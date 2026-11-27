import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'diagnostics_log.dart';
import 'distribution_channel.dart';
import 'net.dart';
import 'update_manifest.dart';

/// GitHub repository this fork publishes releases from. The updater reads the
/// `update.json` asset attached to the latest release (see
/// `.github/workflows/release.yml` and docs/updates.md).
const String kGithubOwner = 'SNBogdanov';
const String kGithubRepo = 'iptvs';

/// The running app's version name — the build-name CI sets from the release tag
/// (`--build-name <tag-without-v>`), so a released build reports e.g. `1.2.3`
/// and compares equal to tag `v1.2.3`. Local `flutter run` builds report the
/// pubspec version (`1.0.0`).
Future<String> appVersion() async => (await PackageInfo.fromPlatform()).version;

/// A published GitHub release, reduced to what the updater needs. Kept free of
/// any `Source`/UI coupling so [fromJson] is a pure, unit-testable parser.
class ReleaseInfo {
  /// Release tag with the leading `v` stripped, e.g. `1.2.3`.
  final String version;

  /// The raw tag, e.g. `v1.2.3`.
  final String tagName;

  /// Human title (`iptvs 1.2.3`).
  final String name;

  /// Release body / changelog (markdown text; shown as-is).
  final String notes;

  /// The release page — the cross-platform browser fallback.
  final Uri htmlUrl;

  /// Direct download of the universal APK (`iptvs-<ver>-android.apk`).
  final Uri? androidAsset;
  final ReleaseArtifact? androidArtifact;

  /// Direct download of the MSI package (`iptvs-<ver>.msi`).
  final Uri? windowsAsset;
  final ReleaseArtifact? windowsArtifact;

  /// Direct download of the x86-64 Linux AppImage.
  final Uri? linuxAsset;
  final ReleaseArtifact? linuxArtifact;

  const ReleaseInfo({
    required this.version,
    required this.tagName,
    required this.name,
    required this.notes,
    required this.htmlUrl,
    this.androidAsset,
    this.androidArtifact,
    this.windowsAsset,
    this.windowsArtifact,
    this.linuxAsset,
    this.linuxArtifact,
  });

  /// The download URL for the running platform, or null if this release ships
  /// no matching asset (e.g. on macOS, where only the browser fallback applies).
  Uri? assetForCurrentPlatform() {
    if (Platform.isAndroid) return androidAsset;
    if (Platform.isWindows) return windowsAsset;
    if (Platform.isLinux) return linuxAsset;
    return null;
  }

  /// Byte size of [assetForCurrentPlatform], for a determinate progress bar.
  int? sizeForCurrentPlatform() {
    if (Platform.isAndroid) return androidArtifact?.byteSize;
    if (Platform.isWindows) return windowsArtifact?.byteSize;
    if (Platform.isLinux) return linuxArtifact?.byteSize;
    return null;
  }

  ReleaseArtifact? artifactForCurrentPlatform() {
    if (Platform.isAndroid) return androidArtifact;
    if (Platform.isWindows) return windowsArtifact;
    if (Platform.isLinux) return linuxArtifact;
    return null;
  }
}

/// Queries GitHub for the latest release and reads the running app version.
/// Follows the `dart:io HttpClient` idiom used elsewhere (see
/// `mdblist_client.dart`) — GitHub's API rejects requests without a User-Agent.
class UpdateService {
  UpdateService({
    HttpClient? http,
    this.owner = kGithubOwner,
    this.repo = kGithubRepo,
    this.track = UpdateTrack.stable,
  }) : _http =
           http ??
           (HttpClient()
             ..connectionTimeout = _connectTimeout
             ..autoUncompress = false);

  final HttpClient _http;
  final String owner;
  final String repo;

  /// Retained so the settings UI's Stable/Beta selector keeps compiling. This
  /// fork publishes one channel: both values read the same `update.json`.
  final UpdateTrack track;

  static const _connectTimeout = Duration(seconds: 15);
  static const _userAgent = 'iptvs-updater';

  /// `releases/latest/download/<asset>` — GitHub's own redirect to the newest
  /// non-draft, non-prerelease release, so no API token or rate limit is
  /// involved (the `tremotesf` model).
  Uri get _manifestUrl => Uri.parse(
    'https://github.com/$owner/$repo/releases/latest/download/update.json',
  );

  /// Fetches the latest release's `update.json`.
  ///
  /// A 404 means no release carries the asset yet and is treated as "up to
  /// date" (null), not an error — an install that predates the first release is
  /// not broken, it is simply current.
  Future<ReleaseInfo?> fetchLatest() async {
    final operation = HttpOperation(kUpdateDiscoveryWorkload);
    final response = await openApprovedUpdateGet(
      _http,
      _manifestUrl,
      operation: operation,
      headers: const {HttpHeaders.userAgentHeader: _userAgent},
    );
    if (response.statusCode == 404) {
      await operation.readBytes(response);
      DiagnosticsLog.instance.add('update', 'No releases published yet');
      return null;
    }
    if (response.statusCode != 200) {
      await operation.readBytes(response);
      throw StateError('GitHub HTTP ${response.statusCode}');
    }
    final manifest = ReleaseManifest.parse(await operation.readBytes(response));
    final android = manifest.artifacts['android'];
    final windows = manifest.artifacts['windows-x64'];
    final linux = manifest.artifacts['linux-x86_64'];
    final info = ReleaseInfo(
      version: manifest.version,
      tagName: 'v${manifest.version}',
      name: 'iptvs ${manifest.version}',
      notes: '',
      htmlUrl: Uri.https('github.com', '/$owner/$repo/releases'),
      androidAsset: android?.url,
      androidArtifact: android,
      windowsAsset: windows?.url,
      windowsArtifact: windows,
      linuxAsset: linux?.url,
      linuxArtifact: linux,
    );
    DiagnosticsLog.instance.add('update', 'Found release ${info.tagName}');
    return info;
  }

  Future<String> currentVersion() => appVersion();

  void close() => _http.close(force: true);
}

bool isApprovedUpdateUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    uri.port == 443 &&
    const {
      'api.github.com',
      'github.com',
      'objects.githubusercontent.com',
      'release-assets.githubusercontent.com',
    }.contains(uri.host.toLowerCase());

/// Resolves one HTTP Location value and rejects it before any connection is
/// made unless the destination remains on approved HTTPS release
/// infrastructure. Relative redirects are resolved against [current].
Uri resolveApprovedUpdateRedirect(Uri current, String location) {
  final parsed = Uri.tryParse(location);
  if (parsed == null) {
    throw const FormatException('Invalid update redirect');
  }
  final resolved = current.resolveUri(parsed);
  if (!isApprovedUpdateUri(resolved)) {
    throw const FormatException('Unapproved update redirect');
  }
  return resolved;
}

/// Opens a GET while manually validating each redirect before following it.
/// `HttpClient` normally follows first and only reports the redirect chain on
/// the final response, which is too late for a security boundary.
Future<HttpClientResponse> openApprovedUpdateGet(
  HttpClient http,
  Uri initial, {
  required HttpOperation operation,
  Map<String, String> headers = const {},
  int maximumRedirects = 5,
}) async {
  if (!isApprovedUpdateUri(initial)) {
    throw const FormatException('Unapproved update host');
  }
  var current = initial;
  for (var redirects = 0; redirects <= maximumRedirects; redirects++) {
    final request = await operation.wait(http.getUrl(current));
    request.followRedirects = false;
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final response = await operation.wait(request.close());
    if (!response.isRedirect) return response;

    final location = response.headers.value(HttpHeaders.locationHeader);
    await operation.readBytes(response);
    if (location == null || location.trim().isEmpty) {
      throw const FormatException('Update redirect has no destination');
    }
    if (redirects == maximumRedirects) {
      throw const FormatException('Too many update redirects');
    }
    current = resolveApprovedUpdateRedirect(current, location);
  }
  throw const FormatException('Too many update redirects');
}

/// Compares two dotted numeric version strings. Build metadata (anything after
/// the first `+`, `-`, or space) is ignored, differing part counts are padded
/// (`1.2` == `1.2.0`), and parts compare numerically (`1.2.10` > `1.2.9`).
/// Returns <0 when [a] < [b], 0 when equal, >0 when [a] > [b].
int compareVersions(String a, String b) {
  List<int> parts(String v) {
    final core = v.trim().split(RegExp(r'[+\- ]')).first;
    return core
        .split('.')
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
  }

  final pa = parts(a);
  final pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

const bool _developerDowngradeOverride = bool.fromEnvironment(
  'ALLOW_UPDATE_DOWNGRADE',
);

/// Release builds always require a strict upgrade. A local debug build may opt
/// into downgrade testing with an explicitly named compile-time override.
bool isUpdateAllowed(
  ReleaseInfo release,
  String current, {
  bool developerDowngradeOverride = _developerDowngradeOverride,
}) {
  final comparison = compareVersions(release.version, current);
  if (comparison > 0) return true;
  return developerDowngradeOverride &&
      !const bool.fromEnvironment('dart.vm.product');
}

bool isNewer(ReleaseInfo release, String current) =>
    compareVersions(release.version, current) > 0;

/// Whether a **development** build may install this release.
///
/// Deliberately `>=` where [isUpdateAllowed] is `>`: a dev build is often the
/// same version as the last release (it is cut from the same tree) or ahead of
/// it, and "install the release" must still be possible for the equal case —
/// that is the whole point of leaving a dev build. An **older** release is
/// refused before anything is downloaded: silently downgrading is the one
/// outcome that must never happen.
bool releaseInstallAllowed(String releaseVersion, String current) =>
    compareVersions(releaseVersion, current) >= 0;

/// Throttle for the boot-time auto-check: run only if we've never checked or
/// the last check was at least [minGap] ago. Pure so it's unit-testable.
bool shouldAutoCheck(
  DateTime? lastCheck,
  DateTime now, {
  Duration minGap = const Duration(hours: 6),
}) {
  if (lastCheck == null) return true;
  return now.difference(lastCheck) >= minGap;
}

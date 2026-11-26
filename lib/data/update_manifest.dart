import 'dart:convert';
import 'dart:typed_data';

const int kMaxReleaseManifestBytes = 64 * 1024;
const int kMaxAndroidUpdateBytes = 512 * 1024 * 1024;
const int kMaxWindowsUpdateBytes = 1024 * 1024 * 1024;
const int kMaxLinuxUpdateBytes = 1024 * 1024 * 1024;

/// Manifest keys this build understands, mapped to the platform names used by
/// the rest of the updater.
///
/// The manifest is the flat shape `tremotesf` publishes — an object keyed by
/// platform. Keys outside this map are **ignored**, so a release that adds a
/// platform cannot break an older client (it simply finds no asset for it); the
/// fail-closed parser this replaced once rejected a whole manifest over one
/// unknown platform.
const Map<String, String> kReleaseManifestKeys = {
  'android': 'android',
  'windows': 'windows-x64',
  'linux': 'linux-x86_64',
};

/// One installable file described by the release manifest.
class ReleaseArtifact {
  const ReleaseArtifact({
    required this.platform,
    required this.url,
    required this.filename,
    required this.byteSize,
    required this.sha256,
  });

  final String platform;

  /// Where the file lives. Only HTTPS GitHub release hosts are downloaded from;
  /// see `update_installer.dart`'s host allowlist.
  final Uri url;

  /// The last path segment of [url] — what the download writes to disk.
  final String filename;

  final int byteSize;
  final String sha256;

  /// File types each platform's installer accepts: an APK on Android, the MSI
  /// package on Windows (it updates itself through `msiexec`), the AppImage on
  /// Linux.
  static const Map<String, List<String>> _extensions = {
    'android': ['.apk'],
    'windows-x64': ['.msi'],
    'linux-x86_64': ['.appimage'],
  };

  static ReleaseArtifact fromJson(Map<String, dynamic> json, String platform) {
    final rawUrl = json['url'];
    final byteSize = json['size'];
    final sha256 = json['sha256'];
    final uri = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.pathSegments.isEmpty) {
      throw const FormatException('Invalid release artifact URL');
    }
    final filename = uri.pathSegments.last;
    if (filename.isEmpty || filename.contains('/')) {
      throw const FormatException('Invalid release artifact filename');
    }
    final lower = filename.toLowerCase();
    if (!_extensions[platform]!.any(lower.endsWith)) {
      throw const FormatException('Unexpected release file type');
    }
    final maximum = switch (platform) {
      'android' => kMaxAndroidUpdateBytes,
      'windows-x64' => kMaxWindowsUpdateBytes,
      'linux-x86_64' => kMaxLinuxUpdateBytes,
      _ => throw const FormatException('Unsupported release platform'),
    };
    if (byteSize is! int || byteSize <= 0 || byteSize > maximum) {
      throw const FormatException('Invalid release artifact size');
    }
    if (sha256 is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('Invalid release artifact SHA-256');
    }
    return ReleaseArtifact(
      platform: platform,
      url: uri,
      filename: filename,
      byteSize: byteSize,
      sha256: sha256,
    );
  }
}

/// The `update.json` asset attached to the latest GitHub release.
///
/// Deliberately **unsigned**, the `tremotesf` model: the trust anchor is HTTPS
/// to GitHub's release CDN plus the per-file SHA-256. The previous
/// Ed25519-signed manifest needed a private key this fork does not have, and a
/// signature shipped beside the artifact it signs adds little over the hash.
///
/// Shape:
/// ```json
/// {
///   "version": "1.2.3",
///   "minimum_version": "1.0.0",
///   "windows": {"url": "https://github.com/.../iptvs-1.2.3.msi", "size": 73422891, "sha256": "…"},
///   "android": {"url": "https://github.com/.../iptvs-1.2.3.apk", "size": 55123456, "sha256": "…"},
///   "linux":   {"url": "https://github.com/.../iptvs-1.2.3.AppImage", "size": 81234567, "sha256": "…"}
/// }
/// ```
class ReleaseManifest {
  const ReleaseManifest({
    required this.version,
    required this.minimumVersion,
    required this.artifacts,
  });

  final String version;
  final String minimumVersion;
  final Map<String, ReleaseArtifact> artifacts;

  static ReleaseManifest parse(Uint8List bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('Release manifest must be an object');
    }
    final json = Map<String, dynamic>.from(decoded);
    final version = json['version'];
    final versionPattern = RegExp(r'^\d+\.\d+\.\d+$');
    if (version is! String || !versionPattern.hasMatch(version)) {
      throw const FormatException('Invalid release version');
    }
    final minimumVersion = json['minimum_version'] ?? version;
    if (minimumVersion is! String || !versionPattern.hasMatch(minimumVersion)) {
      throw const FormatException('Invalid minimum release version');
    }
    final artifacts = <String, ReleaseArtifact>{};
    for (final entry in kReleaseManifestKeys.entries) {
      final raw = json[entry.key];
      if (raw == null) continue;
      if (raw is! Map) {
        throw const FormatException('Invalid release artifact');
      }
      artifacts[entry.value] = ReleaseArtifact.fromJson(
        Map<String, dynamic>.from(raw),
        entry.value,
      );
    }
    return ReleaseManifest(
      version: version,
      minimumVersion: minimumVersion,
      artifacts: Map.unmodifiable(artifacts),
    );
  }
}


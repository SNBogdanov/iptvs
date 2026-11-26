import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'diagnostics_log.dart';
import 'distribution_channel.dart';
import 'net.dart';
import 'update_manifest.dart';
import 'update_service.dart';

/// The MSIX package identity this build ships as (see
/// `windows/packaging/AppxManifest.xml.in`).
///
/// The Windows updater relaunches the app by package family name after
/// installing, and an in-place update only works while this identity — and the
/// publisher — stay unchanged.
const String kWindowsMsixPackageName = 'SNBogdanov.IPTVSPlayer';

/// Outcome of kicking off a platform install.
enum InstallOutcome {  /// The OS installer (Android) or update helper (Windows) was launched. On
  /// desktop platforms the caller should now exit so the running binary can
  /// be replaced.
  launched,

  /// Android only: the app lacks the "install unknown apps" permission — the
  /// caller should prompt the user (see [requestInstallPermission]) and retry.
  needsPermission,

  /// No in-app install path (unsupported platform / failure); the release page
  /// was opened in a browser instead.
  openedInBrowser,
}

/// Downloads a release asset and hands it to the platform's install path:
/// Android fires the system package-installer via the `iptvs/updates`
/// MethodChannel; Windows starts an elevated helper that installs the signed
/// MSI and relaunches the app; Linux atomically replaces the running AppImage
/// and relaunches it. Everything else falls back to the browser.
class UpdateInstaller {
  static const _channel = MethodChannel('iptvs/updates');
  final HttpClient _http;

  UpdateInstaller({HttpClient? http})
    : _http =
          http ??
          (HttpClient()
            ..connectionTimeout = _connectTimeout
            ..autoUncompress = false);

  static const _connectTimeout = Duration(seconds: 20);

  /// Whether an in-app download+install is supported here (the two release
  /// targets). Elsewhere the flow degrades to opening the release page.
  static bool get isSupported =>
      DistributionConfig.directUpdaterEnabled &&
      (Platform.isAndroid ||
          Platform.isWindows ||
          (Platform.isLinux && _runningAppImage != null));

  static String? get _runningAppImage {
    final value = Platform.environment['APPIMAGE']?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// Streams [url] to a file in the temp dir, reporting fractional progress
  /// (0..1) as chunks arrive. Returns the written file. GitHub asset URLs 302
  /// to a CDN; each destination is approved before it is followed.
  Future<File> download(
    Uri url,
    ReleaseArtifact artifact, {
    void Function(double progress)? onProgress,
  }) async {
    if (!isApprovedUpdateUri(url)) {
      throw const FormatException('Unapproved update host');
    }
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, artifact.filename));
    final partial = File('${file.path}.partial');
    if (await partial.exists()) await partial.delete();
    final operation = HttpOperation(
      kUpdateArtifactWorkload.copyWith(
        maximumBodyBytes: artifact.byteSize,
        maximumDecodedBytes: artifact.byteSize,
      ),
    );
    final response = await openApprovedUpdateGet(
      _http,
      url,
      operation: operation,
      headers: const {HttpHeaders.userAgentHeader: 'iptvs-updater'},
    );
    if (response.statusCode != 200) {
      await operation.readBytes(response);
      throw StateError('Download HTTP ${response.statusCode}');
    }
    if (response.contentLength >= 0 &&
        response.contentLength != artifact.byteSize) {
      await response.drain<void>();
      throw const FormatException('Update Content-Length mismatch');
    }
    final digestSink = _DigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    var received = 0;
    var hashClosed = false;
    try {
      received = await operation.readToFile(
        response,
        partial,
        maximumBytes: artifact.byteSize,
        onChunk: (chunk, total) {
          hashSink.add(chunk);
          onProgress?.call(total / artifact.byteSize);
        },
      );
      hashSink.close();
      hashClosed = true;
      validateDownloadedArtifact(
        artifact: artifact,
        receivedBytes: received,
        sha256Digest: digestSink.value.toString(),
      );
      if (await file.exists()) await file.delete();
      final renamed = await partial.rename(file.path);
      return renamed;
    } catch (_) {
      if (!hashClosed) hashSink.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  /// Installs a downloaded [file] for the running platform. On failure or an
  /// unsupported platform, opens [ReleaseInfo.htmlUrl] in a browser.
  Future<InstallOutcome> install(ReleaseInfo release, File file) async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod<String>('installApk', {
          'path': file.path,
        });
        return result == 'needs_permission'
            ? InstallOutcome.needsPermission
            : InstallOutcome.launched;
      }
      if (Platform.isWindows) {
        await _launchWindowsMsiUpdater(file);
        return InstallOutcome.launched;
      }
      if (Platform.isLinux) {
        await _launchLinuxUpdater(file);
        return InstallOutcome.launched;
      }
    } catch (e) {
      DiagnosticsLog.instance.add('update', 'Install failed: $e');
    }
    await openReleasePage(release.htmlUrl);
    return InstallOutcome.openedInBrowser;
  }

  /// Sends the user to Android's per-app "install unknown apps" settings.
  Future<bool> requestInstallPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestInstallPermission') ??
          false;
    } catch (e) {
      DiagnosticsLog.instance.add('update', 'Permission request failed: $e');
      return false;
    }
  }

  /// Opens [url] (the release page) in the system browser.
  Future<void> openReleasePage(Uri url) async {
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      DiagnosticsLog.instance.add(
        'update',
        'Open browser failed: ${redactUrl(url)}',
      );
    }
  }

  /// Starts an elevated helper that installs the downloaded MSI once this
  /// process has exited. The caller must then `exit(0)`.
  ///
  /// MSI is a normal Windows installer: it upgrades the per-machine install in
  /// `C:\Program Files\IPTVS` in place (`msiexec /i … /qn`), so there is no
  /// certificate to trust and no package identity to keep stable — only the
  /// MSI `UpgradeCode`, which the package itself carries.
  Future<void> _launchWindowsMsiUpdater(File msi) async {
    final dir = await getTemporaryDirectory();
    final script = File(p.join(dir.path, 'iptvs_update.ps1'));
    await script.writeAsString(
      windowsMsiUpdateScript(pid: pid, msiPath: msi.path),
    );
    final launch = windowsUpdaterLaunch(script.path);
    await Process.start(
      launch.executable,
      launch.arguments,
      mode: ProcessStartMode.detached,
      workingDirectory: dir.path,
    );
  }
  /// Stages the verified AppImage beside the running one, then starts a
  /// detached helper which waits for this process, atomically swaps the files,
  /// relaunches, and restores the previous AppImage if launch fails.
  Future<void> _launchLinuxUpdater(File appImage) async {
    final configuredPath = _runningAppImage;
    if (configuredPath == null) {
      throw const FileSystemException('Not running from an AppImage');
    }
    final target = File(configuredPath);
    if (!await target.exists()) {
      throw const FileSystemException('Running AppImage is missing');
    }
    final targetPath = await target.resolveSymbolicLinks();
    final stage = File('$targetPath.update-new-$pid');
    if (await stage.exists()) await stage.delete();
    await appImage.copy(stage.path);
    await Process.run('chmod', ['0755', stage.path]);

    final dir = await getTemporaryDirectory();
    final script = File(p.join(dir.path, 'iptvs_update.sh'));
    await script.writeAsString(linuxUpdateScript);
    await Process.run('chmod', ['0700', script.path]);
    await Process.start(
      '/bin/sh',
      [script.path, '$pid', stage.path, targetPath],
      mode: ProcessStartMode.detached,
      workingDirectory: dir.path,
    );
  }

  void close() => _http.close(force: true);
}

/// Detached AppImage replacement helper. Paths are passed as positional
/// arguments (not interpolated), so spaces and shell metacharacters stay data.
const String linuxUpdateScript = r'''#!/bin/sh
set -eu
old_pid="$1"
stage="$2"
target="$3"
backup="$target.update-backup"

while kill -0 "$old_pid" 2>/dev/null; do
  sleep 1
done

rm -f "$backup"
mv "$target" "$backup"
if mv "$stage" "$target" && chmod 0755 "$target"; then
  "$target" >/dev/null 2>&1 &
  new_pid=$!
  sleep 3
  if kill -0 "$new_pid" 2>/dev/null; then
    rm -f "$backup"
    exit 0
  fi
fi

rm -f "$target"
mv "$backup" "$target"
chmod 0755 "$target"
"$target" >/dev/null 2>&1 &
''';

/// Revalidates a previously downloaded APK before resuming installation.
///
/// The pending record lives in secure storage, but the cache file can disappear
/// or be replaced while the app is away. Keep the same exact-byte checks used
/// at download time, and reject paths outside the application temp directory.
Future<void> validateCachedArtifact(
  File file,
  ReleaseArtifact artifact, {
  Directory? tempDirectory,
}) async {
  final temp = tempDirectory ?? await getTemporaryDirectory();
  final tempPath = await temp.resolveSymbolicLinks();
  if (!await file.exists()) {
    throw const FileSystemException('Cached update is missing');
  }
  final filePath = await file.resolveSymbolicLinks();
  if (!p.isWithin(tempPath, filePath) ||
      p.basename(filePath) != artifact.filename) {
    throw const FileSystemException('Cached update path is invalid');
  }
  final length = await file.length();
  final digest = await sha256.bind(file.openRead()).first;
  validateDownloadedArtifact(
    artifact: artifact,
    receivedBytes: length,
    sha256Digest: digest.toString(),
  );
}

void validateDownloadedArtifact({
  required ReleaseArtifact artifact,
  required int receivedBytes,
  required String sha256Digest,
}) {
  if (receivedBytes != artifact.byteSize) {
    throw const FormatException('Update byte size mismatch');
  }
  if (sha256Digest != artifact.sha256) {
    throw const FormatException('Update SHA-256 mismatch');
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('Digest is not complete'));

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

/// How the Windows installer helper is spawned.
///
/// `Add-AppxPackage` and the certificate import both need elevation, so the
/// helper is started with `Start-Process -Verb RunAs` (the UAC prompt the user
/// sees). It is launched through a `-Command` wrapper rather than
/// `-ExecutionPolicy Bypass -File`, because only `Start-Process` can request
/// elevation; the wrapper then runs the script itself hidden.
///
/// The helper's first act is `Wait-Process` on this app's PID: `msiexec` cannot
/// replace files a running process still holds. Pure so the invocation is
/// unit-testable.
({String executable, List<String> arguments}) windowsUpdaterLaunch(
  String scriptPath,
) {
  String q(String value) => "'${value.replaceAll("'", "''")}'";
  return (
    executable: 'powershell.exe',
    arguments: <String>[
      '-NoProfile',
      '-WindowStyle',
      'Hidden',
      '-Command',
      'Start-Process -FilePath powershell.exe -Verb RunAs -WindowStyle Hidden '
          '-ArgumentList '
          "'-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',"
          "'-File',${q(scriptPath)}",
    ],
  );
}

/// The Windows self-update helper script.
///
/// Waits for the app to exit, runs the MSI in quiet mode (`msiexec /i … /qn`)
/// and relaunches the installed executable. A transcript lands in
/// `%TEMP%\iptvs_update.log` so a failed run is diagnosable instead of silent.
String windowsMsiUpdateScript({
  required int pid,
  required String msiPath,
  String installDir = r'C:\Program Files\IPTVS',
}) {
  String q(String s) => "'${s.replaceAll("'", "''")}'";
  return '''
\$ErrorActionPreference = 'Stop'
\$msiPath = ${q(msiPath)}
\$logPath = Join-Path ([System.IO.Path]::GetTempPath()) 'iptvs_update.log'
try { Start-Transcript -Path \$logPath -Force -ErrorAction SilentlyContinue | Out-Null } catch {}

try {
  # The installer replaces files, so the running app has to exit first.
  try { Wait-Process -Id $pid -Timeout 90 } catch {}
  Start-Sleep -Milliseconds 500

  # Where to relaunch from; the MSI writes this, the default is only a fallback
  # for a machine whose registry entry a cleanup tool has removed.
  \$installDir = ${q(installDir)}
  try {
    \$registered = (Get-ItemProperty 'HKLM:\\SOFTWARE\\SNBogdanov\\IPTVS' -Name InstallDir -ErrorAction Stop).InstallDir
    if (-not [string]::IsNullOrWhiteSpace(\$registered)) { \$installDir = \$registered }
  } catch {}

  \$msiLog = Join-Path ([System.IO.Path]::GetTempPath()) 'iptvs_msi.log'
  \$process = Start-Process 'msiexec.exe' -Wait -PassThru -ArgumentList @(
    '/i', \$msiPath, '/qn', '/norestart', '/l*v', \$msiLog)
  if (\$process.ExitCode -ne 0 -and \$process.ExitCode -ne 3010) {
    throw "msiexec exited \$(\$process.ExitCode); see \$msiLog"
  }

  \$exe = Join-Path \$installDir 'iptvs.exe'
  if (Test-Path \$exe) { Start-Process \$exe }
} catch {
  Write-Error \$_
  exit 1
} finally {
  try { Stop-Transcript | Out-Null } catch {}
}
''';
}
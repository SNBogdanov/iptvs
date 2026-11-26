import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/update_installer.dart';
import 'package:iptvs/data/update_manifest.dart';

final _artifact = ReleaseArtifact(
  platform: 'android',
  url: Uri.parse('https://github.com/SNBogdanov/iptvs/releases/download/v1.4.2/artifact.apk'),
  filename: 'iptvs-1.4.2-android.apk',
  byteSize: 5,
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('accepts the signed byte size and digest', () {
    expect(
      () => validateDownloadedArtifact(
        artifact: _artifact,
        receivedBytes: 5,
        sha256Digest: _artifact.sha256,
      ),
      returnsNormally,
    );
  });

  test('rejects a truncated or extended artifact', () {
    for (final size in [4, 6]) {
      expect(
        () => validateDownloadedArtifact(
          artifact: _artifact,
          receivedBytes: size,
          sha256Digest: _artifact.sha256,
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('rejects an artifact with a different digest', () {
    expect(
      () => validateDownloadedArtifact(
        artifact: _artifact,
        receivedBytes: 5,
        sha256Digest:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  group('cached Android update', () {
    late Directory cache;
    late File apk;
    late ReleaseArtifact artifact;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('iptvs-update-test-');
      apk = File('${cache.path}/iptvs-1.4.2-android.apk');
      final bytes = [1, 2, 3, 4, 5];
      await apk.writeAsBytes(bytes);
      artifact = ReleaseArtifact(
        platform: 'android',
        url: Uri.parse('https://github.com/SNBogdanov/iptvs/releases/download/v1.4.2/artifact.apk'),
        filename: 'iptvs-1.4.2-android.apk',
        byteSize: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );
    });

    tearDown(() => cache.delete(recursive: true));

    test('revalidates an unchanged cache-owned APK', () async {
      await validateCachedArtifact(apk, artifact, tempDirectory: cache);
    });

    test('rejects bytes changed during a settings detour', () async {
      await apk.writeAsBytes([5, 4, 3, 2, 1]);
      await expectLater(
        validateCachedArtifact(apk, artifact, tempDirectory: cache),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a matching file outside the owned cache', () async {
      final outside = await Directory.systemTemp.createTemp('iptvs-outside-');
      addTearDown(() => outside.delete(recursive: true));
      final file = await apk.copy('${outside.path}/${artifact.filename}');
      await expectLater(
        validateCachedArtifact(file, artifact, tempDirectory: cache),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  test(
    'install permission request waits for and returns native result',
    () async {
      const channel = MethodChannel('iptvs/updates');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'requestInstallPermission');
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final installer = UpdateInstaller();
      addTearDown(installer.close);

      expect(await installer.requestInstallPermission(), isTrue);
    },
  );

  group('Windows MSI update script', () {
    final script = windowsMsiUpdateScript(
      pid: 42,
      msiPath: r"C:\Users\O'Brien\update.msi",
    );

    test('quotes user-controlled paths and waits for this process', () {
      expect(script, contains(r"$msiPath = 'C:\Users\O''Brien\update.msi'"));
      expect(script, contains('Wait-Process -Id 42'));
    });

    test('installs quietly and relaunches the installed executable', () {
      expect(script, contains("'msiexec.exe'"));
      expect(script, contains("'/i', \$msiPath, '/qn', '/norestart'"));
      expect(script, contains(r'HKLM:\SOFTWARE\SNBogdanov\IPTVS'));
      expect(script, contains(r"Join-Path $installDir 'iptvs.exe'"));
      expect(script, contains('Start-Process \$exe'));
    });

    test('accepts a reboot-required result and keeps an MSI log', () {
      expect(script, contains('3010'));
      expect(script, contains('iptvs_msi.log'));
    });

    test('records a transcript so a failed helper is diagnosable', () {
      expect(script, contains('Start-Transcript'));
      expect(script, contains("'iptvs_update.log'"));
    });
  });

  group('Windows MSI updater launch', () {
    final launch = windowsUpdaterLaunch(r'C:\Temp\iptvs_update.ps1');

    test('asks for elevation through Start-Process -Verb RunAs', () {
      expect(launch.executable, 'powershell.exe');
      expect(launch.arguments, contains('-Command'));
      final command = launch.arguments.last;
      expect(command, contains('-Verb RunAs'));
      expect(command, contains("'-File','C:\\Temp\\iptvs_update.ps1'"));
    });

    test('runs the helper script hidden without a profile', () {
      expect(launch.arguments, contains('-NoProfile'));
      expect(launch.arguments, contains('-WindowStyle'));
    });
  });
  group('Linux AppImage update script', () {
    test('waits for the app and swaps whole files', () {
      expect(linuxUpdateScript, contains('kill -0 "\$old_pid"'));
      expect(linuxUpdateScript, contains('mv "\$target" "\$backup"'));
      expect(linuxUpdateScript, contains('mv "\$stage" "\$target"'));
      expect(linuxUpdateScript, contains('chmod 0755 "\$target"'));
    });

    test('restores and relaunches the previous AppImage on failure', () {
      expect(linuxUpdateScript, contains('rm -f "\$target"'));
      expect(linuxUpdateScript, contains('mv "\$backup" "\$target"'));
      expect(linuxUpdateScript, contains('"\$target" >/dev/null 2>&1 &'));
    });
  });
}

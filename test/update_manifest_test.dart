import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/update_manifest.dart';

Uint8List _bytes(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, dynamic> _artifact(
  String filename, {
  String sha256 = _sha,
  int size = 12345,
  String host = 'github.com',
}) => {
  'url': 'https://$host/SNBogdanov/iptvs/releases/download/v1.4.2/$filename',
  'size': size,
  'sha256': sha256,
};

void main() {
  group('ReleaseManifest', () {
    test('parses every platform with its URL, size and hash', () {
      final manifest = ReleaseManifest.parse(
        _bytes({
          'version': '1.4.2',
          'minimum_version': '1.0.0',
          'windows': _artifact('iptvs-1.4.2.msi', size: 73422891),
          'android': _artifact('iptvs-1.4.2.apk', size: 55123456),
          'linux': _artifact('iptvs-1.4.2.AppImage', size: 81234567),
        }),
      );

      expect(manifest.version, '1.4.2');
      expect(manifest.minimumVersion, '1.0.0');
      expect(manifest.artifacts.keys, {
        'windows-x64',
        'android',
        'linux-x86_64',
      });
      final windows = manifest.artifacts['windows-x64']!;
      expect(windows.filename, 'iptvs-1.4.2.msi');
      expect(windows.byteSize, 73422891);
      expect(windows.sha256, _sha);
      expect(windows.url.host, 'github.com');
    });

    test('a missing minimum_version falls back to the version', () {
      final manifest = ReleaseManifest.parse(
        _bytes({'version': '1.4.2', 'android': _artifact('a.apk')}),
      );
      expect(manifest.minimumVersion, '1.4.2');
    });

    test('unknown platform keys are ignored, not rejected', () {
      final manifest = ReleaseManifest.parse(
        _bytes({
          'version': '1.4.2',
          'android': _artifact('iptvs-1.4.2.apk'),
          'macos': {'url': 'https://github.com/a/b.dmg', 'size': 1, 'sha256': _sha},
        }),
      );
      expect(manifest.artifacts.keys, {'android'});
    });

    test('rejects a version that is not dotted numeric', () {
      expect(
        () => ReleaseManifest.parse(_bytes({'version': 'v1.4.2'})),
        throwsFormatException,
      );
    });

    test('rejects a non-HTTPS or hostless artifact URL', () {
      expect(
        () => ReleaseManifest.parse(
          _bytes({
            'version': '1.4.2',
            'android': {
              'url': 'http://github.com/a.apk',
              'size': 1,
              'sha256': _sha,
            },
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => ReleaseManifest.parse(
          _bytes({
            'version': '1.4.2',
            'android': {'url': 'https:///a.apk', 'size': 1, 'sha256': _sha},
          }),
        ),
        throwsFormatException,
      );
    });

    test('rejects the wrong file type for a platform', () {
      expect(
        () => ReleaseManifest.parse(
          _bytes({
            'version': '1.4.2',
            'windows': _artifact('iptvs-1.4.2.zip'),
          }),
        ),
        throwsFormatException,
      );
    });

    test('rejects a malformed or oversized artifact', () {
      expect(
        () => ReleaseManifest.parse(
          _bytes({
            'version': '1.4.2',
            'android': _artifact('a.apk', sha256: 'not-a-hash'),
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => ReleaseManifest.parse(
          _bytes({
            'version': '1.4.2',
            'android': _artifact('a.apk', size: 0),
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => ReleaseManifest.parse(
          _bytes({
            'version': '1.4.2',
            'android': _artifact(
              'a.apk',
              size: kMaxAndroidUpdateBytes + 1,
            ),
          }),
        ),
        throwsFormatException,
      );
    });
  });

  group('release pipeline', () {
    // The workflow writes `update.json` with shell tools; this pins the shape it
    // must produce against the parser above, so the two cannot drift apart
    // without a red test. (The publish step itself can only run in CI.)
    test('publishes an update.json the client can parse', () {
      final workflow = File('.github/workflows/release.yml').readAsStringSync();

      expect(workflow, contains('> dist/update.json'));
      expect(workflow, contains(r'--arg version "$VERSION"'));
      expect(workflow, contains(r'--arg minimum "$MINIMUM_UPDATE_VERSION"'));
      // Only the platforms this fork publishes. A missing platform key is
      // skipped by the client's tolerant parser, so the absence of `linux` is
      // safe for a client that used to receive one.
      for (final key in ['android', 'windows']) {
        expect(
          workflow,
          contains('--argjson $key'),
          reason: 'update.json must carry the $key platform key',
        );
      }
      expect(
        workflow,
        isNot(contains(r'--argjson linux')),
        reason: 'Linux is not published, so update.json must not name it',
      );
      // Absolute, tag-pinned URLs: the manifest names the build it was made from.
      expect(
        workflow,
        contains(
          r'base="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG"',
        ),
      );
      expect(workflow, contains(r'windows="dist/iptvs-$VERSION.msi"'));
    });

    test('no longer signs the manifest with Ed25519', () {
      final workflow = File('.github/workflows/release.yml').readAsStringSync();

      expect(workflow, isNot(contains('UPDATE_MANIFEST_PRIVATE_KEY')));
      expect(workflow, isNot(contains('UPDATE_MANIFEST_PUBLIC_KEY')));
      expect(workflow, isNot(contains('pkeyutl')));
    });
  });
}

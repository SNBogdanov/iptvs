import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/update_manifest.dart';
import 'package:iptvs/data/update_service.dart';

ReleaseInfo _rel(String version) => ReleaseInfo(
  version: version,
  tagName: 'v$version',
  name: 'iptvs $version',
  notes: '',
  htmlUrl: Uri.parse('https://github.com/SNBogdanov/iptvs/releases'),
);

void main() {
  group('compareVersions', () {
    test('orders numerically, not lexically', () {
      expect(compareVersions('1.2.10', '1.2.3'), greaterThan(0));
      expect(compareVersions('1.2.3', '1.2.10'), lessThan(0));
    });

    test('pads differing part counts', () {
      expect(compareVersions('1.2.0', '1.2'), 0);
      expect(compareVersions('1.2', '1.2.1'), lessThan(0));
    });

    test('equal versions', () {
      expect(compareVersions('2.0.0', '2.0.0'), 0);
    });

    test('ignores build metadata / suffixes', () {
      expect(compareVersions('1.2.3+45', '1.2.3'), 0);
      expect(compareVersions('1.2.3-beta', '1.2.3'), 0);
    });

    test('major and minor take precedence', () {
      expect(compareVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.3.0', '1.2.9'), greaterThan(0));
    });
  });

  group('isNewer', () {
    test('true only when release is strictly newer', () {
      expect(isNewer(_rel('1.3.0'), '1.2.0'), isTrue);
      expect(isNewer(_rel('1.2.0'), '1.2.0'), isFalse);
      expect(isNewer(_rel('1.1.0'), '1.2.0'), isFalse);
    });
  });

  group('isUpdateAllowed', () {
    test('rejects same-version installs and downgrades by default', () {
      expect(isUpdateAllowed(_rel('1.2.0'), '1.2.0'), isFalse);
      expect(isUpdateAllowed(_rel('1.1.9'), '1.2.0'), isFalse);
    });

    test('allows an explicitly labelled local downgrade override', () {
      expect(
        isUpdateAllowed(
          _rel('1.1.9'),
          '1.2.0',
          developerDowngradeOverride: true,
        ),
        isTrue,
      );
    });
  });

  group('release manifest discovery', () {
    test('reads the version and every platform from update.json', () {
      final manifest = ReleaseManifest.parse(
        utf8.encode(
          jsonEncode({
            'version': '1.2.3',
            'minimum_version': '1.0.0',
            'windows': {
              'url':
                  'https://github.com/SNBogdanov/iptvs/releases/download/v1.2.3/iptvs-1.2.3.msi',
              'size': 73422891,
              'sha256': 'a' * 64,
            },
            'android': {
              'url':
                  'https://github.com/SNBogdanov/iptvs/releases/download/v1.2.3/iptvs-1.2.3.apk',
              'size': 55123456,
              'sha256': 'b' * 64,
            },
          }),
        ),
      );
      expect(manifest.version, '1.2.3');
      expect(manifest.minimumVersion, '1.0.0');
      expect(manifest.artifacts['windows-x64']?.filename, 'iptvs-1.2.3.msi');
      expect(manifest.artifacts['android']?.filename, 'iptvs-1.2.3.apk');
      expect(manifest.artifacts['linux-x86_64'], isNull);
    });

    test('ignores platforms this build does not know', () {
      final manifest = ReleaseManifest.parse(
        utf8.encode(
          jsonEncode({
            'version': '1.2.3',
            'macos': {'url': 'https://github.com/a/b/c.dmg', 'size': 1, 'sha256': 'c' * 64},
          }),
        ),
      );
      expect(manifest.artifacts, isEmpty);
    });
  });

  group('shouldAutoCheck', () {
    final now = DateTime(2026, 7, 10, 12);

    test('runs when never checked', () {
      expect(shouldAutoCheck(null, now), isTrue);
    });

    test('throttled within the gap, allowed after', () {
      expect(
        shouldAutoCheck(now.subtract(const Duration(hours: 1)), now),
        isFalse,
      );
      expect(
        shouldAutoCheck(now.subtract(const Duration(hours: 5)), now),
        isFalse,
      );
      expect(
        shouldAutoCheck(now.subtract(const Duration(hours: 7)), now),
        isTrue,
      );
    });
  });

  group('approved update URLs', () {
    test('accepts HTTPS GitHub release infrastructure', () {
      expect(
        isApprovedUpdateUri(
          Uri.parse(
            'https://github.com/SNBogdanov/iptvs/releases/download/v1.2.3/x',
          ),
        ),
        isTrue,
      );
      expect(
        isApprovedUpdateUri(
          Uri.parse('https://release-assets.githubusercontent.com/file'),
        ),
        isTrue,
      );
    });

    test('rejects HTTP, user-controlled hosts, and lookalike suffixes', () {
      expect(isApprovedUpdateUri(Uri.parse('http://github.com/file')), isFalse);
      expect(
        isApprovedUpdateUri(Uri.parse('https://example.com/file')),
        isFalse,
      );
      expect(
        isApprovedUpdateUri(Uri.parse('https://github.com.example.com/file')),
        isFalse,
      );
      expect(
        isApprovedUpdateUri(Uri.parse('https://github.com:444/file')),
        isFalse,
      );
      expect(
        isApprovedUpdateUri(Uri.parse('https://user@github.com/file')),
        isFalse,
      );
    });

    test('resolves an approved relative redirect', () {
      expect(
        resolveApprovedUpdateRedirect(
          Uri.parse('https://github.com/SNBogdanov/iptvs/releases'),
          '/SNBogdanov/iptvs/releases/download/v1.2.3/file.apk',
        ),
        Uri.parse(
          'https://github.com/SNBogdanov/iptvs/releases/download/v1.2.3/file.apk',
        ),
      );
    });

    test('rejects an unapproved redirect before it can be followed', () {
      for (final location in [
        'https://example.com/payload.apk',
        'http://github.com/payload.apk',
        'https://github.com.example.com/payload.apk',
        'https://github.com:444/payload.apk',
      ]) {
        expect(
          () => resolveApprovedUpdateRedirect(
            Uri.parse('https://github.com/release'),
            location,
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });
  });
}

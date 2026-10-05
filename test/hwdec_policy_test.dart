import 'dart:io' show Directory, File, Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/hwdec_policy.dart';

/// Every `.dart` under `lib/`, so the guards below see a whole-surface sweep
/// rather than the two files this bug was found in.
List<File> _libSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  // The policy is a function of the platform, so it can only be asserted for
  // the platform the suite runs on. What matters is that the *rule* holds: the
  // desktop embedded surfaces must never fall back to media_kit's `auto`
  // (the permissive mode that may pick a zero-copy path), and mobile must be
  // left to media_kit's own default — see the file's doc comment for the field
  // report that moved Windows onto the same policy as every other path.
  group('embedded hwdec policy', () {
    test('Windows asks for auto-copy, Linux auto-safe, mobile defers', () {
      if (Platform.isWindows) {
        // auto-safe negotiates d3d11va *zero-copy*, which is exactly the path
        // that lost the last band on HEVC 1080p (the green stripe) on the
        // embedded live/preview surface. auto-copy keeps the decoder on the GPU
        // but copies frames back, so the present path is not handed a surface it
        // can leave half-drawn.
        expect(embeddedHwdec(), 'auto-copy');
      } else if (Platform.isLinux) {
        expect(embeddedHwdec(), 'auto-safe');
      } else {
        expect(embeddedHwdec(), isNull);
      }
    });

    test('never `auto` on a desktop, which is the permissive default', () {
      if (Platform.isWindows || Platform.isLinux) {
        expect(embeddedHwdec(), isNot('auto'));
      }
    });
  });

  // The two tests above were green while the band was on screen. The policy
  // function was never wrong; the *caller* was, and nothing asserted anything
  // about callers. These are the assertions that were missing.
  group('hwdec call sites', () {
    test('no surface leaves hwdec unset', () {
      // `null` is not a neutral "no opinion" here: media_kit's native
      // controller reads it as `auto`, and only the Android controller
      // substitutes `auto-safe` for it. A null on desktop is the bug.
      final offenders = <String>[];
      for (final f in _libSources()) {
        for (final line in f.readAsLinesSync()) {
          final t = line.trim();
          if (t.startsWith('//') || t.startsWith('///')) continue;
          if (RegExp(r'hwdec:\s*null\b').hasMatch(t)) {
            offenders.add('${f.path}: $t');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'hwdec: null means `auto` off-Android. Ask embeddedHwdec().',
      );
    });

    test('only the policy branches on platform for hwdec', () {
      // A platform ternary at a call site is how `Platform.isLinux ? 'auto-safe'
      // : null` shipped: correct-looking, and null on the platform the band was
      // reported on. The one place allowed to know the platform is the policy.
      final offenders = <String>[];
      for (final f in _libSources()) {
        if (f.path.endsWith('hwdec_policy.dart')) continue;
        for (final line in f.readAsLinesSync()) {
          final t = line.trim();
          if (t.startsWith('//') || t.startsWith('///')) continue;
          if (RegExp(r'hwdec:\s*Platform\.').hasMatch(t)) {
            offenders.add('${f.path}: $t');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'route it through embeddedHwdec(), which owns the mapping',
      );
    });

    test('nothing in lib hardcodes the permissive `auto` for hwdec', () {
      final offenders = <String>[];
      for (final f in _libSources()) {
        for (final line in f.readAsLinesSync()) {
          final t = line.trim();
          if (t.startsWith('//') || t.startsWith('///')) continue;
          if (RegExp(r"""hwdec['"]?\s*[:=]\s*['"]auto['"]""").hasMatch(t)) {
            offenders.add('${f.path}: $t');
          }
        }
      }
      expect(offenders, isEmpty, reason: '`auto` may pick a zero-copy path');
    });
  });
}

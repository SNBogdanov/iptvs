import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/hwdec_policy.dart';

void main() {
  // The policy is a function of the platform, so it can only be asserted for
  // the platform the suite runs on. What matters is that the *rule* holds: the
  // desktop embedded surfaces must never fall back to media_kit's `auto`
  // (the permissive mode that may pick a zero-copy path), and mobile must be
  // left to media_kit's own default — see the file's doc comment for the field
  // report that moved Windows onto the same policy as every other path.
  group('embedded hwdec policy', () {
    test('desktop asks for auto-safe, mobile defers to media_kit', () {
      if (Platform.isWindows || Platform.isLinux) {
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
}

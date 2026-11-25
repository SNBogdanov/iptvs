import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/live_row_layout.dart';

void main() {
  group('LiveRowLayout', () {
    test('offsets are the exact prefix sums of the mixed extents', () {
      final layout = LiveRowLayout(
        count: 4,
        plain: 72,
        withEpg: 112,
        tallAt: (i) => i == 1 || i == 3,
      );
      expect([for (var i = 0; i < 4; i++) layout.extentAt(i)], [
        72.0,
        112.0,
        72.0,
        112.0,
      ]);
      expect([for (var i = 0; i < 4; i++) layout.offsetAt(i)], [
        0.0,
        72.0,
        184.0,
        256.0,
      ]);
      expect(layout.total, 368.0);
    });

    test('a catalog with no programmes is uniformly plain', () {
      final layout = LiveRowLayout(
        count: 10,
        plain: 72,
        withEpg: 112,
        tallAt: (_) => false,
      );
      expect(layout.offsetAt(7), 504.0);
      expect(layout.total, 720.0);
      expect(layout.isUniform, isFalse, reason: 'heights differ, none used');
    });

    test('an empty list has no height and a zero origin', () {
      final layout = LiveRowLayout(
        count: 0,
        plain: 72,
        withEpg: 112,
        tallAt: (_) => true,
      );
      expect(layout.total, 0.0);
      expect(layout.offsetAt(0), 0.0);
    });

    test('the prefix grows on demand and stays exact when asked out of order',
        () {
      final layout = LiveRowLayout(
        count: 300,
        plain: 72,
        withEpg: 112,
        tallAt: (i) => i.isEven,
      );
      // Asking for a far row first must not corrupt the earlier arithmetic.
      expect(layout.offsetAt(200), 100 * 72 + 100 * 112);
      expect(layout.offsetAt(1), 112.0);
      expect(layout.offsetAt(3), 112 + 72 + 112);
      // Every index agrees with a naive walk.
      var expected = 0.0;
      for (var i = 0; i < 300; i++) {
        expect(layout.offsetAt(i), expected, reason: 'row $i');
        expected += i.isEven ? 112 : 72;
      }
      expect(layout.total, expected);
    });
  });
}

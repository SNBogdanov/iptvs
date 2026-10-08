import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/media_duration.dart';

void main() {
  group('formatMediaDuration', () {
    test('renders H:MM:SS at an hour or above', () {
      expect(formatMediaDuration(1 * 3600 + 47 * 60 + 30), '1:47:30');
      expect(formatMediaDuration(2 * 3600 + 5 * 60 + 7), '2:05:07');
    });

    test('drops the hour field entirely below an hour', () {
      // A sub-hour clip is the compact form: the leading field is *absent*, not
      // padded to `0:` - a three-field shape padded like a clock reads as time
      // spent rather than time long. Keeping it in one test group makes the
      // boundary the assertion, not just the individual shapes.
      expect(formatMediaDuration(65), '01:05');
      expect(formatMediaDuration(59), '00:59');
      expect(formatMediaDuration(1), '00:01');
      expect(formatMediaDuration(59 * 60 + 59), '59:59');
      // Exactly an hour is where it flips back to the three-field shape.
      expect(formatMediaDuration(3600), '1:00:00');
      expect(formatMediaDuration(3601), '1:00:01');
    });

    test('pads minutes and seconds, never the hour', () {
      // A padded hour reads as a time of day rather than a runtime, and would
      // make `1:05:07` and `12:05:07` not line up.
      expect(formatMediaDuration(65 * 60), '1:05:00');
      expect(formatMediaDuration(3600), '1:00:00');
      expect(formatMediaDuration(10 * 3600 + 1), '10:00:01');
    });

    test('an absent or non-positive value prints nothing', () {
      // A portal reporting `0` means "unknown runtime"; `00:00` would state a
      // runtime nobody gave.
      expect(formatMediaDuration(null), isNull);
      expect(formatMediaDuration(0), isNull);
      expect(formatMediaDuration(-1), isNull);
    });
  });
}

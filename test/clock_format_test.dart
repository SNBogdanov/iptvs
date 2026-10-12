import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/clock_format.dart';
import 'package:iptvs/player/player_overlay.dart';

/// A Russian Windows install: the long date NLS produced from `d MMMM yyyy 'г.'`
/// (genitive month and all), and the `LOCALE_SSHORTTIME` picture.
ClockFormat _ru({DateTime? forDay}) => ClockFormat(
  longDate: '6 октября 2026 г.',
  dateFor: forDay ?? DateTime(2026, 10, 6),
  shortTime: 'H:mm',
  am: 'AM',
  pm: 'PM',
);

void main() {
  tearDown(() => debugClockFormat = null);

  group('ClockFormat time picture', () {
    test('24-hour short time, unpadded and padded', () {
      expect(_ru().format(DateTime(2026, 10, 6, 12, 34), dated: false), '12:34');
      expect(_ru().format(DateTime(2026, 10, 6, 9, 5), dated: false), '9:05');
    });

    test('12-hour picture uses the AM/PM designators', () {
      final f = ClockFormat(
        longDate: 'Tuesday, October 6, 2026',
        dateFor: DateTime(2026, 10, 6),
        shortTime: 'h:mm tt',
        am: 'AM',
        pm: 'PM',
      );
      expect(f.format(DateTime(2026, 10, 6, 9, 5), dated: false), '9:05 AM');
      expect(f.format(DateTime(2026, 10, 6, 21, 5), dated: false), '9:05 PM');
    });

    test('seconds, literals, escapes and an unmodelled token', () {
      ClockFormat f(String shortTime) => ClockFormat(
        longDate: 'd',
        dateFor: DateTime(2026, 10, 6),
        shortTime: shortTime,
        am: 'AM',
        pm: 'PM',
      );
      expect(
        f('HH:mm:ss').format(DateTime(2026, 10, 6, 7, 8, 9), dated: false),
        '07:08:09',
      );
      expect(
        f("'At' HH").format(DateTime(2026, 10, 6, 7, 8), dated: false),
        'At 07',
      );
      expect(f(r'H\H').format(DateTime(2026, 10, 6, 7, 8), dated: false), '7H');
      expect(
        f('H:mm X').format(DateTime(2026, 10, 6, 12, 34), dated: false),
        '12:34 X',
      );
    });
  });

  group('ClockFormat composition', () {
    test('the dated form is the native long date verbatim, then the time', () {
      expect(
        _ru().format(DateTime(2026, 10, 6, 12, 34), dated: true),
        '6 октября 2026 г. · 12:34',
      );
    });

    test('isForDay tracks the local day only', () {
      final f = _ru();
      expect(f.isForDay(DateTime(2026, 10, 6, 23, 59)), isTrue);
      expect(f.isForDay(DateTime(2026, 10, 7, 0, 0)), isFalse);
    });
  });

  group('ClockFormat.fromMap', () {
    Map<Object?, Object?> valid() => <Object?, Object?>{
      'longDate': '6 октября 2026 г.',
      'shortTime': 'H:mm',
      'am': 'AM',
      'pm': 'PM',
      'shortDate': 'dd.MM.yyyy',
    };

    test('accepts a complete map and stamps the local day', () {
      final f = ClockFormat.fromMap(valid(), DateTime(2026, 10, 6, 15, 0));
      expect(f, isNotNull);
      expect(f!.format(DateTime(2026, 10, 6, 12, 34), dated: true),
          '6 октября 2026 г. · 12:34');
      expect(f.dateFor.year, 2026);
      expect(f.dateFor.hour, 0);
    });

    test('carries the short-date picture for the VOD card', () {
      final f = ClockFormat.fromMap(valid(), DateTime(2026, 10, 6));
      expect(f!.shortDate, 'dd.MM.yyyy');
      expect(
        ClockFormat.fromMap(valid()..remove('shortDate'), DateTime(2026, 10, 6))!
            .shortDate,
        '',
        reason: 'an absent picture must not stop the clock badge from working',
      );
    });

    test('rejects a missing or blank pattern', () {
      expect(ClockFormat.fromMap(valid()..remove('longDate'), DateTime.now()), isNull);
      expect(ClockFormat.fromMap(valid()..['longDate'] = '', DateTime.now()), isNull);
      expect(ClockFormat.fromMap(valid()..['shortTime'] = '', DateTime.now()), isNull);
    });
  });

  group('playerClockLabel', () {
    test('uses the resolved format when present', () {
      debugClockFormat = _ru();
      expect(
        playerClockLabel(DateTime(2026, 10, 6, 12, 34), dated: true),
        '6 октября 2026 г. · 12:34',
      );
      expect(
        playerClockLabel(DateTime(2026, 10, 6, 12, 34), dated: false),
        '12:34',
      );
    });

    test('falls back to the English badge when nothing resolved', () {
      debugClockFormat = null;
      expect(
        playerClockLabel(DateTime(2026, 8, 8, 16, 2), dated: true),
        'Sat 8 Aug · 16:02',
      );
      expect(playerClockLabel(DateTime(2026, 8, 8, 16, 2), dated: false), '16:02');
    });
  });
}

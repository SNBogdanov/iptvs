// Printing a provider's release date the way the machine writes one.
//
// The provider picks the shape (`2026-09-29`, `29.09.2026`, a bare `2026`); the
// VOD card prints it back through the OS's short-date picture. These are pure
// tests over one function and one global, so nothing here needs a widget or a
// platform channel.

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/release_date.dart';

void main() {
  tearDown(() => systemShortDatePattern = null);

  group('releaseDateParts', () {
    test('reads a full ISO date', () {
      final parts = releaseDateParts('2026-09-29')!;
      expect(parts.year, 2026);
      expect(parts.month, 9);
      expect(parts.day, 29);
      expect(parts.hasDay, isTrue);
    });

    test('reads a bare year with no day', () {
      final parts = releaseDateParts('2026')!;
      expect(parts.year, 2026);
      expect(parts.month, isNull);
      expect(parts.day, isNull);
      expect(parts.hasDay, isFalse);
    });

    test('reads a truncated year-month as year plus month, no day', () {
      final parts = releaseDateParts('2026-09')!;
      expect(parts.year, 2026);
      expect(parts.month, 9);
      expect(parts.day, isNull);
      expect(parts.hasDay, isFalse);
    });

    test('is null for an absent or unusable value', () {
      expect(releaseDateParts(null), isNull);
      expect(releaseDateParts(''), isNull);
      expect(releaseDateParts('unknown'), isNull);
    });
  });

  group('formatReleaseDate', () {
    test('paints an ISO date in a day-first European picture', () {
      expect(
        formatReleaseDate('2026-09-29', pattern: 'dd.MM.yyyy'),
        '29.09.2026',
      );
    });

    test('paints an ISO date in a month-first American picture', () {
      expect(
        formatReleaseDate('2026-09-29', pattern: 'M/d/yyyy'),
        '9/29/2026',
      );
    });

    test('honours unpadded tokens and the ISO picture', () {
      expect(formatReleaseDate('2026-09-29', pattern: 'yyyy-M-d'), '2026-9-29');
    });

    test('zero-pads the two-digit year', () {
      expect(formatReleaseDate('2026-01-02', pattern: 'yy.MM.dd'), '26.01.02');
    });

    test('applies a time-ordered source date, not the source order', () {
      // Day-first in, ISO out: the parser and the picture are independent.
      expect(
        formatReleaseDate('29.09.2026', pattern: 'yyyy-MM-dd'),
        '2026-09-29',
      );
    });

    test('reads through a time tail', () {
      expect(
        formatReleaseDate('2026-09-29T18:04:11', pattern: 'dd.MM.yyyy'),
        '29.09.2026',
      );
    });

    test('honours quoted literals', () {
      expect(
        formatReleaseDate('2026-09-29', pattern: "yyyy'年'M'月'd'日'"),
        '2026年9月29日',
      );
    });

    test('honours a backslash escape', () {
      expect(formatReleaseDate('2026-09-29', pattern: r'\d.M.yyyy'), 'd.9.2026');
    });

    test('falls back to the global picture when no pattern is given', () {
      systemShortDatePattern = 'dd.MM.yyyy';
      expect(formatReleaseDate('2026-09-29'), '29.09.2026');
    });

    test('leaves the raw string when no picture resolved', () {
      // The non-Windows case, and the fail-closed default: unchanged behaviour.
      expect(formatReleaseDate('2026-09-29'), '2026-09-29');
      expect(formatReleaseDate('2026-09-29', pattern: ''), '2026-09-29');
    });

    test('leaves a year-only value alone', () {
      // Nothing extra to print: the picture needs a day and month.
      expect(formatReleaseDate('2026', pattern: 'dd.MM.yyyy'), '2026');
      expect(formatReleaseDate('2026-09', pattern: 'dd.MM.yyyy'), '2026-09');
    });

    test('leaves an unparseable value alone', () {
      expect(formatReleaseDate('n/a', pattern: 'dd.MM.yyyy'), 'n/a');
      expect(formatReleaseDate(null, pattern: 'dd.MM.yyyy'), '');
    });

    test('leaves an out-of-range month or day alone', () {
      expect(
        formatReleaseDate('2026-13-40', pattern: 'dd.MM.yyyy'),
        '2026-13-40',
      );
    });
  });
}

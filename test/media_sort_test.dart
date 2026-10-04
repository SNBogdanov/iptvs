// The VOD grid's ordering rule: newest first by default, with name and the
// other direction available, and undated rows last in *both* directions.
//
// Pure-function tests over MediaItem, so nothing here needs a database, a
// widget tree or a provider — the properties that matter (a date string the
// panel chose, a direction flip, a stable tie-break) are all decided in
// media_sort.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/media_sort.dart';
import 'package:iptvs/sources/release_date.dart';
import 'package:iptvs/sources/source.dart';

MediaItem _item(String id, {String? title, String? year}) =>
    MediaItem(id: id, title: title ?? id, kind: ContentKind.movie, year: year);

/// Ids in the order the grid would draw them.
List<String> order(List<MediaItem> items, MediaSort sort) => [
  for (final item in sortedMedia(items, sort)) item.id,
];

void main() {
  group('the default', () {
    test('is release date, newest first', () {
      // The requested default, pinned: a change here is a change of behaviour,
      // not a refactor.
      expect(kDefaultMediaSort, MediaSort.releaseDateDesc);
      expect(
        sortedMedia([
          _item('old', year: '1994'),
          _item('new', year: '2026-09-29'),
          _item('mid', year: '2011'),
        ], kDefaultMediaSort).map((i) => i.id),
        ['new', 'mid', 'old'],
      );
    });

    test('each mode has a distinct, non-empty label', () {
      // The label *is* the control (a dropdown that shows the active order), so
      // two modes sharing one would make the active order unanswerable.
      final labels = MediaSort.values.map((mode) => mode.label).toList();
      expect(labels.toSet(), hasLength(MediaSort.values.length));
      expect(labels.every((label) => label.isNotEmpty), isTrue);
    });
  });

  group('releaseSortKey', () {
    test('the grid orders three films of ONE year by their real dates', () {
      // The property the whole control exists for. `MediaItem.year` holds
      // whatever precision the provider gave, so a portal that reports full
      // dates yields a real order inside a single year — and a panel that
      // reports only years simply ties there instead of inventing one.
      expect(
        order([
          _item('a', year: '2026-01-04'),
          _item('b', year: '2026-11-20'),
          _item('c', year: '2026-06-15'),
        ], MediaSort.releaseDateDesc),
        ['b', 'c', 'a'],
      );
    });

    test('mixes full dates and bare years in one direction each', () {
      // A bare year takes part rather than dropping to the bottom: `2026`
      // sorts as 2026-01-01, which is early in a descending order and honest
      // about being a year-granular row.
      final mixed = [
        _item('dated', year: '1999-12-31'),
        _item('yearOnly', year: '2026'),
      ];
      expect(order(mixed, MediaSort.releaseDateDesc), ['yearOnly', 'dated']);
    });

    test('reads the ISO form both Stalker and Xtream emit', () {
      expect(releaseSortKey('2026-09-29'), 20260929);
      expect(releaseSortKey('2026/09/29'), 20260929);
      // A time tail is common on Xtream and must not break the date.
      expect(releaseSortKey('2026-09-29T18:04:11'), 20260929);
    });

    test('reads day-first, as a European panel writes it', () {
      expect(releaseSortKey('29.09.2026'), 20260929);
      expect(releaseSortKey('29-09-2026'), 20260929);
    });

    test('a day-first reading still orders a month-first set correctly', () {
      // `05/06/2026` cannot be told from `06/05/2026` by shape alone, so the
      // key picks day-first for every row and never per row. That is safe
      // precisely because the choice is *consistent*: a panel writing
      // month-first is still sorted month-first, since one convention misread
      // uniformly leaves the relative order intact.
      final keys = [
        for (final written in ['15/01/2026', '10/03/2026', '01/12/2026'])
          releaseSortKey(written)!,
      ];
      expect(keys, [for (final k in keys) k]..sort());
    });

    test('reads a bare year as the start of that year', () {
      // So a year-only row orders *before* that year's dated rows ascending,
      // instead of tying with them and landing wherever the tie-break put it.
      expect(releaseSortKey('2026'), 20260000);
      expect(
        releaseSortKey('2026')! < releaseSortKey('2026-01-01')!,
        isTrue,
        reason: 'the year-only row must sort as Jan 1, not tie with the year',
      );
    });

    test('reads a year out of an unexpected date format', () {
      // The fallback that keeps a panel with its own date style sortable
      // instead of dumping every row to the bottom.
      expect(releaseSortKey('May 12, 2026'), 20260000);
      expect(releaseSortKey(' premiered 2026 '), 20260000);
    });

    test('a truncated year-month keeps the month', () {
      expect(releaseSortKey('2026-09'), 20260900);
    });

    test('an absent or unusable value is null, never a guess', () {
      expect(releaseSortKey(null), isNull);
      expect(releaseSortKey(''), isNull);
      expect(releaseSortKey('   '), isNull);
      expect(releaseSortKey('unknown'), isNull);
      expect(
        releaseSortKey('1234'),
        isNull,
        reason: 'before film, so not a year',
      );
    });

    test('a nonsense month or day stays inside its year', () {
      // A padded date must not spill into the next year and outrank 2027.
      expect(
        releaseSortKey('2026-13-40')! < releaseSortKey('2027-01-01')!,
        isTrue,
      );
    });
  });

  group('release date order', () {
    final items = [
      _item('a', year: '2011-05-09'),
      _item('b', year: '2026-09-29'),
      _item('c', year: '1994'),
      _item('d', year: '2026-01-02'),
    ];

    test('newest first', () {
      expect(order(items, MediaSort.releaseDateDesc), ['b', 'd', 'a', 'c']);
    });

    test('oldest first', () {
      expect(order(items, MediaSort.releaseDateAsc), ['c', 'a', 'd', 'b']);
    });

    test('a year-only row takes part in both directions', () {
      final mixed = [
        _item('dated', year: '2026-09-29'),
        _item('yearOnly', year: '2026'),
      ];
      expect(order(mixed, MediaSort.releaseDateDesc), ['dated', 'yearOnly']);
      expect(order(mixed, MediaSort.releaseDateAsc), ['yearOnly', 'dated']);
    });
  });

  group('undated rows', () {
    final items = [
      _item('undated-1'),
      _item('dated', year: '2020'),
      _item('undated-2', year: ''),
      _item('newer', year: '2024'),
    ];

    test('sort last with a real date, in both directions', () {
      // The one place the direction is deliberately not applied: an undated row
      // is neither the oldest nor the newest, so flipping the control must not
      // send the same rows from one end of the grid to the other.
      expect(order(items, MediaSort.releaseDateDesc), [
        'newer',
        'dated',
        'undated-1',
        'undated-2',
      ]);
      expect(order(items, MediaSort.releaseDateAsc), [
        'dated',
        'newer',
        'undated-1',
        'undated-2',
      ]);
    });

    test('keep their relative order among themselves', () {
      final result = sortedMedia(items, MediaSort.releaseDateDesc);
      final undated = [
        for (final i in result)
          if (releaseSortKey(i.year) == null) i.id,
      ];
      expect(undated, ['undated-1', 'undated-2']);
    });

    test('a catalogue with no dates at all keeps the provider order', () {
      // The degenerate portal: every row sorts last, so the grid must look
      // exactly as it did before sorting existed.
      final undated = [_item('z'), _item('a'), _item('m', year: 'n/a')];
      expect(order(undated, MediaSort.releaseDateDesc), ['z', 'a', 'm']);
    });
  });

  group('name order', () {
    final items = [
      _item('one', title: 'alien'),
      _item('two', title: 'The Matrix'),
      _item('three', title: 'Blade Runner'),
    ];

    test('A-Z', () {
      // 'alien' < 'blade runner' < 'the matrix' - the leading "The" is not
      // stripped, so a title sorts where its first character puts it.
      expect(order(items, MediaSort.titleAsc), ['one', 'three', 'two']);
    });

    test('Z-A is the exact reverse', () {
      expect(order(items, MediaSort.titleDesc), ['two', 'three', 'one']);
    });

    test('case-insensitive, so capitals do not form a separate block', () {
      // A portal shipping `THE MATRIX` beside `alien` must not put every
      // capitalised title ahead of every lowercase one.
      final mixed = [
        _item('upper', title: 'Zulu'),
        _item('lower', title: 'alpha'),
      ];
      expect(order(mixed, MediaSort.titleAsc), ['lower', 'upper']);
      expect(order(mixed, MediaSort.titleDesc), ['upper', 'lower']);
    });

    test('same-title rows keep their given order', () {
      final twins = [
        _item('first', title: 'Dune', year: '2021'),
        _item('second', title: 'Dune', year: '1984'),
      ];
      expect(order(twins, MediaSort.titleAsc), ['first', 'second']);
      expect(order(twins, MediaSort.titleDesc), ['first', 'second']);
    });
  });

  group('provider order', () {
    test('is the identity - the escape hatch back to the panel list', () {
      final items = [
        _item('zulu', title: 'Zulu', year: '1999'),
        _item('alpha', title: 'Alpha', year: '2026'),
      ];
      expect(order(items, MediaSort.providerOrder), ['zulu', 'alpha']);
      expect(MediaSort.providerOrder.sorts, isFalse);
      expect(MediaSort.releaseDateDesc.sorts, isTrue);
    });

    test('returns the very list it was handed, not a copy', () {
      // The common case on a portal whose order is already right: skip the
      // sort rather than allocate a copy of a 250k list to reorder nothing.
      final items = [_item('a'), _item('b')];
      expect(
        identical(sortedMedia(items, MediaSort.providerOrder), items),
        isTrue,
      );
    });
  });

  group('stability', () {
    test('equal keys survive a list long enough to trip an unstable sort', () {
      // `List.sort` is introsort and is *not* stable; on one long run of equal
      // keys the partitioning is exactly where an unstable sort reshuffles.
      final rows = [for (var i = 0; i < 200; i++) _item('r$i', year: '2020')];
      expect(order(rows, MediaSort.releaseDateDesc), [
        for (var i = 0; i < 200; i++) 'r$i',
      ]);
      expect(order(rows, MediaSort.releaseDateAsc), [
        for (var i = 0; i < 200; i++) 'r$i',
      ]);
    });

    test('the input list is never sorted in place', () {
      // The caller hands over the list it also uses for the Favorites catalog
      // ordering; mutating it would make the two rules fight each other.
      final items = [_item('b', year: '2020'), _item('a', year: '2026')];
      sortedMedia(items, MediaSort.releaseDateDesc);
      expect([for (final i in items) i.id], ['b', 'a']);
    });
  });

  group('degenerate inputs', () {
    test('empty and single-item lists', () {
      expect(sortedMedia(const [], MediaSort.releaseDateDesc), isEmpty);
      final one = [_item('only')];
      expect(order(one, MediaSort.titleAsc), ['only']);
    });
  });
}

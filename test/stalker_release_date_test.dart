// Release-date precision: the catalogue card showed a bare "2026" while the
// *opened* item showed the real date. Not a stale card and not a render
// difference — the list mapper read `year` first, and this portal puts a
// deliberately year-only value in `year` while carrying the exact date next to
// it in `releasedate`/`release_date`/`releaseDate`. The details mapper already
// preferred the exact keys, so only the card lost the month and day.
//
// Drives the real `mediaItems`/`mediaDetails` path through the `debugApi` seam,
// so this pins the shipped mapping rather than a helper.

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';

void main() {
  StalkerSource portal(
    List<Map<String, dynamic>> rows, {
    Map<String, dynamic> details = const {},
  }) => StalkerSource(
    sourceId: 'stalker-test',
    portal: 'http://example.invalid/c/',
    mac: '00:1A:79:12:34:56',
    diagnostics: false,
    debugApi: (params) async {
      switch (params['action']) {
        case 'get_ordered_list':
          return {
            'js': {
              'total_items': rows.length,
              'max_page_items': 50,
              'data': [for (final r in rows) Map<String, dynamic>.from(r)],
            },
          };
        case 'get_movie_details':
          return {'js': Map<String, dynamic>.from(details)};
      }
      return const {'js': null};
    },
  );

  /// The row shape this portal actually sends: the date three times over,
  /// plus a year-only value in `year`.
  Map<String, dynamic> portalMovieRow(String id) => {
    'id': id,
    'name': 'Movie $id',
    'year': '2026',
    'releasedate': '2026-09-29',
    'release_date': '2026-09-29',
    'releaseDate': '2026-09-29',
  };

  test('movie: the exact date wins over the year-only field', () async {
    final items = await portal([portalMovieRow('73661')]).mediaItems(
      ContentKind.movie,
    );

    expect(items, hasLength(1));
    expect(items.single.year, '2026-09-29');
  });

  test('series: the same precedence as movies', () async {
    final items = await portal([
      {
        'id': '100001',
        'name': 'Series',
        'year': '2026',
        'releasedate': '2026-07-03',
      },
    ]).mediaItems(ContentKind.series);

    expect(items.single.year, '2026-07-03');
  });

  test('a year-only payload still parses, not dropped', () async {
    final items = await portal([
      {'id': '1', 'name': 'Old film', 'year': '1994'},
    ]).mediaItems(ContentKind.movie);

    expect(items.single.year, '1994');
  });

  test("the legacy `released` field is still honoured", () async {
    final items = await portal([
      {'id': '2', 'name': 'Legacy', 'year': '2011', 'released': '2011-05-09'},
    ]).mediaItems(ContentKind.movie);

    expect(items.single.year, '2011-05-09');
  });

  test('the card and the opened item agree — the reported symptom', () async {
    final source = portal(
      [portalMovieRow('73661')],
      details: {'year': '2026-09-29', 'description': 'plot'},
    );

    final listed = await source.mediaItems(ContentKind.movie);
    final opened = await source.mediaDetails(listed.single);

    expect(opened.year, '2026-09-29');
    expect(opened.year, listed.single.year);
  });
}

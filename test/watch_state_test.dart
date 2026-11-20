// WatchState / planWatchPull: the pure half of the watch-state cloud sync, i.e.
// what a pull is allowed to overwrite and what it must delete.

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/watch_state.dart';
import 'package:iptvs/sources/source.dart';

WatchState state(
  String itemId, {
  ContentKind kind = ContentKind.movie,
  String sourceId = 'src',
  int positionMs = 0,
  int durationMs = 0,
  bool watched = false,
}) => WatchState(
  sourceId: sourceId,
  kind: kind,
  itemId: itemId,
  positionMs: positionMs,
  durationMs: durationMs,
  watched: watched,
);

void main() {
  group('WatchState', () {
    test('ignores kinds without a timeline', () {
      expect(WatchState.accepts(ContentKind.movie), isTrue);
      expect(WatchState.accepts(ContentKind.episode), isTrue);
      expect(WatchState.accepts(ContentKind.live), isFalse);
      expect(WatchState.accepts(ContentKind.season), isFalse);
    });

    test('a row with no state is a clear, not an empty position', () {
      expect(state('m').cleared, isTrue);
      expect(state('m').asCleared().watched, isFalse);
      expect(state('m', positionMs: 1).cleared, isFalse);
      expect(state('m', watched: true).cleared, isFalse);
    });

    test('sameState ignores the local bookkeeping stamp', () {
      final a = WatchState(
        sourceId: 'src',
        kind: ContentKind.movie,
        itemId: 'm',
        positionMs: 1000,
        durationMs: 5000,
        updatedAtMs: 1,
      );
      final b = WatchState(
        sourceId: 'src',
        kind: ContentKind.movie,
        itemId: 'm',
        positionMs: 1000,
        durationMs: 5000,
        updatedAtMs: 999,
      );
      expect(a.sameState(b), isTrue);
      expect(a.sameState(state('m', positionMs: 2000)), isFalse);
    });

    test('the push element carries exactly the server columns', () {
      expect(state('m', positionMs: 9000, durationMs: 10000).toCloudJson(), {
        'source_id': 'src',
        'kind': 'movie',
        'item_id': 'm',
        'position_ms': 9000,
        'duration_ms': 10000,
        'watched': false,
      });
    });

    test('the display snapshot rides along only when known', () {
      final withMeta = state('m', positionMs: 9000, durationMs: 10000).withMeta(
        const WatchMeta(
          title: 'A film',
          year: '2026',
          poster: 'https://cdn.example/p.jpg',
        ),
      );
      expect(withMeta.toCloudJson(), {
        'source_id': 'src',
        'kind': 'movie',
        'item_id': 'm',
        'position_ms': 9000,
        'duration_ms': 10000,
        'watched': false,
        'title': 'A film',
        'year': '2026',
        'poster': 'https://cdn.example/p.jpg',
      });

      // Absent keys, not empty ones: the server must read "this device does not
      // know" and keep whatever another device stored.
      expect(
        state('m').withMeta(const WatchMeta()).toCloudJson(),
        isNot(contains('title')),
      );
    });

    test('metadata is clipped to the server bounds, never failing a push', () {
      final meta = WatchMeta(
        title: 't' * 600,
        year: 'y' * 40,
        poster: 'https://cdn.example/${'p' * 2100}',
        backdrop: 'https://cdn.example/${'b' * 2100}',
      ).clipped();
      expect(meta.title.length, 512);
      expect(meta.year.length, 32);
      expect(meta.poster.length, 2048);
      expect(meta.backdrop.length, 2048);

      final json = state('m').withMeta(meta).toCloudJson();
      expect((json['title'] as String).length, 512);
      expect((json['year'] as String).length, 32);
      expect((json['poster'] as String).length, 2048);
      expect((json['backdrop'] as String).length, 2048);
    });

    test('a non-http poster is dropped rather than sent', () {
      for (final poster in [
        'javascript:alert(1)',
        'data:image/png;base64,AAAA',
        'file:///c:/x.png',
        'ftp://host/x.png',
      ]) {
        final json = state(
          'm',
        ).withMeta(WatchMeta(poster: poster)).toCloudJson();
        expect(json, isNot(contains('poster')), reason: poster);
      }
    });

    test('the wide artwork rides along and is checked the same way', () {
      expect(
        state('m')
            .withMeta(const WatchMeta(backdrop: 'https://cdn.example/w.jpg'))
            .toCloudJson(),
        containsPair('backdrop', 'https://cdn.example/w.jpg'),
      );
      expect(
        state('m')
            .withMeta(const WatchMeta(backdrop: 'javascript:alert(1)'))
            .toCloudJson(),
        isNot(contains('backdrop')),
      );
    });

    test('a dragged-in rename is not a state change', () {
      final a = state('m', positionMs: 1000);
      final b = a.withMeta(const WatchMeta(title: 'Renamed'));
      expect(a.sameState(b), isTrue);
      expect(b.meta.title, 'Renamed');
    });

    test('parses a cloud row, coercing numeric strings', () {
      final parsed = WatchState.fromCloudRow({
        'source_id': 'src',
        'kind': 'episode',
        'item_id': 'e1',
        'position_ms': '61000',
        'duration_ms': 1800000,
        'watched': false,
      });
      expect(parsed, isNotNull);
      expect(parsed!.kind, ContentKind.episode);
      expect(parsed.positionMs, 61000);
      expect(parsed.durationMs, 1800000);
    });

    test('reads the display snapshot back, clipped', () {
      final parsed = WatchState.fromCloudRow({
        'source_id': 'src',
        'kind': 'movie',
        'item_id': 'm',
        'position_ms': 1,
        'duration_ms': 2,
        'watched': false,
        'title': 'A film',
        'year': '2026',
        'poster': 'https://cdn.example/p.jpg',
        'backdrop': 'https://cdn.example/w.jpg',
      });
      expect(parsed!.meta.title, 'A film');
      expect(parsed.meta.year, '2026');
      expect(parsed.meta.poster, 'https://cdn.example/p.jpg');
      expect(parsed.meta.backdrop, 'https://cdn.example/w.jpg');

      // A hostile/legacy row cannot smuggle a non-http scheme into the panel's
      // `<img src>`; the parse drops it like the push would.
      final unsafe = WatchState.fromCloudRow({
        'source_id': 'src',
        'kind': 'movie',
        'item_id': 'm',
        'position_ms': 1,
        'duration_ms': 2,
        'poster': 'javascript:alert(1)',
      });
      expect(unsafe!.meta.poster, isEmpty);
    });

    test('rejects rows it cannot apply instead of throwing', () {
      for (final row in <Map<String, dynamic>>[
        {'source_id': 'src', 'kind': 'live', 'item_id': 'c'},
        {'source_id': 'src', 'kind': 'nonsense', 'item_id': 'x'},
        {'source_id': 'src', 'kind': 'movie'},
        {'kind': 'movie', 'item_id': 'x'},
        {'source_id': 'src', 'kind': 'movie', 'item_id': ''},
      ]) {
        expect(WatchState.fromCloudRow(row), isNull, reason: '$row');
      }
    });

    test('negative or unparseable metrics become zero', () {
      final parsed = WatchState.fromCloudRow({
        'source_id': 'src',
        'kind': 'movie',
        'item_id': 'm',
        'position_ms': -5,
        'duration_ms': 'later',
      });
      expect(parsed!.positionMs, 0);
      expect(parsed.durationMs, 0);
      expect(parsed.cleared, isTrue);
    });
  });

  group('planWatchPull', () {
    test('writes a row the device does not have', () {
      final plan = planWatchPull(
        remote: [state('m', positionMs: 5000, durationMs: 9000)],
        local: const [],
        pending: const [],
      );
      expect(plan.writes.single.itemId, 'm');
      expect(plan.clears, isEmpty);
    });

    test('does nothing when both sides already agree', () {
      final plan = planWatchPull(
        remote: [state('m', positionMs: 5000, durationMs: 9000)],
        local: [state('m', positionMs: 5000, durationMs: 9000)],
        pending: const [],
      );
      expect(plan.isEmpty, isTrue);
    });

    test('the cloud wins over a local row that was never queued', () {
      // Not queued means "this device has nothing newer to say": its row is at
      // most as recent as the last pull, so remote is the truth.
      final plan = planWatchPull(
        remote: [state('m', watched: true)],
        local: [state('m', positionMs: 5000, durationMs: 9000)],
        pending: const [],
      );
      expect(plan.writes.single.watched, isTrue);
      expect(plan.clears, isEmpty);
    });

    test('a queued local change is left alone in both directions', () {
      final plan = planWatchPull(
        remote: [state('m', positionMs: 1000)],
        local: [state('m', positionMs: 2000), state('gone', watched: true)],
        pending: [state('m', positionMs: 2000), state('gone')],
      );
      expect(plan.isEmpty, isTrue, reason: 'the outbox wins until it is sent');
    });

    test('a local row the cloud lacks is a deletion to mirror', () {
      final plan = planWatchPull(
        remote: const [],
        local: [state('m', positionMs: 5000)],
        pending: const [],
      );
      expect(plan.writes, isEmpty);
      expect(plan.clears.single.itemId, 'm');
      expect(plan.clears.single.cleared, isTrue);
    });

    test('a cleared remote element deletes rather than stores', () {
      final plan = planWatchPull(
        remote: [state('m')],
        local: [state('m', positionMs: 5000)],
        pending: const [],
      );
      expect(plan.writes, isEmpty);
      expect(plan.clears.single.itemId, 'm');
    });

    test('ignores kinds and sources the sync never carries', () {
      final plan = planWatchPull(
        remote: [
          state('c', kind: ContentKind.live),
          state('s', kind: ContentKind.season),
        ],
        local: [state('c', kind: ContentKind.live)],
        pending: const [],
      );
      expect(plan.isEmpty, isTrue);
    });

    test('keys include the source, so equal ids do not collide', () {
      final plan = planWatchPull(
        remote: [state('1', sourceId: 'a', positionMs: 1)],
        local: [state('1', sourceId: 'b', positionMs: 1)],
        pending: const [],
      );
      expect(plan.writes.single.sourceId, 'a');
      expect(plan.clears.single.sourceId, 'b');
    });
  });
}

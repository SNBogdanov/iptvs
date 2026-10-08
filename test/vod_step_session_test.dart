// Bounds and ordering for the VOD previous/next step — the pure half of
// `VodStepSession`, pinned without a player, a widget, or a provider.
//
// The load-bearing case is the clamp: a live zap wraps at both ends (there is no
// end to the channel list), a VOD step must not (episode 1 stepping back into
// the previous season is a surprise). Everything else here exists so that
// difference cannot be lost in a refactor.

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/vod_step_session.dart';
import 'package:iptvs/sources/source.dart';

MediaItem _item(String id) => MediaItem(
  id: id,
  title: id,
  kind: ContentKind.episode,
);

VodStepSession _session(List<String> ids, {int index = 0}) => VodStepSession(
  items: [for (final id in ids) _item(id)],
  index: index,
  resolve: (_) async => null,
);

void main() {
  group('a step inside the list resolves to the immediate sibling', () {
    test('forward is the next row, backward the previous one', () {
      final session = _session(['a', 'b', 'c'], index: 1);
      expect(session.neighbour(previous: false)?.id, 'c');
      expect(session.neighbour(previous: true)?.id, 'a');
    });

    test('the first and last rows have only one neighbour each', () {
      final first = _session(['a', 'b', 'c']);
      expect(first.neighbour(previous: false)?.id, 'b');
      expect(first.neighbour(previous: true), isNull);

      expect(_session(['a', 'b', 'c'], index: 2).neighbour(previous: true)?.id, 'b');
      expect(_session(['a', 'b', 'c'], index: 2).neighbour(previous: false), isNull);
    });
  });

  group('a VOD list has ends — it never wraps', () {
    // The counterpart to `liveZapIndex`, which wraps at both ends on purpose.
    test('stepping back off the first row returns nothing', () {
      final only = _session(['only']);
      expect(only.neighbour(previous: true), isNull);
      expect(only.neighbour(previous: false), isNull);
    });

    test('a single-item list answers neither direction', () {
      expect(vodStepIndex(length: 1, index: 0, previous: false), isNull);
      expect(vodStepIndex(length: 1, index: 0, previous: true), isNull);
    });

    test('the order is the caller\'s, not re-sorted here', () {
      // Deliberately unsorted: a step must follow the list as given. Re-deriving
      // an order here is the second-copy bug this class doc rules out — the
      // launching surface already owns the rule.
      final session = _session(['s2e05', 's2e01', 's1e02'], index: 0);
      // `s2e01`, not the numerically-first sibling: list order, not sorted order.
      expect(session.neighbour(previous: false)?.id, 's2e01');

      // And the start really is the start: no wrap back to `s1e02` or `s2e05`.
      expect(session.neighbour(previous: true), isNull);
    });
  });

  group('a session that cannot answer says so instead of guessing', () {
    test('an out-of-range cursor resolves to nothing', () {
      // `vodStepIndex` directly, bypassing the constructor assert deliberately:
      // a corrupt cursor must be inert, not an out-of-bounds read from a list
      // the user is looking at.
      expect(vodStepIndex(length: 3, index: 3, previous: true), isNull);
      expect(vodStepIndex(length: 3, index: -1, previous: false), isNull);
    });

    test('an empty list resolves to nothing in either direction', () {
      final session = _session([]);
      expect(session.isEmpty, isTrue);
      expect(session.neighbour(previous: false), isNull);
      expect(session.neighbour(previous: true), isNull);
    });
  });
}

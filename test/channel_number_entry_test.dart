// Typed channel numbers: which channel the digits resolve to, and when the
// buffer commits. Pure logic over a catalog, so everything here is a table.
//
// The rules that are easy to get wrong, and are pinned below:
//
//   * **Exact beats prefix, wherever each sits in the list.** `2001` listed
//     before `200` must not swallow a typed `200` that means the real `200`.
//   * **A partial number resolves to the first prefix match in catalog order** —
//     `200` with no `200` lands on `2001`.
//   * **The search space is the whole catalog, not the visible page.**
//   * **Four digits with a match commit on the keystroke**; shorter ones wait
//     for another digit, and the timeout is the backstop.
//   * **A commit with no match is a no-op** — the chip has already said
//     `No Data Found`, and it must never jump to whatever was selected.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/channel_number_entry.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  Channel ch(String id, String name, int? number) =>
      Channel(id: id, name: name, number: number);

  /// A catalog whose numbers are what the test name says they are.
  List<Channel> numbered(int count, {int start = 1}) => [
    for (final n in Iterable.generate(count, (i) => start + i))
      ch('c$n', 'Channel $n', n),
  ];

  group('matchChannelNumber', () {
    test('an exact number matches wherever it sits in the list', () {
      final list = [ch('a', 'A', 2001), ch('b', 'B', 200), ch('c', 'C', 2002)];
      expect(matchChannelNumber(list, '200')?.id, 'b');
    });

    test('a partial number lands on the first prefix match', () {
      final list = [ch('a', 'A', 100), ch('b', 'B', 2001), ch('c', 'C', 2002)];
      expect(matchChannelNumber(list, '200')?.id, 'b');
      expect(matchChannelNumber(list, '20')?.id, 'b');
      expect(matchChannelNumber(list, '2')?.id, 'b');
    });

    test('the exact match wins even when a prefix match comes first', () {
      // The case the two-pass rule exists for: typing `200` to reach `2001` is
      // the answer only while no channel numbered exactly `200` exists.
      final withoutExact = [ch('a', 'A', 2001), ch('b', 'B', 2002)];
      expect(matchChannelNumber(withoutExact, '200')?.id, 'a');
      final withExact = [ch('a', 'A', 2001), ch('b', 'B', 200)];
      expect(matchChannelNumber(withExact, '200')?.id, 'b');
    });

    test('no digits, no channels, and numberless channels never match', () {
      expect(matchChannelNumber(numbered(3), ''), isNull);
      expect(matchChannelNumber(const [], '1'), isNull);
      expect(matchChannelNumber([ch('a', 'A', null)], '1'), isNull);
      expect(matchChannelNumber(numbered(3), '9'), isNull);
    });

    test('matching scans the whole catalog, not the visible page', () {
      // The host passes its whole list; a number reaches a channel the current
      // group does not draw.
      final all = [ch('a', 'A', 1), ch('b', 'B', 77), ch('c', 'C', 3)];
      final visible = [all[0], all[2]];
      expect(matchChannelNumber(visible, '77'), isNull);
      expect(matchChannelNumber(all, '77')?.id, 'b');
    });
  });

  group('planNumberJumpGroup', () {
    const favorites = 'favorites';

    // The screen's own view of which group would draw a channel: a category
    // draws its own channels, "All channels" draws everything not hidden, and
    // Favorites draws favorites even from a hidden category.
    bool Function(String?) drawsFor({
      String? categoryId,
      bool hidden = false,
      bool favorite = false,
    }) {
      bool draw(String? group) {
        if (group == favorites) return favorite;
        if (group == null) return !hidden;
        return group == categoryId;
      }

      return draw;
    }

    test('a channel already in the current group does not move the sidebar', () {
      final group = planNumberJumpGroup(
        currentGroupId: 'news',
        drawsTarget: drawsFor(categoryId: 'news'),
        favoritesGroupId: favorites,
      );
      expect(group, 'news');
    });

    test('a channel in another group falls back to All channels', () {
      final group = planNumberJumpGroup(
        currentGroupId: 'news',
        drawsTarget: drawsFor(categoryId: 'sport'),
        favoritesGroupId: favorites,
      );
      expect(group, isNull, reason: 'null is "All channels"');
    });

    test('a favorite in a disabled category falls back to Favorites', () {
      // "All channels" cannot draw it (the category is disabled) but the
      // Favorites view is drawn from disabled categories on purpose, so it is
      // the last view that can show the channel the number named.
      final group = planNumberJumpGroup(
        currentGroupId: 'news',
        drawsTarget: drawsFor(categoryId: 'sport', hidden: true, favorite: true),
        favoritesGroupId: favorites,
      );
      expect(group, favorites);
    });

    test('a channel in a disabled category that is not a favorite stays put', () {
      // Nothing can draw it, and re-enabling a category the user turned off is
      // not a keystroke's decision — so the ladder changes nothing and the
      // caller selects nothing.
      final group = planNumberJumpGroup(
        currentGroupId: 'news',
        drawsTarget: drawsFor(categoryId: 'sport', hidden: true),
        favoritesGroupId: favorites,
      );
      expect(group, 'news');
    });

    test('the cross-source view keeps its own rows', () {
      // Its rows are a cache read across sources rather than a filter over the
      // loaded catalog, so it is already drawing whatever the number matched and
      // needs no group switch.
      final group = planNumberJumpGroup(
        currentGroupId: 'all-sources',
        drawsTarget: (id) => id == 'all-sources',
        favoritesGroupId: favorites,
      );
      expect(group, 'all-sources');
    });

    test('a null favorites view is simply not a rung', () {
      final group = planNumberJumpGroup(
        currentGroupId: 'news',
        drawsTarget: drawsFor(categoryId: 'sport', hidden: true, favorite: true),
      );
      expect(group, 'news');
    });
  });

  group('ChannelNumberEntry', () {
    late List<String> committed;

    ChannelNumberEntry make(List<Channel> Function() catalog) {
      committed = <String>[];
      return ChannelNumberEntry(
        channels: catalog,
        onCommitted: (c) => committed.add(c.id),
      );
    }

    test('the chip names the match while the number is still being typed', () {
      final entry = make(() => numbered(3));
      addTearDown(entry.dispose);

      entry.appendDigit(2);
      expect(entry.digits, '2');
      expect(entry.match?.id, 'c2');
      expect(entry.matchLabel, 'Channel 2');
      expect(committed, isEmpty, reason: 'a partial number does not commit');
    });

    test('the chip says No Data Found when nothing matches', () {
      final entry = make(() => numbered(3));
      addTearDown(entry.dispose);

      entry.appendDigit(9);
      expect(entry.match, isNull);
      expect(entry.matchLabel, kNoChannelNumberMatch);
      expect(kNoChannelNumberMatch, 'No Data Found');
    });

    test('four digits hold for a beat before switching, so the digits are '
        'readable', () {
      fakeAsync((async) {
        final entry = make(() => numbered(2500));
        addTearDown(entry.dispose);

        entry.appendDigit(1);
        entry.appendDigit(2);
        entry.appendDigit(3);
        expect(committed, isEmpty);
        entry.appendDigit(4);

        // Nothing may have switched yet: the commit is also what swaps the
        // picture and takes the chip down with it, so an instant commit leaves
        // the digits on screen for a single frame.
        expect(committed, isEmpty);
        expect(entry.digits, '1234', reason: 'still readable, still correctable');
        expect(entry.match, isNotNull, reason: 'the landing channel is previewed');

        async.elapse(kChannelNumberFullLengthCommitDelay);
        expect(committed, ['c1234']);
        expect(entry.digits, isEmpty, reason: 'the buffer is consumed');
        expect(entry.match, isNull);
      });
    });

    test('a partial number still waits the full timeout', () {
      // The counterpart to the hold above: shortening the full-length pause must
      // not have shortened every other commit, or a half-typed number would
      // switch under the next digit.
      fakeAsync((async) {
        final entry = make(() => numbered(2500));
        addTearDown(entry.dispose);

        entry.appendDigit(1);
        async.elapse(kChannelNumberFullLengthCommitDelay);
        expect(
          committed,
          isEmpty,
          reason: 'one digit is not a full-length number',
        );

        async.elapse(kChannelNumberCommitDelay);
        expect(committed, ['c1'], reason: 'the partial timeout still applies');
      });
    });

    test('the full-length hold is shorter than the partial timeout', () {
      // A partial number may still be extended, so it waits out that
      // possibility; a full-length one cannot, so the shorter pause is buying
      // read time and nothing else. If these ever equal, the constant that
      // documents the difference is lying.
      expect(
        kChannelNumberFullLengthCommitDelay,
        lessThan(kChannelNumberCommitDelay),
        reason: 'a full-length number has no next digit to wait for',
      );
    });

    test('a full-length number is abandonable during the hold', () {
      // The reason the hold exists: a mis-typed fourth digit is recoverable,
      // which an on-the-keystroke commit made impossible.
      fakeAsync((async) {
        final entry = make(() => numbered(2500));
        addTearDown(entry.dispose);

        for (final d in [1, 2, 3, 4]) {
          entry.appendDigit(d);
        }
        entry.clear();
        async.elapse(kChannelNumberFullLengthCommitDelay);

        expect(
          committed,
          isEmpty,
          reason: 'the timer was cancelled with the buffer',
        );
      });
    });

    test('four digits with no match wait for the timeout, then give up', () {
      final entry = make(() => numbered(3));
      addTearDown(entry.dispose);

      for (final d in [9, 9, 9, 9]) {
        entry.appendDigit(d);
      }
      expect(entry.isActive, isTrue, reason: 'nothing resolved it');
      expect(committed, isEmpty);

      entry.commit();
      expect(committed, isEmpty, reason: 'no match means no jump');
      expect(entry.digits, isEmpty);
    });

    test('more than four digits are refused', () {
      final entry = make(() => numbered(1));
      addTearDown(entry.dispose);

      entry.appendDigit(1);
      for (var i = 0; i < 5; i++) {
        entry.appendDigit(1);
      }
      expect(entry.digits, '1111');
    });

    test('the timeout commits the pending match', () {
      fakeAsync((async) {
        final entry = make(() => numbered(3));
        entry.appendDigit(3);
        expect(committed, isEmpty);
        async.elapse(kChannelNumberCommitDelay + const Duration(milliseconds: 1));
        expect(committed, ['c3']);
        expect(entry.digits, isEmpty);
        entry.dispose();
      });
    });

    test('each digit restarts the timeout', () {
      fakeAsync((async) {
        final entry = make(() => numbered(99));
        entry.appendDigit(1);
        async.elapse(kChannelNumberCommitDelay ~/ 2);
        entry.appendDigit(2);
        async.elapse(kChannelNumberCommitDelay ~/ 2);
        expect(committed, isEmpty, reason: 'the clock restarted on the 2nd digit');
        async.elapse(kChannelNumberCommitDelay ~/ 2 + const Duration(seconds: 1));
        expect(committed, ['c12']);
        entry.dispose();
      });
    });

    test('Enter takes the number, and only while one is being typed', () {
      final entry = make(() => numbered(3));
      addTearDown(entry.dispose);

      expect(
        entry.handleKey(keyDownEvent(LogicalKeyboardKey.enter)),
        isFalse,
        reason: 'no number up: the key belongs to the surface',
      );

      entry.appendDigit(2);
      expect(entry.handleKey(keyDownEvent(LogicalKeyboardKey.enter)), isTrue);
      expect(committed, ['c2']);
      expect(entry.digits, isEmpty);
    });

    test('numpad and Select confirm the same way', () {
      for (final key in [
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.select,
      ]) {
        final entry = make(() => numbered(3));
        addTearDown(entry.dispose);
        entry.appendDigit(2);
        expect(entry.handleKey(keyDownEvent(key)), isTrue);
        expect(committed, ['c2']);
      }
    });

    test('digits from the numpad and the digit row are the same digit', () {
      final entry = make(() => numbered(99));
      addTearDown(entry.dispose);

      expect(entry.handleKey(keyDownEvent(LogicalKeyboardKey.digit4)), isTrue);
      expect(entry.handleKey(keyDownEvent(LogicalKeyboardKey.numpad2)), isTrue);
      expect(entry.digits, '42');
      expect(entry.match?.id, 'c42');
    });

    test('a held digit does not append on repeat or key-up', () {
      final entry = make(() => numbered(9));
      addTearDown(entry.dispose);

      expect(entry.handleKey(keyDownEvent(LogicalKeyboardKey.digit4)), isTrue);
      expect(
        entry.handleKey(
          KeyRepeatEvent(
            physicalKey: PhysicalKeyboardKey.digit4,
            logicalKey: LogicalKeyboardKey.digit4,
            timeStamp: Duration.zero,
          ),
        ),
        isTrue,
      );
      expect(entry.handleKey(keyUpEvent(LogicalKeyboardKey.digit4)), isTrue);
      expect(entry.digits, '4');
    });

    test('a non-number key is left to the surface', () {
      final entry = make(() => numbered(3));
      addTearDown(entry.dispose);

      expect(
        entry.handleKey(keyDownEvent(LogicalKeyboardKey.arrowDown)),
        isFalse,
      );
      expect(entry.isActive, isFalse);
    });

    test('the match follows a reloaded catalog', () {
      var catalog = numbered(3);
      final entry = make(() => catalog);
      addTearDown(entry.dispose);

      entry.appendDigit(2);
      expect(entry.match?.id, 'c2');
      // A refresh replaces the list; the chip must not keep naming a channel the
      // cache no longer has.
      catalog = [ch('x', 'Renumbered', 2)];
      entry.clear();
      entry.appendDigit(2);
      expect(entry.match?.id, 'x');
    });

    test('clear drops the buffer without committing', () {
      final entry = make(() => numbered(3));
      addTearDown(entry.dispose);

      entry.appendDigit(2);
      entry.clear();

      expect(entry.digits, isEmpty);
      expect(entry.match, isNull);
      expect(committed, isEmpty);
    });

    test('the entry publishes only while the buffer changes', () {
      final entry = make(() => numbered(3));
      addTearDown(entry.dispose);
      var pulses = 0;
      entry.addListener(() => pulses++);

      entry.appendDigit(2);
      expect(pulses, 1);
      entry.clear();
      expect(pulses, 2);
      entry.clear();
      expect(
        pulses,
        2,
        reason: 'clearing an already-clear buffer is not a change',
      );
    });
  });
}

KeyEvent keyDownEvent(LogicalKeyboardKey key) => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.digit0,
  logicalKey: key,
  timeStamp: Duration.zero,
);

KeyEvent keyUpEvent(LogicalKeyboardKey key) => KeyUpEvent(
  physicalKey: PhysicalKeyboardKey.digit0,
  logicalKey: key,
  timeStamp: Duration.zero,
);

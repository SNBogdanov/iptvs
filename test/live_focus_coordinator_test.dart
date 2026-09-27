// The live tab's D-pad contract, as pure selection logic.
//
// The channel list and the category sidebar are selection models (one focus node
// + a selected index each), so navigation is synchronous integer maths — no
// lazy-list focus race to mock. The rules these pin are deliberately asymmetric:
//
//   * **Down wraps** at the end of both lists — the only infinite motion.
//   * **Up never wraps.** At the first row it *escapes upward* (categories → the
//     search box; channels → the preview controls, or the search box on a phone).
//     The old design wrapped Up too, which is what left users "stuck in the
//     categories" with no way out but Right or Back.
//   * The channel cursor has an **intra-row favorite column**: Right enters the
//     row's star, Left peels back to the body before crossing panes, OK acts on
//     the column, and vertical moves always land back on the body.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/channel_number_entry.dart';
import 'package:iptvs/screens/live_focus_coordinator.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Channel> channels(List<String> ids) => [
    for (final (i, id) in ids.indexed)
      Channel(id: id, name: 'Ch $id', number: i + 1),
  ];

  /// A coordinator over [visible] channels and [categories] (plus the implicit
  /// "All channels" at index 0). [wide] toggles the sidebar/preview layout.
  ///
  /// [all] is the catalog number entry searches — the whole list, which is
  /// deliberately *not* the visible page (see `LiveFocusCoordinator.allChannels`).
  /// It defaults to [visible] so the navigation tests don't have to restate it.
  ({
    LiveFocusCoordinator focus,
    List<String> played,
    List<String> toggled,
    List<String> committed,
    List<String?> activated,
    int Function() tabsFocused,
    void Function(List<Channel>) replaceVisible,
    void Function(List<Channel>) replaceAll,
    ScrollController channelScroll,
  })
  make({
    List<Channel> visible = const [],
    List<String?> categories = const [null],
    bool wide = true,
    List<Channel>? all,
  }) {
    final played = <String>[];
    final toggled = <String>[];
    final committed = <String>[];
    final activated = <String?>[];
    var currentVisible = visible;
    var currentAll = all ?? visible;
    var tabs = 0;
    // Held so a test can mount a real list on it: `_reveal` is a no-op without
    // attached clients, and "the reveal happened" is the whole point of the
    // deferred-reveal group below.
    final channelScroll = ScrollController();
    addTearDown(channelScroll.dispose);
    final focus = LiveFocusCoordinator(
      scrollController: channelScroll,
      categoryScrollController: ScrollController(),
      visibleChannels: () => currentVisible,
      allChannels: () => currentAll,
      orderedCategoryIds: () => categories,
      channelRowExtent: () => 100,
      categoryRowExtent: () => 48,
      isWide: () => wide,
      isMounted: () => true,
      onChannelSelectionChanged: (_, _) {},
      onCategoryActivated: activated.add,
      onPlayChannel: (c) => played.add(c.id),
      onToggleFavorite: (c) => toggled.add(c.id),
      onNumberCommitted: (c) => committed.add(c.id),
      onFocusTabs: () => tabs++,
    );
    return (
      focus: focus,
      played: played,
      toggled: toggled,
      committed: committed,
      activated: activated,
      tabsFocused: () => tabs,
      channelScroll: channelScroll,
      replaceVisible: (replacement) => currentVisible = replacement,
      replaceAll: (replacement) => currentAll = replacement,
    );
  }

  KeyEvent keyDown(LogicalKeyboardKey key) => KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: key,
    timeStamp: Duration.zero,
  );

  KeyEvent keyRepeat(LogicalKeyboardKey key) => KeyRepeatEvent(
    physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: key,
    timeStamp: Duration.zero,
  );

  // Attach the coordinator's nodes to a real tree so `hasFocus` / `context` work.
  Future<void> host(
    WidgetTester tester,
    LiveFocusCoordinator focus, {
    bool withPreview = true,
    ScrollController? channelList,
    int itemCount = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Focus(
                focusNode: focus.searchCellFocusNode,
                child: const SizedBox(width: 10, height: 10),
              ),
              if (withPreview)
                Focus(
                  focusNode: focus.previewFavoriteFocusNode,
                  child: const SizedBox(width: 10, height: 10),
                ),
              Focus(
                focusNode: focus.categoriesFocusNode,
                child: const SizedBox(width: 10, height: 10),
              ),
              Focus(
                focusNode: focus.channelsFocusNode,
                child: const SizedBox(width: 10, height: 10),
              ),
              if (channelList != null)
                // The real list, at the coordinator's own row extent: the reveal
                // is `index * extent` arithmetic against this viewport.
                Expanded(
                  child: ListView.builder(
                    controller: channelList,
                    itemExtent: 100,
                    itemCount: itemCount,
                    itemBuilder: (_, i) => SizedBox(height: 100, child: Text('row $i')),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  group('channel list', () {
    testWidgets('async replacement retains the selected channel by id', (
      tester,
    ) async {
      final h = make(visible: channels(['a', 'b', 'c']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.selectChannel(1);
      expect(h.focus.selectedChannelId, 'b');

      h.replaceVisible(channels(['new', 'a', 'b', 'c']));
      h.focus.clampSelection();

      expect(h.focus.selectedChannelId, 'b');
      expect(h.focus.selectedChannelIndex, 2);
    });

    testWidgets('Down walks the list and WRAPS past the last row', (
      tester,
    ) async {
      final h = make(visible: channels(['a', 'b', 'c']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();

      expect(h.focus.selectedChannelIndex, 0);
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      expect(h.focus.selectedChannelIndex, 1);
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      expect(h.focus.selectedChannelIndex, 2);
      // Past the last row: wraps to the top. This is the one infinite motion.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      expect(h.focus.selectedChannelIndex, 0);
      expect(h.focus.region, LiveFocusRegion.channels);
    });

    testWidgets('Up walks back but NEVER wraps — at the top it escapes to the '
        'preview controls', (tester) async {
      final h = make(visible: channels(['a', 'b', 'c']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.selectChannel(2);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      expect(h.focus.selectedChannelIndex, 1);
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      expect(h.focus.selectedChannelIndex, 0);

      // At the first row Up climbs OUT — it must not wrap to the last row.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      await tester.pump();
      expect(h.focus.selectedChannelIndex, 0, reason: 'no wrap-around');
      expect(h.focus.region, LiveFocusRegion.previewControls);
    });

    testWidgets(
      'on a phone (no preview panel) Up from the top escapes to search',
      (tester) async {
        final h = make(visible: channels(['a', 'b']), wide: false);
        addTearDown(h.focus.dispose);
        await host(tester, h.focus, withPreview: false);
        h.focus.focusChannels();
        await tester.pump();

        h.focus.handleChannelsKey(
          h.focus.channelsFocusNode,
          keyDown(LogicalKeyboardKey.arrowUp),
        );
        await tester.pump();
        expect(h.focus.selectedChannelIndex, 0);
        expect(h.focus.region, LiveFocusRegion.search);
      },
    );

    testWidgets('Left crosses to the categories (wide only)', (tester) async {
      final h = make(visible: channels(['a']), categories: [null, 'news']);
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowLeft),
      );
      await tester.pump();
      expect(h.focus.region, LiveFocusRegion.categories);
    });
  });

  // The per-row favorite star: the channel cursor has two intra-row columns
  // (body / favorite). Right enters the star, Left peels back before crossing
  // panes, OK acts on whichever column holds the cursor, and every vertical
  // move resets to the body so the star column is never sticky across rows.
  group('intra-row favorite column', () {
    testWidgets('held activation cannot play or toggle twice', (tester) async {
      final h = make(visible: channels(['a']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.select),
      );
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyRepeat(LogicalKeyboardKey.select),
      );
      expect(h.played, ['a']);

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.select),
      );
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyRepeat(LogicalKeyboardKey.select),
      );
      expect(h.toggled, ['a']);
    });

    testWidgets('Right moves body → favorite; a second Right is consumed '
        'without change', (tester) async {
      final h = make(visible: channels(['a', 'b']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();
      expect(h.focus.channelColumn, ChannelRowColumn.body);

      final first = h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(first, KeyEventResult.handled);
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);

      // Already on the star: still consumed (geometry traversal must never
      // run in the live body), but nothing changes.
      final second = h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(second, KeyEventResult.handled);
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);
      expect(h.focus.region, LiveFocusRegion.channels);
    });

    testWidgets('Left peels favorite → body, and only then crosses to the '
        'categories (two-stage)', (tester) async {
      final h = make(visible: channels(['a']), categories: [null, 'news']);
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);

      // First Left: back onto the row body, still in the channel pane.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowLeft),
      );
      await tester.pump();
      expect(h.focus.channelColumn, ChannelRowColumn.body);
      expect(h.focus.region, LiveFocusRegion.channels);

      // Second Left: crosses into the sidebar.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowLeft),
      );
      await tester.pump();
      expect(h.focus.region, LiveFocusRegion.categories);
    });

    testWidgets('OK plays on the body and toggles on the favorite column', (
      tester,
    ) async {
      final h = make(visible: channels(['a', 'b']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();

      // Body: OK plays.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.select),
      );
      expect(h.played, ['a']);
      expect(h.toggled, isEmpty);

      // Favorite column: OK toggles instead of playing.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.select),
      );
      expect(h.toggled, ['a']);
      expect(h.played, ['a'], reason: 'the star press must not also play');
    });

    testWidgets('vertical moves reset the column to the body', (tester) async {
      final h = make(visible: channels(['a', 'b', 'c']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.selectChannel(1);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      expect(h.focus.selectedChannelIndex, 2);
      expect(h.focus.channelColumn, ChannelRowColumn.body);

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      expect(h.focus.selectedChannelIndex, 1);
      expect(h.focus.channelColumn, ChannelRowColumn.body);
    });

    testWidgets('Up-escape at the first row also resets the column', (
      tester,
    ) async {
      final h = make(visible: channels(['a', 'b']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      await tester.pump();
      expect(h.focus.region, LiveFocusRegion.previewControls);
      expect(h.focus.channelColumn, ChannelRowColumn.body);
    });
  });

  group('category sidebar', () {
    testWidgets('Down walks the sidebar and WRAPS past the last row', (
      tester,
    ) async {
      final h = make(
        visible: channels(['a']),
        categories: [null, 'news', 'kids'],
      );
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusCategories();
      await tester.pump();

      expect(h.focus.selectedCategoryIndex, 0);
      for (var i = 1; i < 3; i++) {
        h.focus.handleCategoriesKey(
          h.focus.categoriesFocusNode,
          keyDown(LogicalKeyboardKey.arrowDown),
        );
        expect(h.focus.selectedCategoryIndex, i);
      }
      h.focus.handleCategoriesKey(
        h.focus.categoriesFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      expect(h.focus.selectedCategoryIndex, 0, reason: 'Down wraps');
    });

    testWidgets(
      'Up NEVER wraps — at the first category it escapes to the search box '
      '(the "stuck in categories" fix)',
      (tester) async {
        final h = make(
          visible: channels(['a']),
          categories: [null, 'news', 'kids'],
        );
        addTearDown(h.focus.dispose);
        await host(tester, h.focus);
        h.focus.selectCategory(2);
        h.focus.focusCategories();
        await tester.pump();

        h.focus.handleCategoriesKey(
          h.focus.categoriesFocusNode,
          keyDown(LogicalKeyboardKey.arrowUp),
        );
        expect(h.focus.selectedCategoryIndex, 1);
        h.focus.handleCategoriesKey(
          h.focus.categoriesFocusNode,
          keyDown(LogicalKeyboardKey.arrowUp),
        );
        expect(h.focus.selectedCategoryIndex, 0);

        // The old model wrapped here, trapping the user. Now it climbs out.
        h.focus.handleCategoriesKey(
          h.focus.categoriesFocusNode,
          keyDown(LogicalKeyboardKey.arrowUp),
        );
        await tester.pump();
        expect(
          h.focus.selectedCategoryIndex,
          0,
          reason: 'must not wrap to the last category',
        );
        expect(h.focus.region, LiveFocusRegion.search);
      },
    );

    testWidgets('Right crosses into the channel list', (tester) async {
      final h = make(visible: channels(['a', 'b']), categories: [null, 'news']);
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusCategories();
      await tester.pump();

      h.focus.handleCategoriesKey(
        h.focus.categoriesFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      await tester.pump();
      expect(h.focus.region, LiveFocusRegion.channels);
    });

    testWidgets('OK applies the category and enters its channel list', (
      tester,
    ) async {
      final h = make(visible: channels(['a']), categories: [null, 'news']);
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusCategories();
      h.focus.selectCategory(1);
      await tester.pump();

      h.focus.handleCategoriesKey(
        h.focus.categoriesFocusNode,
        keyDown(LogicalKeyboardKey.enter),
      );
      await tester.pump();
      expect(h.activated, ['news']);
      expect(h.focus.region, LiveFocusRegion.channels);
    });
  });

  group('search box', () {
    testWidgets('Down drops into the channels, Up climbs to the tabs', (
      tester,
    ) async {
      final h = make(visible: channels(['a', 'b']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusSearch();
      await tester.pump();

      h.focus.handleSearchCellKey(
        h.focus.searchCellFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      await tester.pump();
      expect(h.focus.region, LiveFocusRegion.channels);

      h.focus.focusSearch();
      await tester.pump();
      h.focus.handleSearchCellKey(
        h.focus.searchCellFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      expect(h.tabsFocused(), 1, reason: 'Up from search reaches the tabs');
    });
  });

  group('selection bookkeeping', () {
    test('the cursor clamps when the visible list shrinks', () {
      var visible = channels(['a', 'b', 'c', 'd']);
      final focus = LiveFocusCoordinator(
        scrollController: ScrollController(),
        categoryScrollController: ScrollController(),
        visibleChannels: () => visible,
        allChannels: () => visible,
        orderedCategoryIds: () => const [null],
        channelRowExtent: () => 100,
        categoryRowExtent: () => 48,
        isWide: () => true,
        isMounted: () => true,
        onChannelSelectionChanged: (_, _) {},
        onCategoryActivated: (_) {},
        onPlayChannel: (_) {},
        onToggleFavorite: (_) {},
        onNumberCommitted: (_) {},
        onFocusTabs: () {},
      );
      addTearDown(focus.dispose);

      focus.selectChannel(3);
      expect(focus.selectedChannelIndex, 3);

      // A search narrows the list under the cursor.
      visible = channels(['a']);
      focus.clampSelection();
      expect(focus.selectedChannelIndex, 0);
    });
  });

  // Number entry is a *jump*, and the coordinator deliberately does not
  // perform it: resolving a number can require changing the group, clearing a
  // search, or (outside the list) resolving a stream. So the coordinator owns
  // the digits and hands the matched channel to the host, which owns the jump.
  // These pin the half of the contract that lives here — the search space, the
  // match, and the keys.
  group('number entry', () {
    test('a committed number is handed to the host, not resolved here', () {
      final h = make(visible: channels(['a', 'b', 'c'])); // numbers 1..3
      addTearDown(h.focus.dispose);

      h.focus.appendDigit(3);
      expect(h.focus.digitBuffer, '3');
      h.focus.commitDigitBuffer();

      expect(h.focus.digitBuffer, isEmpty);
      expect(h.committed, ['c']);
      // The cursor is the host's business: it has to change group first when
      // the number is outside the visible page, so the coordinator must not
      // have jumped (and possibly to an index that is not there yet).
      expect(h.focus.selectedChannelIndex, 0);
    });

    test('a number with no matching channel just clears the buffer', () {
      final h = make(visible: channels(['a']));
      addTearDown(h.focus.dispose);

      h.focus.appendDigit(9);
      expect(h.focus.digitMatch, isNull);
      h.focus.commitDigitBuffer();

      expect(h.focus.digitBuffer, isEmpty);
      expect(h.committed, isEmpty, reason: 'nothing to jump to');
      expect(h.focus.selectedChannelIndex, 0);
    });

    test('a number matches the whole catalog, not the visible page', () {
      // The visible page is one category; the number space is everything. A
      // number that names a channel the current group does not draw still has
      // to resolve, or the same digits would mean different channels
      // depending on where the user happened to be.
      final h = make(
        visible: channels(['a', 'b']),
        all: channels(['a', 'b', 'c', 'd']),
      );
      addTearDown(h.focus.dispose);

      h.focus.appendDigit(4);

      expect(h.focus.digitMatch?.id, 'd');
      h.focus.commitDigitBuffer();
      expect(h.committed, ['d']);
    });

    test('digits switch on their own once the number is unambiguous', () {
      // Four digits with a match need no disambiguation — but the switch is
      // also what takes the chip down, so it holds for a beat first and the
      // coordinator must not have forgotten the digits in the meantime.
      fakeAsync((async) {
        final h = make(visible: channels(['x', 'y', 'z']), all: [
          ...channels(['a', 'b', 'c']),
          for (final n in [1000, 1234]) Channel(id: '$n', name: 'Ch $n', number: n),
        ]);
        addTearDown(h.focus.dispose);

        for (final d in [1, 2, 3, 4]) {
          h.focus.appendDigit(d);
        }

        expect(h.committed, isEmpty, reason: 'not on the keystroke');
        expect(h.focus.digitBuffer, '1234', reason: 'still readable');

        async.elapse(kChannelNumberFullLengthCommitDelay);
        expect(h.committed, ['1234']);
        expect(h.focus.digitBuffer, isEmpty);
      });
    });

    test('a number can be entered when the visible page is empty', () {
      // A group with no channels draws no rows, and the key handler used to
      // return before it looked at digits — so the one way *out* of an empty
      // group was a number that could not be typed.
      final h = make(visible: const [], all: channels(['a', 'b']));
      addTearDown(h.focus.dispose);

      h.focus.handleChannelsKey(h.focus.channelsFocusNode, keyDown(LogicalKeyboardKey.digit2));

      expect(h.focus.digitBuffer, '2');
      h.focus.commitDigitBuffer();
      expect(h.committed, ['b']);
    });

    test('Enter confirms a half-typed number, and only then', () {
      final h = make(visible: channels(['a', 'b']));
      addTearDown(h.focus.dispose);

      // Nothing typed: Enter is the activate key, so it plays the row.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.enter),
      );
      expect(h.committed, isEmpty);
      expect(h.played, ['a']);

      h.focus.appendDigit(2);
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.enter),
      );
      expect(h.committed, ['b']);
      expect(h.played, ['a'], reason: 'the number took the press instead');
    });

    test('a direction key drops a half-typed number', () {
      // Navigating away is a decision to stop entering it; leaving the chip up
      // over a moving cursor reads as a pending jump that is about to fire.
      for (final key in [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        final h = make(visible: channels(['a', 'b', 'c']));
        addTearDown(h.focus.dispose);
        h.focus.appendDigit(2);
        expect(h.focus.digitBuffer, '2');

        h.focus.handleChannelsKey(h.focus.channelsFocusNode, keyDown(key));

        expect(h.focus.digitBuffer, isEmpty, reason: 'for $key');
      }
    });

    test('the chip names the match, and the no-match case explicitly', () {
      final h = make(visible: channels(['a', 'b']));
      addTearDown(h.focus.dispose);

      h.focus.appendDigit(2);
      expect(h.focus.digitMatchLabel, 'Ch b');

      h.focus.appendDigit(9);
      expect(h.focus.digitMatch, isNull);
      expect(h.focus.digitMatchLabel, kNoChannelNumberMatch);
    });

    test('a pending number cannot commit after the coordinator is gone', () {
      // The host hand-off is async, and a screen can be torn down inside the
      // 1.5s window. An undisposed entry would still fire into a dead screen.
      fakeAsync((async) {
        final h = make(visible: channels(['a', 'b']));
        h.focus.appendDigit(2);

        h.focus.dispose();
        async.elapse(kChannelNumberCommitDelay * 2);

        expect(h.committed, isEmpty);
    });
  });

  // The half of the jump that is *not* pure: getting the row on screen. A
  // number can select a channel perfectly and still look like nothing happened,
  // which is exactly the bug this pins — the reveal is `index * extent`
  // arithmetic, so issued before the frame that renders the group it is jumping
  // into, it is measured against the outgoing list and clamps to the top.
  group('revealing a jumped-to channel', () {
    testWidgets('a deferred reveal lands on the row in the NEW list', (
      tester,
    ) async {
      // Start in a short group; the target is row 40 of a long one.
      final h = make(visible: channels(List.generate(4, (i) => 'c$i')));
      addTearDown(h.focus.dispose);
      await host(
        tester,
        h.focus,
        channelList: h.channelScroll,
        itemCount: 4,
      );

      // The group switch: a different, longer list arrives and the widget tree
      // grows with it.
      h.replaceVisible(channels(List.generate(60, (i) => 'c$i')));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: h.channelScroll,
              itemExtent: 100,
              itemCount: 60,
              itemBuilder: (_, i) => SizedBox(height: 100, child: Text('row $i')),
            ),
          ),
        ),
      );

      // What the host does after a group switch: move the cursor now, scroll
      // after the frame.
      h.focus.selectChannel(40, reveal: false);
      expect(h.focus.selectedChannelId, 'c40');
      expect(h.channelScroll.offset, 0, reason: 'the scroll waits for the frame');
      h.focus.revealSelectedChannel();
      // The reveal is an animated scrollTo, so the offset only means something
      // once it has run.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(h.channelScroll.offset, greaterThan(0));

      // The row is inside the viewport, not merely somewhere in the list.
      final position = h.channelScroll.position;
      expect(position.pixels, lessThanOrEqualTo(40 * 100));
      expect(position.pixels + position.viewportDimension, greaterThan(40 * 100));
    });

    testWidgets('a reveal issued before the new list exists addresses a row '
        'that is not there', (tester) async {
      // The negative control for the test above: same target index, but measured
      // against the 4-row list that is on screen right now — so the index meant
      // for the incoming list is consumed by the outgoing one and the cursor
      // lands on the wrong channel entirely.
      final h = make(visible: channels(List.generate(4, (i) => 'c$i')));
      addTearDown(h.focus.dispose);
      await host(
        tester,
        h.focus,
        channelList: h.channelScroll,
        itemCount: 4,
      );

      h.focus.selectChannel(40);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(h.focus.selectedChannelId, 'c3', reason: 'index clamped to 4 rows');
      expect(h.focus.selectedChannelId, isNot('c40'));
    });

    testWidgets('a number jump lands without a frame in which it can be '
        'cancelled', (tester) async {
      // The reported failure: the number resolved, the cursor moved, the preview
      // retargeted to the right channel — and the row was still off-screen. The
      // reveal was a 140 ms `animateTo` across hundreds of rows, so any rebuild
      // during it (the preview retarget, a late guide) abandoned the scroll
      // wherever it had got to, and a half-finished animation is indistinguishable
      // from no scroll at all.
      //
      // So the number's reveal is immediate. `jumpTo` has no frame in which it
      // can be interrupted, and a several-hundred-row jump animated in 140 ms
      // was a blur rather than a transition in the first place.
      final h = make(visible: channels(List.generate(600, (i) => 'c$i')));
      addTearDown(h.focus.dispose);
      await host(
        tester,
        h.focus,
        channelList: h.channelScroll,
        itemCount: 600,
      );

      // What the host does on a number commit: cursor now, scroll after the
      // frame, un-animated.
      h.focus.selectChannel(512, reveal: false);
      expect(h.channelScroll.offset, 0, reason: 'the scroll waits for the frame');
      h.focus.revealSelectedChannel(immediate: true);

      // A single frame. No settling pump, no 200 ms of curve — the offset must
      // already be final, because a real screen has no guarantee of another one
      // arriving before the user looks.
      await tester.pump();
      final landed = h.channelScroll.offset;
      expect(landed, greaterThan(0));

      // And it is the *right* row, not merely a scrolled list: the revealed
      // window has to contain the selected channel.
      final position = h.channelScroll.position;
      expect(
        512 * 100,
        inInclusiveRange(
          position.pixels.round(),
          (position.pixels + position.viewportDimension).round(),
        ),
        reason: 'row 512 must be on screen, not just somewhere in the list',
      );
    });
  });
});

// The live body used to rebuild in full on every D-pad press *and* every focus
// change, which was the dominant per-frame cost under key auto-repeat on weak
// Android TV hardware. The panes now subscribe to narrow slices. These pin the
// split so it can't silently collapse back into one notifier.
group('notification granularity', () {
  /// Counts pulses on each slice plus the aggregate.
  ({
    int Function() channel,
    int Function() category,
    int Function() digits,
    int Function() preview,
    int Function() aggregate,
  })
  watch(LiveFocusCoordinator focus) {
    var channel = 0, category = 0, digits = 0, preview = 0, aggregate = 0;
    focus.channelSelection.addListener(() => channel++);
    focus.categorySelection.addListener(() => category++);
    focus.digitEntry.addListener(() => digits++);
    focus.previewRegion.addListener(() => preview++);
    focus.addListener(() => aggregate++);
    return (
      channel: () => channel,
      category: () => category,
      digits: () => digits,
      preview: () => preview,
      aggregate: () => aggregate,
    );
  }

    test('moving the channel cursor leaves the category sidebar alone', () {
      final h = make(visible: channels(['a', 'b', 'c']));
      addTearDown(h.focus.dispose);
      final counts = watch(h.focus);

      h.focus.selectChannel(1, reveal: false);

      expect(counts.channel(), 1);
      expect(counts.category(), 0, reason: 'the sidebar did not change');
      expect(counts.digits(), 0);
      // The wide preview panel follows the channel cursor, so it must repaint.
      expect(counts.preview(), 1);
    });

    test('moving the category cursor leaves the channel list alone', () {
      final h = make(
        visible: channels(['a', 'b']),
        categories: [null, 'news', 'sport'],
      );
      addTearDown(h.focus.dispose);
      final counts = watch(h.focus);

      h.focus.selectCategory(2, reveal: false);

      expect(counts.category(), 1);
      expect(counts.channel(), 0, reason: 'the channel list did not change');
      expect(counts.preview(), 0);
    });

    test('digit entry repaints only the chip', () {
      final h = make(visible: channels(['a', 'b']));
      addTearDown(h.focus.dispose);
      final counts = watch(h.focus);

      h.focus.appendDigit(2);

      expect(counts.digits(), 1);
      expect(counts.channel(), 0);
      expect(counts.category(), 0);
    });

    test('every slice pulse still reaches the aggregate listener', () {
      final h = make(visible: channels(['a', 'b']), categories: [null, 'news']);
      addTearDown(h.focus.dispose);
      final counts = watch(h.focus);

      h.focus.selectChannel(1, reveal: false);
      h.focus.selectCategory(1, reveal: false);
      h.focus.appendDigit(2);

      // Anything still listening to the coordinator as a whole — the Back
      // ladder's route reads, the screen's own wiring — keeps seeing all three.
      expect(counts.aggregate(), 3);
    });
  });
}

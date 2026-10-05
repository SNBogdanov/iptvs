// Where the D-pad lands when a media tab opens.
//
// The bug this pins: the "Continue watching" rail is drawn *above* the poster
// grid, but it could never take the initial focus — `_ContinueWatchingRail`
// built its cards with no `autofocus` at all — while the grid's rule was
// "autofocus `lastPlayedId`, else item 0". `lastPlayedId` is only ever set by
// `MediaTabController.notePlayed`, so on a fresh open it is null and the focus
// went to the catalog's *first* movie/series, with the things the user was
// actually watching sitting right above it, unfocused.
//
// The rule under test is a priority, not a single boolean, and each case is a way
// of ruling out one candidate:
//
//   rail present, nothing played this session -> the rail's newest entry
//   rail present, last-played still in the grid -> that grid tile (a deliberate
//     existing behaviour: coming back from a details sheet must land where you
//     left, not at the top of the tab)
//   no rail, nothing played -> grid item 0 (the old behaviour, untouched)
//   searching -> the rail is hidden, so the results take the focus
//   loading / error / empty body -> the rail must NOT take it; that body's own
//     retry/empty action owns the focus (CLAUDE.md, "a body with no focusable
//     rows must put focus on its own action")
//
// Exactly one autofocus candidate per tab matters as much as which one: two
// widgets requesting autofocus on the same frame race, and the winner is decided
// by tree order rather than by intent.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart' show PlaybackPosition;
import 'package:iptvs/screens/media_tab_controller.dart'
    show ContinueWatchingEntry;
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/focusable_card.dart';

List<MediaItem> _items(int count) => [
  for (var i = 0; i < count; i++)
    MediaItem(
      id: 'm$i',
      title: 'Title $i',
      kind: ContentKind.movie,
      year: '2020',
    ),
];

ContinueWatchingEntry _entry(MediaItem item) => ContinueWatchingEntry(
  item: item,
  position: PlaybackPosition(
    kind: ContentKind.movie,
    itemId: item.id,
    position: const Duration(minutes: 12),
    duration: const Duration(hours: 1, minutes: 40),
    updatedAt: DateTime(2024, 1, 1),
  ),
);

/// Mounts [MediaTabView] at a window big enough for the grid, and returns the
/// scroll controller for teardown.
Future<ScrollController> _mount(
  WidgetTester tester, {
  required List<MediaItem> items,
  List<ContinueWatchingEntry> rail = const [],
  String? lastPlayedId,
  bool showingSearch = false,
  bool loading = false,
  bool failed = false,
}) async {
  final scroll = ScrollController();
  final focus = FocusNode();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: MediaTabView(
          kind: ContentKind.movie,
          visible: items,
          snapshot: null,
          loading: loading,
          loadingMore: false,
          error: failed ? 'boom' : null,
          showingSearch: showingSearch,
          lastPlayedId: lastPlayedId,
          scrollController: scroll,
          firstFocusNode: focus,
          isFavorite: (_) => false,
          onOpenMedia: (_) {},
          onLoadMore: () {},
          onRetry: () {},
          continueWatching: rail,
          onResume: (_) {},
          onRemoveContinueWatching: (_) {},
        ),
      ),
    ),
  );
  // Not `pumpAndSettle`: the loading body spins an indeterminate progress
  // indicator, so settling never converges. Two plain frames are enough for the
  // autofocus request to land, which is all these assertions read.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  addTearDown(() {
    scroll.dispose();
    focus.dispose();
  });
  return scroll;
}

/// Every `autofocus: true` [FocusableCard] in the tree, by debug label. Asserted
/// as a *list* so "two of them" fails, which is the race the priority rule
/// exists to prevent.
List<String> _autofocusLabels(WidgetTester tester) => [
  for (final card in tester.widgetList<FocusableCard>(find.byType(FocusableCard)))
    if (card.autofocus) card.debugLabel ?? '<unlabelled>',
];

void main() {
  group('the media tab opens its focus on the right thing', () {
    testWidgets('recents present, nothing played this session: the rail',
        (tester) async {
      final items = _items(8);
      await _mount(
        tester,
        items: items,
        // Rail is newest-first, so the landing spot is index 0 — not the item
        // that happens to sit first in the grid.
        rail: [_entry(items[5]), _entry(items[2]), _entry(items[7])],
      );

      expect(
        _autofocusLabels(tester),
        ['media.continue.m5'],
        reason: 'the newest entry is the first rail tile',
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is FocusableCard && w.debugLabel == 'media.continue.m5',
        ),
        findsOneWidget,
      );
      // Real focus, not just the flag: the whole point is where the D-pad sits.
      final focused = Focus.of(
        tester.element(
          find.byWidgetPredicate(
            (w) => w is FocusableCard && w.debugLabel == 'media.continue.m5',
          ),
        ),
      );
      expect(focused.hasFocus, isTrue);
    });

    testWidgets('recents present and last-played visible: that grid tile wins',
        (tester) async {
      final items = _items(8);
      await _mount(
        tester,
        items: items,
        rail: [_entry(items[5]), _entry(items[2])],
        lastPlayedId: items[3].id,
      );

      expect(
        _autofocusLabels(tester),
        ['media.item.m3'],
        reason: 'returning from the details sheet must land where you left, '
            'not at the top of the tab',
      );
    });

    testWidgets('no recents, nothing played: the first grid item',
        (tester) async {
      await _mount(tester, items: _items(8));
      expect(_autofocusLabels(tester), ['media.item.m0']);
    });

    testWidgets('searching hides the rail, so the results take the focus',
        (tester) async {
      final items = _items(8);
      await _mount(
        tester,
        items: items,
        rail: [_entry(items[5])],
        showingSearch: true,
      );

      expect(
        _autofocusLabels(tester),
        ['media.item.m0'],
        reason: 'the rail is not drawn while searching',
      );
    });

    for (final (label, loading, failed) in const [
      ('loading', true, false),
      ('failed', false, true),
    ]) {
      testWidgets('$label body: the rail leaves the focus alone',
          (tester) async {
        final items = _items(8);
        await _mount(
          tester,
          items: items,
          rail: [_entry(items[5]), _entry(items[2])],
          loading: loading,
          failed: failed,
        );

        expect(
          _autofocusLabels(tester),
          isEmpty,
          reason: 'a status line is not reachable by D-pad; the retry action '
              'owns the focus here (docs/tv-navigation.md)',
        );
      });
    }
  });
}
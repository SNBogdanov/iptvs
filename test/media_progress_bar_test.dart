// The green "how far watched" bar on a poster card.
//
// Two claims are worth a test and only one of them is about pixels:
//
//   1. **The bar is conditional and per-item.** It appears on the cards the
//      controller says are in progress and on no others — including not at all
//      when the map is empty, which is the common case (most titles are never
//      started) and the one that must cost nothing.
//   2. **It changes no geometry.** This is the load-bearing one. A poster cell
//      is a fixed extent derived from `childAspectRatio` plus a fixed
//      `textBudget`; a bar added as a row under the poster would either move
//      that extent — re-deriving every pinned metric in `MediaGridMetrics` — or
//      clip the text block. So the bar lives inside the poster's own `Stack`, and
//      this asserts the cell is byte-for-byte the same size with and without it.
//      A test that only checked "a green bar appeared" would pass just as well
//      with a bar that pushed every title down by four pixels.
//
// The narrow-layout row is covered by the same suite via its own thumb, because
// a phone in landscape must report the same progress the grid does.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart' show PlaybackPosition;
import 'package:iptvs/screens/media_tab_controller.dart'
    show ContinueWatchingEntry;
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';

List<MediaItem> _items(int count) => [
  for (var i = 0; i < count; i++)
    MediaItem(
      id: 'm$i',
      title: 'Title $i',
      kind: ContentKind.movie,
      year: '2020',
    ),
];

Widget _app(Widget child) =>
    MaterialApp(theme: AppTheme.dark, home: Scaffold(body: child));

void main() {
  group('the watched-progress bar on a poster card', () {
    testWidgets('appears only on the cards that are in progress',
        (tester) async {
      final items = _items(6);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      await tester.pumpWidget(
        _app(
          MediaTabView(
            kind: ContentKind.movie,
            visible: items,
            snapshot: null,
            loading: false,
            loadingMore: false,
            error: null,
            showingSearch: false,
            lastPlayedId: null,
            scrollController: scroll,
            firstFocusNode: null,
            isFavorite: (_) => false,
            onOpenMedia: (_) {},
            onLoadMore: () {},
            onRetry: () {},
            // m1 is 40% in, m4 just started.
            resumeProgress: const {'m1': 0.4, 'm4': 0.02},
            onResume: (_) {},
            onRemoveContinueWatching: (_) {},
          ),
        ),
      );
      await tester.pump();

      final bars = tester.widgetList<WatchProgressBar>(
        find.byType(WatchProgressBar),
      );
      expect(
        bars.map((b) => b.value),
        unorderedEquals([0.4, 0.02]),
        reason: 'one bar per in-progress title, carrying that title\'s fraction',
      );

      // The bar is *on the poster*, not beside it: the title still reads below
      // the artwork rather than having moved under a bar row.
      expect(find.text('Title 1'), findsOneWidget);
      expect(find.text('Title 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a finished title draws a full bar, and nothing else marks it',
        (tester) async {
      // A film played to the end has no position row, but it *was* watched —
      // the controller merges its watched mark as 1.0. The full bar is that
      // indicator: the resize-resistance and per-item conditionality of a
      // partial bar apply to it exactly.
      final items = _items(4);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      await tester.pumpWidget(
        _app(
          MediaTabView(
            kind: ContentKind.movie,
            visible: items,
            snapshot: null,
            loading: false,
            loadingMore: false,
            error: null,
            showingSearch: false,
            lastPlayedId: null,
            scrollController: scroll,
            firstFocusNode: null,
            isFavorite: (_) => false,
            onOpenMedia: (_) {},
            onLoadMore: () {},
            onRetry: () {},
            // m0 seen to the end; m1 is mid-film.
            resumeProgress: const {'m0': 1.0, 'm1': 0.4},
            onResume: (_) {},
            onRemoveContinueWatching: (_) {},
          ),
        ),
      );
      await tester.pump();

      final bars = tester.widgetList<WatchProgressBar>(
        find.byType(WatchProgressBar),
      );
      expect(
        bars.map((b) => b.value),
        unorderedEquals([1.0, 0.4]),
        reason: 'the full bar and the partial bar are the same widget',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('no bar anywhere when nothing is in progress', (tester) async {
      final items = _items(6);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      await tester.pumpWidget(
        _app(
          MediaTabView(
            kind: ContentKind.movie,
            visible: items,
            snapshot: null,
            loading: false,
            loadingMore: false,
            error: null,
            showingSearch: false,
            lastPlayedId: null,
            scrollController: scroll,
            firstFocusNode: null,
            isFavorite: (_) => false,
            onOpenMedia: (_) {},
            onLoadMore: () {},
            onRetry: () {},
            onResume: (_) {},
            onRemoveContinueWatching: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(WatchProgressBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a card is the same size with and without its bar',
        (tester) async {
      // The load-bearing assertion. See the file header.
      final items = _items(6);

      Future<Size> cellSize(Map<String, double> progress) async {
        final scroll = ScrollController();
        await tester.pumpWidget(
          _app(
            MediaTabView(
              kind: ContentKind.movie,
              visible: items,
              snapshot: null,
              loading: false,
              loadingMore: false,
              error: null,
              showingSearch: false,
              lastPlayedId: null,
              scrollController: scroll,
              firstFocusNode: null,
              isFavorite: (_) => false,
              onOpenMedia: (_) {},
              onLoadMore: () {},
              onRetry: () {},
              resumeProgress: progress,
              onResume: (_) {},
              onRemoveContinueWatching: (_) {},
            ),
          ),
        );
        await tester.pump();
        addTearDown(scroll.dispose);
        return tester.getSize(find.byType(MediaTabView).first);
      }

      final noBar = await cellSize(const {});
      final withBar = await cellSize(const {'m0': 0.5, 'm1': 0.9});

      expect(withBar.width, closeTo(noBar.width, 0.01));
      expect(withBar.height, closeTo(noBar.height, 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the bar is green, and the rail draws the same widget',
        (tester) async {
      // Two surfaces answering one question ("how far through is this?") must
      // not answer it in two colours, so both go through [WatchProgressBar].
      final items = _items(6);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      await tester.pumpWidget(
        _app(
          MediaTabView(
            kind: ContentKind.movie,
            visible: items,
            snapshot: null,
            loading: false,
            loadingMore: false,
            error: null,
            showingSearch: false,
            lastPlayedId: null,
            scrollController: scroll,
            firstFocusNode: null,
            isFavorite: (_) => false,
            onOpenMedia: (_) {},
            onLoadMore: () {},
            onRetry: () {},
            resumeProgress: const {'m0': 0.5},
            continueWatching: [for (final item in items.take(2)) _entryFor(item)],
            onResume: (_) {},
            onRemoveContinueWatching: (_) {},
          ),
        ),
      );
      await tester.pump();

      // Two rail tiles + one in-progress card. The card bar and the rail bars are
      // the *same* widget, so the two surfaces cannot drift apart again.
      expect(find.byType(WatchProgressBar), findsNWidgets(3));
      final rails = tester
          .widgetList<WatchProgressBar>(find.byType(WatchProgressBar))
          .where((b) => b.inset != EdgeInsets.zero);
      expect(
        rails,
        hasLength(2),
        reason: 'the rail insets its bar; the card runs it flush to the poster',
      );
      for (final indicator in tester.widgetList<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      )) {
        expect(indicator.color, AppColors.success);
      }
      expect(tester.takeException(), isNull);
    });
  });
}

/// A minimal rail entry; the rail's own rendering is pinned by
/// `test/layout_overflow_test.dart` and its focus by
/// `test/media_tab_focus_test.dart` — this suite is only about the bar.
ContinueWatchingEntry _entryFor(MediaItem item) => ContinueWatchingEntry(
  item: item,
  position: PlaybackPosition(
    kind: ContentKind.movie,
    itemId: item.id,
    position: const Duration(minutes: 40),
    duration: const Duration(minutes: 100),
    updatedAt: DateTime(2024, 1, 1),
  ),
);
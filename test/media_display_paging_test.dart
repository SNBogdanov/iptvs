// The VOD display window: the catalogue is loaded whole (global release-date
// sorting needs every page), so paging is a *display* step вЂ” "Load more"
// reveals the next screenful of items already in memory. One screenful is what
// actually fits the viewport, not a fixed count, so a wall of a TV and a phone
// reveal the same amount of *screen*.
//
// The failure this guards: with no window the grid drew the entire catalogue at
// once and the paging control never appeared (the default sort loads all pages).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

Future<void> _mount(
  WidgetTester tester, {
  required List<MediaItem> visible,
  required int displayPages,
}) async {
  // A window comfortably in the grid branch, and tall enough that the computed
  // screenful is several rows.
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final scroll = ScrollController();
  final focus = FocusNode();
  addTearDown(scroll.dispose);
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: MediaTabView(
          kind: ContentKind.movie,
          visible: visible,
          // Null snapshot (no provider paging): the window alone decides what is
          // drawn, which is exactly the sorted-mode case the window exists for.
          snapshot: null,
          loading: false,
          loadingMore: false,
          error: null,
          showingSearch: false,
          lastPlayedId: null,
          scrollController: scroll,
          firstFocusNode: focus,
          displayPages: displayPages,
          isFavorite: (_) => false,
          onOpenMedia: (_) {},
          onLoadMore: () {},
          onRetry: () {},
          continueWatching: const [],
          onResume: (_) {},
          onRemoveContinueWatching: (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('one page offers the next page, not the whole catalogue', (
    tester,
  ) async {
    await _mount(tester, visible: _items(300), displayPages: 1);

    // The grid is virtualized, so a text finder cannot prove what is *not*
    // built. The windowing signal is the control: 300 items against one
    // screenful must offer page 2, which the controller never would if the
    // window did not exist (all 300 are loaded, so there is no provider page to
    // fetch and no `snapshot.hasMore`).
    expect(find.text('Title 0'), findsOneWidget);
    expect(find.text('Next page'), findsOneWidget);
  });

  testWidgets('enough pages reach the end, so the control disappears', (
    tester,
  ) async {
    // 50 screens is comfortably more than 300 items at any window this test
    // uses, so every item is inside the window and there is nothing to page to.
    await _mount(tester, visible: _items(300), displayPages: 50);

    expect(find.text('Title 0'), findsOneWidget);
    expect(find.textContaining('Next page'), findsNothing);
  });

  testWidgets('a short catalogue shows no paging control', (tester) async {
    // Fewer items than one screenful: nothing to page to.
    await _mount(tester, visible: _items(3), displayPages: 1);

    expect(find.text('Title 0'), findsOneWidget);
    expect(find.text('Title 2'), findsOneWidget);
    expect(find.textContaining('Next page'), findsNothing);
  });
}


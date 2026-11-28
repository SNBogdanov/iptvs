// The VOD display window: the catalogue is loaded whole (global release-date
// sorting needs every page), so paging is a *display* step — the window reveals
// the next screenful of items already in memory. One screenful is what actually
// fits the viewport, not a fixed count, so a wall of a TV and a phone reveal the
// same amount of *screen*.
//
// There is **no "Next page" control**. On a television it was a trip to the
// bottom-right corner, and the rows it revealed pushed everything above them up,
// so the user walked back down for every page. Down on the last available row is
// the page gesture now, and it lands the cursor one row below.
//
// The failure the window guards: with no window the grid drew the entire
// catalogue at once (the default sort loads all pages).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/screens/media_tab_controller.dart';
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
  Size window = const Size(1280, 900),
  double? bodyHeight,
  List<ContinueWatchingEntry> continueWatching = const [],
  List<int>? reported,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final scroll = ScrollController();
  final focus = FocusNode();
  addTearDown(scroll.dispose);
  addTearDown(focus.dispose);
  Widget body = MediaTabView(
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
    continueWatching: continueWatching,
    onResume: (_) {},
    onRemoveContinueWatching: (_) {},
    onShown: reported?.add,
  );
  if (bodyHeight != null) {
    body = SizedBox(height: bodyHeight, child: body);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: body),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('one page reveals one screenful, not the whole catalogue', (
    tester,
  ) async {
    final reported = <int>[];
    await _mount(
      tester,
      visible: _items(300),
      displayPages: 1,
      reported: reported,
    );

    // The grid is virtualized, so a text finder cannot prove what is *not*
    // built. The reported window is the signal: one screenful of 300 items,
    // and no paging control to walk to.
    expect(find.text('Title 0'), findsOneWidget);
    expect(reported, isNotEmpty);
    expect(reported.last, lessThan(300));
    expect(find.textContaining('Next page'), findsNothing);
  });

  testWidgets('enough pages reach the end of the catalogue', (tester) async {
    final reported = <int>[];
    await _mount(
      tester,
      visible: _items(300),
      displayPages: 50,
      reported: reported,
    );

    expect(find.text('Title 0'), findsOneWidget);
    expect(reported.last, 300);
    expect(find.textContaining('Next page'), findsNothing);
  });

  testWidgets('a short catalogue is shown whole', (tester) async {
    final reported = <int>[];
    await _mount(
      tester,
      visible: _items(3),
      displayPages: 1,
      reported: reported,
    );

    expect(find.text('Title 0'), findsOneWidget);
    expect(find.text('Title 2'), findsOneWidget);
    expect(reported.last, 3);
  });

  testWidgets('the Continue-watching rail shortens page 1 only', (
    tester,
  ) async {
    // The rail is a sliver above the grid, so the first screen has room for
    // fewer rows. It no longer costs a cell for a paging control: the window is
    // exactly what fits below the rail.
    final withRail = <int>[];
    await _mount(
      tester,
      visible: _items(300),
      displayPages: 1,
      window: const Size(384, 763),
      bodyHeight: 432,
      continueWatching: [
        for (final item in _items(2))
          ContinueWatchingEntry(
            item: item,
            position: PlaybackPosition(
              kind: ContentKind.movie,
              itemId: item.id,
              position: const Duration(minutes: 40),
              duration: const Duration(minutes: 100),
              updatedAt: DateTime(2024, 1, 1),
            ),
          ),
      ],
      reported: withRail,
    );
    expect(withRail.last, greaterThan(1));
    expect(withRail.last, lessThan(300));

    final withoutRail = <int>[];
    await _mount(
      tester,
      visible: _items(300),
      displayPages: 1,
      window: const Size(384, 763),
      bodyHeight: 432,
      reported: withoutRail,
    );
    expect(
      withRail.last,
      lessThan(withoutRail.last),
      reason: 'the rail occupies part of the first screen',
    );
  });

  testWidgets('Down on the last row reveals the page and keeps the column', (
    tester,
  ) async {
    // List layout (a narrow window), so "the row below" is the next item and
    // the assertion is exact. The harness is the screen's behaviour in
    // miniature: a page request raises the display window.
    tester.view.physicalSize = const Size(500, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var pages = 1;
    var loads = 0;
    final reported = <int>[];
    final scroll = ScrollController();
    final first = FocusNode();
    addTearDown(scroll.dispose);
    addTearDown(first.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: StatefulBuilder(
              builder: (context, setState) => MediaTabView(
                kind: ContentKind.movie,
                visible: _items(40),
                snapshot: null,
                loading: false,
                loadingMore: false,
                error: null,
                showingSearch: false,
                lastPlayedId: null,
                scrollController: scroll,
                firstFocusNode: first,
                displayPages: pages,
                isFavorite: (_) => false,
                onOpenMedia: (_) {},
                onLoadMore: () => setState(() {
                  loads += 1;
                  pages += 1;
                }),
                onRetry: () {},
                onResume: (_) {},
                onRemoveContinueWatching: (_) {},
                onShown: reported.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final firstPage = reported.last;
    expect(firstPage, greaterThan(1));
    expect(firstPage, lessThan(40));

    // Walk to the last shown row, then press Down once more.
    var guard = 0;
    while (loads == 0 && guard++ < 40) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.pump();

    expect(loads, 1, reason: 'the last row asked for the next page');
    expect(reported.last, greaterThan(firstPage), reason: 'the page appeared');
    // The cursor stayed in its column: in the list that is exactly the next
    // item, the first of the row that has just been revealed.
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'media.item.m$firstPage',
    );
  });
}

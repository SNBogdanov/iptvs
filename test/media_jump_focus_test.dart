import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  testWidgets('a jump target outside the window is revealed and focused', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final scroll = ScrollController();
    final firstFocus = FocusNode();
    final jumpFocus = FocusNode();
    addTearDown(() {
      scroll.dispose();
      firstFocus.dispose();
      jumpFocus.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: MediaTabView(
            kind: ContentKind.movie,
            visible: _items(60),
            snapshot: null,
            loading: false,
            loadingMore: false,
            error: null,
            showingSearch: false,
            lastPlayedId: null,
            jumpTargetId: 'm40',
            jumpTargetIndex: 40,
            jumpFocusNode: jumpFocus,
            scrollController: scroll,
            firstFocusNode: firstFocus,
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
    await tester.pumpAndSettle();

    expect(scroll.offset, greaterThan(0));
    expect(jumpFocus.hasFocus, isTrue);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is FocusableCard && widget.debugLabel == 'media.item.m40',
      ),
      findsOneWidget,
    );
  });
}

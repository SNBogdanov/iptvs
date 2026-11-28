// The two auto-advance toggles on the global Settings screen, pinned at the UI
// boundary: they must exist, be D-pad reachable (a FocusableCard, not a bare
// tappable), and write the same store the player reads. The decision itself is
// pinned in `next_video_policy_test.dart`; this only proves the screen actually
// exposes it and that a press reaches `AppSettingsStore`.

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/data/content_tabs_visibility.dart';
import 'package:iptvs/player/next_video_policy.dart';
import 'package:iptvs/screens/settings_screen.dart';
import 'package:iptvs/sources/source.dart'
    show ContentKind, kContentSections;
import 'package:iptvs/widgets/focusable_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = AppSettingsStore();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester) async {
    // Tall enough that the whole tile list is built: a `ListView` only
    // materialises what fits (plus a little cacheExtent), and the auto-advance
    // tiles sit below the default 600px fold on every desktop-hosted test.
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: SettingsScreen(store: store)),
    );
    await tester.pumpAndSettle();
  }

  Finder tile(String debugLabel) => find.byWidgetPredicate(
    (widget) => widget is FocusableCard && widget.debugLabel == debugLabel,
  );

  testWidgets('both toggles are focus cards, not bare tappables', (
    tester,
  ) async {
    await pump(tester);
    expect(tile('settings.Auto-play the next video'), findsOneWidget);
    expect(tile('settings.Next video already watched'), findsOneWidget);
  });

  testWidgets('auto-play starts off and a press turns it on', (tester) async {
    await pump(tester);
    expect(await store.autoPlayNextVideo(), isFalse);
    await tester.tap(tile('settings.Auto-play the next video'));
    await tester.pumpAndSettle();
    expect(await store.autoPlayNextVideo(), isTrue);
  });

  testWidgets('the behaviour tile shows and cycles the current policy', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Continue / skip'), findsOneWidget);
    await tester.tap(tile('settings.Next video already watched'));
    await tester.pumpAndSettle();
    expect(
      await store.nextVideoPlayedBehavior(),
      NextVideoPlayedBehavior.startOver,
    );
    expect(find.text('Start over'), findsOneWidget);
    await tester.tap(tile('settings.Next video already watched'));
    await tester.pumpAndSettle();
    expect(
      await store.nextVideoPlayedBehavior(),
      NextVideoPlayedBehavior.resumeOrSkip,
    );
  });

  testWidgets('the seek-step tile shows and cycles the step', (tester) async {
    await pump(tester);
    expect(tile('settings.VOD seek step'), findsOneWidget);
    expect(find.text('10 s'), findsOneWidget);
    await tester.tap(tile('settings.VOD seek step'));
    await tester.pumpAndSettle();
    expect(await store.seekStepSeconds(), 15);
    expect(find.text('15 s'), findsOneWidget);
  });

  // The section switches: a section can be hidden, the last one cannot.
  testWidgets('a section hides, and the last visible one refuses to', (
    tester,
  ) async {
    visibleContentTabs.value = {...kContentSections};
    addTearDown(() => visibleContentTabs.value = {...kContentSections});
    await pump(tester);

    expect(tile('settings.Live section'), findsOneWidget);
    expect(tile('settings.Movies section'), findsOneWidget);
    expect(tile('settings.Series section'), findsOneWidget);

    await tester.tap(tile('settings.Series section'));
    await tester.pumpAndSettle();
    expect(visibleContentTabs.value, isNot(contains(ContentKind.series)));
    expect(await store.visibleContentTabs(), isNot(contains('series')));

    await tester.tap(tile('settings.Live section'));
    await tester.pumpAndSettle();
    expect(visibleContentTabs.value, {ContentKind.movie});

    // The only one left: refused, with a message, and still on.
    await tester.tap(tile('settings.Movies section'));
    await tester.pumpAndSettle();
    expect(visibleContentTabs.value, {ContentKind.movie});
    expect(
      find.text('At least one section has to stay visible'),
      findsOneWidget,
    );
  });
}

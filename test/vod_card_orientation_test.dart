import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/data/vod_card_orientation.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';

/// The card-shape preference is one enum behind three layers — the keychain, the
/// live notifier the grid listens to, and the grid's own default — and the only
/// way it breaks is a disagreement between them. So this drives the real store
/// over the mocked keychain the rest of the suite uses, rather than a fake.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = AppSettingsStore();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    vodCardOrientation.value = VodCardOrientation.portrait;
  });

  group('storage encoding', () {
    test('portrait is the default and is never written', () {
      // Absence *is* the default throughout AppSettingsStore; storing the
      // default would make the keychain look like the user had chosen something.
      expect(VodCardOrientation.portrait.storageValue, isNull);
      expect(VodCardOrientation.landscape.storageValue, 'landscape');
    });

    test('parse round-trips every value', () {
      for (final value in VodCardOrientation.values) {
        expect(VodCardOrientation.parse(value.storageValue), value);
      }
    });

    test('an unknown or absent value reads as portrait', () {
      // Deliberately not a throw: a keychain value written by a *newer* build
      // must not fail the grid on an older one, and the safe answer is the
      // shape everything shipped with.
      for (final raw in <String?>[null, '', 'PORTRAIT', 'square', 'Landscape']) {
        expect(
          VodCardOrientation.parse(raw),
          VodCardOrientation.portrait,
          reason: 'raw: "$raw"',
        );
      }
    });
  });

  group('the notifier the grid listens to', () {
    test('loads the stored value', () async {
      await store.setRawVodCardOrientation('landscape');

      await loadVodCardOrientation(store: store);

      expect(vodCardOrientation.value, VodCardOrientation.landscape);
    });

    test('an untouched install loads portrait', () async {
      await loadVodCardOrientation(store: store);

      expect(vodCardOrientation.value, VodCardOrientation.portrait);
    });

    test('setting publishes first, then persists', () async {
      await setVodCardOrientation(
        VodCardOrientation.landscape,
        store: store,
      );

      // Published synchronously inside the call, before the await — the visible
      // redraw is the point of the toggle and a slow keychain must not delay it.
      expect(vodCardOrientation.value, VodCardOrientation.landscape);
      expect(await store.rawVodCardOrientation(), 'landscape');
    });

    test('switching back clears the key rather than storing portrait', () async {
      await setVodCardOrientation(
        VodCardOrientation.landscape,
        store: store,
      );
      await setVodCardOrientation(
        VodCardOrientation.portrait,
        store: store,
      );

      expect(await store.rawVodCardOrientation(), isNull);
      expect(vodCardOrientation.value, VodCardOrientation.portrait);
    });

    test('survives a reboot', () async {
      await setVodCardOrientation(
        VodCardOrientation.landscape,
        store: store,
      );

      // The notifier is process state; the store is what the next run reads.
      vodCardOrientation.value = VodCardOrientation.portrait;
      await loadVodCardOrientation(store: store);

      expect(vodCardOrientation.value, VodCardOrientation.landscape);
    });
  });

  group('the two-way cycle behind the Settings tile', () {
    test('toggles between exactly two shapes and comes back', () {
      var value = VodCardOrientation.portrait;
      final seen = <VodCardOrientation>[];
      for (var i = 0; i < 3; i++) {
        value = otherVodCardOrientation(value);
        seen.add(value);
      }
      expect(seen, <VodCardOrientation>[
        VodCardOrientation.landscape,
        VodCardOrientation.portrait,
        VodCardOrientation.landscape,
      ]);
    });

    test('the label is what the tile prints', () {
      expect(VodCardOrientation.portrait.label, 'Portrait');
      expect(VodCardOrientation.landscape.label, 'Landscape');
    });
  });

  group('the narrow list row follows the shape', () {
    // A phone window: under the media grid's 600 dp floor, so the tab renders
    // list rows — the surface where the preference used to do nothing at all,
    // because a phone never reaches the poster grid.
    Future<void> mount(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
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
              visible: const [
                MediaItem(id: 'm1', title: 'One', kind: ContentKind.movie),
              ],
              snapshot: null,
              loading: false,
              loadingMore: false,
              error: null,
              showingSearch: false,
              lastPlayedId: null,
              scrollController: scroll,
              firstFocusNode: focus,
              displayPages: 1,
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

    testWidgets('only the width follows the preference', (tester) async {
      await mount(tester);
      Size thumb() => tester.getSize(
        find.byKey(const ValueKey('media.list.thumb')).first,
      );

      // Portrait keeps the 2:3 poster, landscape widens to a 16:9 band.
      expect(thumb().height, 84);
      expect(thumb().width, closeTo(84 * (2 / 3), 0.01));

      vodCardOrientation.value = VodCardOrientation.landscape;
      await tester.pump();

      // The height is what the paging math counts rows by, so it must not move —
      // that was the reason the row used to ignore the setting entirely.
      expect(thumb().height, 84);
      expect(thumb().width, closeTo(84 * (16 / 9), 0.01));
    });
  });
}
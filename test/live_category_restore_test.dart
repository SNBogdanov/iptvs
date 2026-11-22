// The live tab's remembered category: the device record, the boot-time cache,
// and the screen actually opening on it.
//
// The rules pinned here:
//
//   * The choice is **per source** (`app_live_category_<sourceId>`), because a
//     category id is the provider's own. A stored id is only a candidate: the
//     screen opens on it and drops it back to "All channels" once the catalogue
//     proves it gone (renamed, removed, or disabled in source settings) — an
//     empty list with no row to move off is the failure this prevents.
//   * The category is settled **before** the last-channel resume, so a stored
//     channel that the restored category lists is revealed inside it.
//   * Switching category keeps the selected channel when the new view also
//     lists it; the coordinator's own tests cover that rule, these cover the
//     restore path that feeds it.
//
// Deliberately narrow-layout widget tests: the wide layout builds an inline
// preview player (libmpv), the narrow one exercises the same load, restore and
// draw path without it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/data/last_channel_store.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_refresh_store.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/media_category_cache.dart';
import 'package:iptvs/screens/media_tab_controller.dart'
    show kAllSourcesFavoritesCategoryId;
import 'package:iptvs/widgets/image_utils.dart'
    show debugDisableNetworkChannelLogos;
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  const sourceId = 'groups';

  group('liveTabCategoryForZapRange', () {
    test('maps the quick list vocabulary back to the tab filter', () {
      // The quick list's "everything" row is the tab's "All channels".
      expect(liveTabCategoryForZapRange(''), isNull);
      // A provider category id is one and the same on both sides.
      expect(liveTabCategoryForZapRange('7'), '7');
      // A per-source row inside the cross-source view has no per-source filter
      // in the tab, so it lands on the whole cross-source view - the widest
      // thing that still draws the channel.
      expect(
        liveTabCategoryForZapRange('zapsrc:abc'),
        kAllSourcesFavoritesCategoryId,
      );
    });
  });

  group('AppSettingsStore.liveCategory', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('round-trips per source, and null means "All channels"', () async {
      const settings = AppSettingsStore();
      expect(await settings.liveCategory(sourceId), isNull);

      await settings.setLiveCategory(sourceId, 'news');
      expect(await settings.liveCategory(sourceId), 'news');
      // Another provider's ids must never leak into this one.
      expect(await settings.liveCategory('other'), isNull);

      await settings.setLiveCategory(sourceId, null);
      expect(
        await settings.liveCategory(sourceId),
        isNull,
        reason:
            '"All channels" deletes the row instead of storing an empty one',
      );
    });
  });

  group('preloadTabCategoryPrefs', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      resetMediaCategoryCacheForTest();
    });

    test('fills the live cache, so a screen restores synchronously', () async {
      const settings = AppSettingsStore();
      await settings.setMediaCategory(sourceId, 'movie', 'films');
      await settings.setLiveCategory(sourceId, 'news');

      await preloadTabCategoryPrefs([sourceId]);

      expect(cachedLiveCategory(sourceId), 'news');
      expect(cachedMediaCategory(sourceId, 'movie'), 'films');
      expect(cachedMediaCategory(sourceId, 'series'), isNull);
    });

    test('an unreadable preference reads as "All"', () async {
      resetMediaCategoryCacheForTest();
      // No key written at all: the read returns null rather than throwing.
      await preloadTabCategoryPrefs([sourceId]);
      expect(cachedLiveCategory(sourceId), isNull);
    });
  });

  group('ChannelListScreen', () {
    late Directory tempDir;
    late AppDatabase db;
    final store = SourceStore();

    SourceConfig config() => const SourceConfig(
      id: sourceId,
      kind: SourceKind.m3u,
      label: 'Groups',
      fields: {},
      settings: {},
    );

    setUp(() async {
      debugDisableNetworkChannelLogos = true;
      resetMediaCategoryCacheForTest();
      FlutterSecureStorage.setMockInitialValues({});
      tempDir = Directory.systemTemp.createTempSync('iptvs_live_category_test');
      db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
      // Keep the scheduled catalogue refresh out of these tests: it starts a
      // second `replaceLibrary` in the background, and that transaction can
      // still be in flight when the widget tree is disposed ("a Timer is still
      // pending"). Stamping "just refreshed" makes the schedule not due.
      await SourceRefreshStore().setLastRefresh(sourceId, DateTime.now());
    });

    tearDown(() async {
      debugDisableNetworkChannelLogos = false;
      await db.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// Pumps the live tab narrow enough to skip the preview player, and keeps
    /// pumping until [waitFor] appears — the first frame only means the cached
    /// catalogue is up.
    Future<void> pumpNarrow(WidgetTester tester, Finder waitFor) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: ChannelListScreen(
            repo: LibraryRepository(source: _GroupsSource(), db: db),
            config: config(),
            store: store,
          ),
        ),
      );
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (waitFor.evaluate().isNotEmpty) break;
      }
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    /// Unmounts the screen and lets its in-flight work settle **inside** the
    /// test.
    ///
    /// A screen left mounted until teardown can still have a database
    /// transaction open when the framework disposes the tree, and sqflite's
    /// transaction timer then trips the "a Timer is still pending" assertion —
    /// the flake this file had under load. Unmounting here cancels the
    /// controllers' own timers and gives the real I/O a moment to finish.
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('opens on the remembered category', (tester) async {
      await const AppSettingsStore().setLiveCategory(sourceId, 'news');
      await preloadTabCategoryPrefs([sourceId]);

      await pumpNarrow(tester, find.text('1 - News One'));

      expect(find.text('1 - News One'), findsOneWidget);
      expect(find.text('2 - News Two'), findsOneWidget);
      // The other group did not load into this view.
      expect(find.text('3 - Sport One'), findsNothing);
      await unmount(tester);
    });

    testWidgets('a category the source no longer offers falls back to All', (
      tester,
    ) async {
      // The provider dropped (or the user disabled) the stored group.
      await const AppSettingsStore().setLiveCategory(sourceId, 'gone');
      await preloadTabCategoryPrefs([sourceId]);

      await pumpNarrow(tester, find.text('1 - News One'));

      expect(find.text('1 - News One'), findsOneWidget);
      expect(find.text('3 - Sport One'), findsOneWidget);
      await unmount(tester);
      expect(
        await const AppSettingsStore().liveCategory(sourceId),
        isNull,
        reason: 'the dead id must not be restored again on the next launch',
      );
    });

    testWidgets('no remembered category means All channels', (tester) async {
      await preloadTabCategoryPrefs([sourceId]);

      await pumpNarrow(tester, find.text('1 - News One'));

      expect(find.text('1 - News One'), findsOneWidget);
      expect(find.text('3 - Sport One'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('the restored category outranks the last-channel resume', (
      tester,
    ) async {
      // The reported bug: the tab opened on the remembered category and, a
      // couple of seconds later, fell back to "All channels" — the resume had
      // picked the last played channel, which this category does not draw, and
      // re-ranged the whole tab to reach it.
      await const LastChannelStore().write(
        kNoProfileResumeKey,
        const LastChannel(sourceId: sourceId, channelId: 's1'),
      );
      await const AppSettingsStore().setLiveCategory(sourceId, 'news');
      await preloadTabCategoryPrefs([sourceId]);

      await pumpNarrow(tester, find.text('1 - News One'));
      // The resume's keychain reads and its post-frame reveal land here.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(find.text('1 - News One'), findsOneWidget);
      expect(
        find.text('3 - Sport One'),
        findsNothing,
        reason: 'the filter must stay on the restored category',
      );
      await unmount(tester);
    });
  });
}

/// Two groups, two channels each, so "which filter is applied" is visible in the
/// row list alone.
class _GroupsSource implements Source {
  @override
  String get id => 'groups';

  @override
  String get name => 'Groups';

  static const List<Channel> channels_ = [
    Channel(id: 'n1', name: 'News One', categoryId: 'news', number: 1),
    Channel(id: 'n2', name: 'News Two', categoryId: 'news', number: 2),
    Channel(id: 's1', name: 'Sport One', categoryId: 'sport', number: 3),
    Channel(id: 's2', name: 'Sport Two', categoryId: 'sport', number: 4),
  ];

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [
    Category(id: 'news', title: 'News'),
    Category(id: 'sport', title: 'Sport'),
  ];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => channels_;

  @override
  Future<StreamInfo> resolve(Channel channel) async =>
      const StreamInfo(url: 'http://stream');

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async => throw UnsupportedError('no catch-up');

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => const [];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async => MediaPage(items: const [], page: page, totalPages: page);

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async => const [];

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async =>
      throw UnsupportedError('not playable');

  @override
  Future<SubscriptionExpiry> subscriptionExpiry() async =>
      const SubscriptionExpiry.unknown();

  @override
  Future<void> dispose() async {}
}

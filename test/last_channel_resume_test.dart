import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/last_channel_store.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

/// The start-up resume: the device-local record, the pure decision, and the
/// cursor actually landing on the channel.
///
/// **Deliberately a narrow-layout widget test.** The wide layout builds an
/// inline preview player, and `LivePreviewController` creates its media_kit
/// player lazily — so a *narrow* screen exercises the whole select-and-reveal
/// path with no libmpv, which means these run on a plain `flutter test` instead
/// of skipping on every Windows dev box the way the focus suite does. The
/// preview half of the decision is covered by [planResumeAction] instead, which
/// is where the rule actually lives.
void main() {
  group('LastChannel', () {
    test('round-trips through json', () {
      const channel = LastChannel(sourceId: 'src', channelId: 'ch7');
      expect(LastChannel.fromJson(channel.toJson()), channel);
    });

    test('rejects anything malformed rather than throwing', () {
      // A launch must never fail over a convenience record, so every one of
      // these reads as "nothing stored" and the app starts normally.
      for (final bad in <Object?>[
        null,
        'nope',
        42,
        <String, dynamic>{},
        {'sourceId': 'src'},
        {'channelId': 'ch7'},
        {'sourceId': '', 'channelId': 'ch7'},
        {'sourceId': 'src', 'channelId': ''},
        {'sourceId': 1, 'channelId': 2},
      ]) {
        expect(LastChannel.fromJson(bad), isNull, reason: 'accepted $bad');
      }
    });
  });

  group('LastChannelStore', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('reads back what it wrote', () async {
      const store = LastChannelStore();
      const channel = LastChannel(sourceId: 'src', channelId: 'ch7');
      expect(await store.read('p1'), isNull);
      await store.write('p1', channel);
      expect(await store.read('p1'), channel);
    });

    test('keeps profiles apart', () async {
      // The whole point of keying by profile: one profile's last channel must
      // never be handed to another, or a profile switch restores a channel from
      // a provider the user is no longer signed in to.
      const store = LastChannelStore();
      await store.write('p1', const LastChannel(sourceId: 'a', channelId: '1'));
      await store.write('p2', const LastChannel(sourceId: 'b', channelId: '2'));
      expect(
        await store.read('p1'),
        const LastChannel(sourceId: 'a', channelId: '1'),
      );
      expect(
        await store.read('p2'),
        const LastChannel(sourceId: 'b', channelId: '2'),
      );
    });

    test('a later play replaces the record for that profile only', () async {
      const store = LastChannelStore();
      await store.write('p1', const LastChannel(sourceId: 'a', channelId: '1'));
      await store.write('p2', const LastChannel(sourceId: 'a', channelId: '9'));
      await store.write('p1', const LastChannel(sourceId: 'a', channelId: '2'));
      expect(
        await store.read('p1'),
        const LastChannel(sourceId: 'a', channelId: '2'),
      );
      expect(
        await store.read('p2'),
        const LastChannel(sourceId: 'a', channelId: '9'),
      );
    });

    test('forget drops one profile and leaves the rest', () async {
      const store = LastChannelStore();
      await store.write('p1', const LastChannel(sourceId: 'a', channelId: '1'));
      await store.write('p2', const LastChannel(sourceId: 'a', channelId: '2'));
      await store.forget('p1');
      expect(await store.read('p1'), isNull);
      expect(await store.read('p2'), isNotNull);
      // Forgetting something already gone is a no-op, not a write.
      await store.forget('p1');
      expect(await store.read('p2'), isNotNull);
    });

    test('a corrupt blob reads as empty instead of throwing', () async {
      const storage = FlutterSecureStorage();
      await storage.write(key: 'resume_last_channel', value: '{not json');
      expect(await const LastChannelStore().read('p1'), isNull);
    });

    test('an empty profile key is refused', () async {
      // A record under "" would be shared by every install state that failed to
      // resolve a profile, which is the opposite of per-profile.
      const store = LastChannelStore();
      await store.write('', const LastChannel(sourceId: 'a', channelId: '1'));
      expect(await store.read(''), isNull);
    });
  });

  group('SourceConfig.autoResumeLastChannel', () {
    test('is on unless explicitly off', () {
      // "On unless off" is deliberate: a resume feature nobody notices is not a
      // feature, and storing nothing for the default means an untouched source
      // serializes exactly as it did before the setting existed.
      const base = SourceConfig(
        id: 's',
        kind: SourceKind.m3u,
        label: 'S',
        fields: {},
      );
      expect(base.autoResumeLastChannel, isTrue);
      expect(
        base
            .copyWith(settings: {'autoResumeLastChannel': false})
            .autoResumeLastChannel,
        isFalse,
      );
      expect(
        base
            .copyWith(settings: {'autoResumeLastChannel': true})
            .autoResumeLastChannel,
        isTrue,
      );
    });

    test('an unrecognised stored value reads as on, not off', () {
      // A mangled preference should degrade to the default behaviour rather than
      // silently switch the feature off for a user who never asked for that.
      const config = SourceConfig(
        id: 's',
        kind: SourceKind.m3u,
        label: 'S',
        fields: {},
        settings: {'autoResumeLastChannel': 'maybe'},
      );
      expect(config.autoResumeLastChannel, isTrue);
    });
  });

  group('planResumeAction', () {
    const stored = LastChannel(sourceId: 'src', channelId: 'ch7');

    ResumeAction plan({
      bool enabled = true,
      String activeSourceId = 'src',
      LastChannel? record = stored,
      bool drawable = true,
      bool previewVisible = true,
      bool somethingAlreadyPlaying = false,
    }) => planResumeAction(
      enabled: enabled,
      activeSourceId: activeSourceId,
      stored: record,
      drawable: drawable,
      previewVisible: previewVisible,
      somethingAlreadyPlaying: somethingAlreadyPlaying,
    );

    test('selects and previews a matching, drawable channel', () {
      expect(plan(), ResumeAction.selectAndPreview);
    });

    test('respects the source preference first of all', () {
      expect(plan(enabled: false), ResumeAction.none);
    });

    test('does nothing without a record', () {
      expect(plan(record: null), ResumeAction.none);
    });

    test('does nothing for a channel from another source', () {
      // The id is unique only within a provider, so a record naming a different
      // source describes a channel this list cannot draw.
      expect(plan(activeSourceId: 'other'), ResumeAction.none);
    });

    test('does nothing for a channel no view can draw', () {
      expect(plan(drawable: false), ResumeAction.none);
    });

    test('never previews on the narrow layout', () {
      // No preview panel there, so an engine would spend a provider connection
      // on video nobody can see — and single-connection portals cannot spare it.
      expect(plan(previewVisible: false), ResumeAction.select);
    });

    test('never resolves on top of something already playing', () {
      expect(plan(somethingAlreadyPlaying: true), ResumeAction.none);
    });
  });

  group('start-up resume in the channel list', () {
    late Directory tempDir;
    late AppDatabase db;
    final store = SourceStore();

    const sourceId = 'many';

    SourceConfig configWith({required bool resume}) => SourceConfig(
      id: sourceId,
      kind: SourceKind.m3u,
      label: 'Many',
      fields: {},
      settings: resume ? const {} : const {'autoResumeLastChannel': false},
    );

    setUp(() async {
      debugDisableNetworkChannelLogos = true;
      tempDir = Directory.systemTemp.createTempSync('iptvs_resume_test');
      db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() async {
      debugDisableNetworkChannelLogos = false;
      await db.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// The row's top edge in viewport coordinates — the observable half of
    /// "the cursor is on it", since the live list is a selection model and its
    /// rows are not focus targets.
    double topOf(WidgetTester tester, String name) =>
        tester.getTopLeft(find.text(name)).dy;

    /// Waits for [waitFor], then keeps pumping long enough for the resume's two
    /// keychain reads, its post-frame reveal and the reveal's 140ms scroll to
    /// land. The first row appearing is *not* that point: it only means the
    /// catalog is up, and the resume reads the record after that.
    Future<void> pumpUntilFound(WidgetTester tester, Finder waitFor) async {
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (waitFor.evaluate().isNotEmpty) break;
      }
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> pumpNarrow(
      WidgetTester tester,
      SourceConfig config, {
      Finder? waitFor,
    }) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = LibraryRepository(source: _ManySource(sourceId), db: db);
      await tester.pumpWidget(
        MaterialApp(
          home: ChannelListScreen(repo: repo, config: config, store: store),
        ),
      );
      await pumpUntilFound(tester, waitFor ?? find.text('1 - Channel 0'));
    }

    testWidgets('lands on the stored channel', (tester) async {
      // The last row of forty: far enough down that a start which did *not*
      // resume would leave it well below the fold, so the assertion cannot pass
      // by accident.
      await const LastChannelStore().write(
        kNoProfileResumeKey,
        const LastChannel(sourceId: sourceId, channelId: 'ch39'),
      );
      await pumpNarrow(
        tester,
        configWith(resume: true),
        waitFor: find.text('40 - Channel 39'),
      );

      expect(topOf(tester, '40 - Channel 39'), greaterThan(0));
      expect(topOf(tester, '40 - Channel 39'), lessThan(800));
    });

    testWidgets('starts at the top when the source turned it off', (
      tester,
    ) async {
      await const LastChannelStore().write(
        kNoProfileResumeKey,
        const LastChannel(sourceId: sourceId, channelId: 'ch39'),
      );
      await pumpNarrow(tester, configWith(resume: false));

      // A normal start: the first row is the one drawn, and the stored channel
      // is nowhere in the tree, because the list never scrolled to it.
      expect(find.text('1 - Channel 0'), findsOneWidget);
      expect(find.text('40 - Channel 39'), findsNothing);
    });

    testWidgets('starts at the top when the record names another source', (
      tester,
    ) async {
      await const LastChannelStore().write(
        kNoProfileResumeKey,
        const LastChannel(sourceId: 'somewhere-else', channelId: 'ch39'),
      );
      await pumpNarrow(tester, configWith(resume: true));

      expect(find.text('1 - Channel 0'), findsOneWidget);
      expect(find.text('40 - Channel 39'), findsNothing);
    });

    testWidgets('starts at the top when the channel is gone from the source', (
      tester,
    ) async {
      // A channel removed by a provider refresh must not leave the app trying
      // to reveal a row that no longer exists.
      await const LastChannelStore().write(
        kNoProfileResumeKey,
        const LastChannel(sourceId: sourceId, channelId: 'ch-does-not-exist'),
      );
      await pumpNarrow(tester, configWith(resume: true));

      expect(find.text('1 - Channel 0'), findsOneWidget);
      expect(find.text('40 - Channel 39'), findsNothing);
    });
  });
}

/// Forty channels in one category, so a reveal is unambiguous.
class _ManySource implements Source {
  _ManySource(this.id);

  @override
  final String id;

  @override
  String get name => 'Many';

  static final List<Channel> channels_ = [
    for (var i = 0; i < 40; i++)
      Channel(
        id: 'ch$i',
        name: 'Channel $i',
        categoryId: 'cat0',
        number: i + 1,
      ),
  ];

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [
    Category(id: 'cat0', title: 'All'),
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

// Tests for LibraryRepository.enrichMediaMetadata's bounded-concurrency
// fan-out: a fixed worker pool pulls from a shared queue instead of a plain
// serial loop (CLAUDE.md "Async publishes are generation-guarded" area,
// perf/tier0 fix). Uses a fake MetadataProvider that tracks concurrent calls
// and a real AppDatabase (via AppDatabase.openAt) so the cache-hit
// short-circuit and the final updateMediaDisplayFields write are exercised
// for real — no network involved.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/metadata_provider.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

/// Fake provider that records concurrency (in-flight/max-in-flight counts)
/// and every id it was asked to search, and can be told to throw for
/// specific ids to exercise the fan-out's error handling.
class _FakeMetadataProvider implements MetadataProvider {
  _FakeMetadataProvider({this.failFor = const {}});

  @override
  String get provider => 'fake';

  @override
  String get authMode => 'none';

  @override
  bool get ratingsOnly => false;

  /// Item ids that should throw instead of resolving.
  final Set<String> failFor;

  int inFlight = 0;
  int maxInFlight = 0;
  final List<String> searched = [];

  @override
  Future<ExternalMetadata?> search(MediaItem item) async {
    inFlight++;
    maxInFlight = maxInFlight < inFlight ? inFlight : maxInFlight;
    searched.add(item.id);
    try {
      // Yield a few times so overlapping calls actually interleave, the way
      // real HTTP round trips would.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      if (failFor.contains(item.id)) {
        throw Exception('boom:${item.id}');
      }
      return ExternalMetadata(
        provider: provider,
        providerKey: 'fake:${item.id}',
        title: 'Enriched ${item.id}',
        overview: 'overview-${item.id}',
        refreshedAt: DateTime.now(),
      );
    } finally {
      inFlight--;
    }
  }

  @override
  Future<ExternalMetadata?> seasonMetadata(
    MediaItem series,
    MediaItem season,
  ) async => null;

  @override
  Future<ExternalMetadata?> episodeMetadata(
    MediaItem season,
    MediaItem episode,
  ) async => null;

  @override
  void close() {}
}

MediaItem _movie(String id) =>
    MediaItem(id: id, title: 'title-$id', kind: ContentKind.movie);

/// A source whose catalogue rows carry no plot but whose `mediaDetails` (the
/// `get_vod_info`/details call) does — the shape that makes `describeMedia`'s
/// provider-details fallback the only synopsis available with no metadata key.
class _DetailsSource extends DemoSource {
  @override
  Future<MediaItem> mediaDetails(MediaItem item) async =>
      item.copyWith(description: 'provider plot for ${item.id}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_enrich_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
    'enrichMediaMetadata fans out with bounded concurrency and preserves order',
    () async {
      final provider = _FakeMetadataProvider();
      final repo = LibraryRepository(
        source: DemoSource(),
        db: db,
        metadataProvider: provider,
      );

      final items = List.generate(19, (i) => _movie('m$i'));
      final result = await repo.enrichMediaMetadata(items);

      expect(result.length, items.length);
      // Every item enriched, in the same order as the input.
      for (var i = 0; i < items.length; i++) {
        expect(result[i].id, items[i].id);
        expect(result[i].title, 'Enriched m$i');
        expect(result[i].description, 'overview-m$i');
      }
      // All items were actually looked up.
      expect(provider.searched.toSet(), items.map((e) => e.id).toSet());
      // Never exceeded the pool's cap, but did overlap (fan-out happened).
      expect(provider.maxInFlight, greaterThan(1));
      expect(provider.maxInFlight, lessThanOrEqualTo(4));
    },
  );

  test(
    'one item failing does not prevent the others from being enriched',
    () async {
      final provider = _FakeMetadataProvider(failFor: {'m2', 'm5'});
      final repo = LibraryRepository(
        source: DemoSource(),
        db: db,
        metadataProvider: provider,
      );

      final items = List.generate(8, (i) => _movie('m$i'));
      final result = await repo.enrichMediaMetadata(items);

      expect(result.length, items.length);
      for (var i = 0; i < items.length; i++) {
        if (items[i].id == 'm2' || items[i].id == 'm5') {
          // Failed lookups leave the item untouched rather than aborting.
          expect(result[i].title, items[i].title);
        } else {
          expect(result[i].title, 'Enriched ${items[i].id}');
        }
      }
      expect(provider.searched.toSet(), items.map((e) => e.id).toSet());
    },
  );

  test('cache hits short-circuit the provider call', () async {
    final provider = _FakeMetadataProvider();
    final repo = LibraryRepository(
      source: DemoSource(),
      db: db,
      metadataProvider: provider,
    );

    final cached = _movie('cached-1');
    await db.cacheExternalMetadata(
      'demo',
      cached,
      ExternalMetadata(
        provider: 'fake',
        providerKey: 'fake:cached-1',
        title: 'From cache',
        refreshedAt: DateTime.now(),
      ),
    );

    final result = await repo.enrichMediaMetadata([cached]);

    expect(result.single.title, 'From cache');
    expect(provider.searched, isEmpty);
  });

  test(
    'respects the limit parameter, scanning only the first N matches',
    () async {
      final provider = _FakeMetadataProvider();
      final repo = LibraryRepository(
        source: DemoSource(),
        db: db,
        metadataProvider: provider,
      );

      final items = List.generate(10, (i) => _movie('m$i'));
      final result = await repo.enrichMediaMetadata(items, limit: 3);

      expect(provider.searched.length, 3);
      for (var i = 0; i < 3; i++) {
        expect(result[i].title, 'Enriched m$i');
      }
      for (var i = 3; i < items.length; i++) {
        expect(result[i].title, items[i].title);
      }
    },
  );

  // describeMedia backs the player chrome's on-demand synopsis: the item's own
  // description when the provider gave one, else the cached/enriched overview.
  group('describeMedia', () {
    test('returns the item\'s own description without a provider lookup', () async {
      final provider = _FakeMetadataProvider();
      final repo = LibraryRepository(
        source: DemoSource(),
        db: db,
        metadataProvider: provider,
      );
      final item = MediaItem(
        id: 'own',
        title: 'title-own',
        kind: ContentKind.movie,
        description: 'own plot',
      );

      expect(await repo.describeMedia(item), 'own plot');
      expect(provider.searched, isEmpty);
    });

    test('enriches a missing description from the provider, then the cache',
        () async {
      final provider = _FakeMetadataProvider();
      final repo = LibraryRepository(
        source: DemoSource(),
        db: db,
        metadataProvider: provider,
      );
      final item = _movie('m1');

      expect(await repo.describeMedia(item), 'overview-m1');
      expect(provider.searched, ['m1']);
      // The lookup is cached, so a second read for the same item (a step back)
      // does not hit the provider again.
      expect(await repo.describeMedia(item), 'overview-m1');
      expect(provider.searched, ['m1']);
    });

    test('returns null with no provider and no own description', () async {
      final repo = LibraryRepository(source: DemoSource(), db: db);
      expect(await repo.describeMedia(_movie('m2')), isNull);
    });

    test('falls back to the provider details when no metadata answers', () async {
      // No metadata provider configured, and the catalogue row has no plot — so
      // the only synopsis is the one `mediaDetails` (get_vod_info) returns.
      final repo = LibraryRepository(source: _DetailsSource(), db: db);
      expect(await repo.describeMedia(_movie('m9')), 'provider plot for m9');
    });
  });
}

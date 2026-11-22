// Tests for VOD pagination arithmetic.
//
// The "load more" control is labelled `Load page ${loadedPages + 1}`, so one
// press has to advance `loadedPages` by exactly one - otherwise the label and
// the request disagree and the counts read as a bug. It did: one press issued
// three page requests, so a Stalker portal (15 rows a page) appended ~40 cards
// and the button then offered page 5.
//
// Driven through the real LibraryRepository against a fake Source that records
// every requested page, because the thing worth pinning is which pages the
// provider was asked for, not the private constant that decides it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/media_order.dart';
import 'package:iptvs/sources/source.dart';

/// 15 rows a page, four pages - the shape that made the mismatch visible.
const int kRowsPerPage = 15;
const int kTotalPages = 4;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('iptvs_paging'));
  tearDown(() => _deleteTempDir(tempDir));
  String dbPath() => '${tempDir.path}/iptv.db';

  test('one "load more" press requests exactly one page', () async {
    final db = await AppDatabase.openAt(dbPath());
    final source = _PagedSource();
    final repo = LibraryRepository(source: source, db: db);

    final first = await repo.loadMedia(ContentKind.movie, loadAll: false);
    expect(source.requestedPages, [1]);
    expect(first.loadedPages, 1);
    expect(first.totalPages, kTotalPages);
    expect(first.hasMore, isTrue);
    expect(first.items.length, kRowsPerPage);

    // The press behind the "Load page 2" button.
    final second = await repo.loadMoreMedia(ContentKind.movie);
    expect(
      source.requestedPages,
      [1, 2],
      reason:
          'one press, one page - the button promises page 2 and nothing else',
    );
    expect(second.loadedPages, 2);
    expect(second.items.length, 2 * kRowsPerPage);
    expect(second.hasMore, isTrue);

    final third = await repo.loadMoreMedia(ContentKind.movie);
    expect(source.requestedPages, [1, 2, 3]);
    expect(third.loadedPages, 3);
    expect(third.items.length, 3 * kRowsPerPage);

    await db.close();
  });

  test(
    'the last page ends paging instead of asking past the catalogue',
    () async {
      final db = await AppDatabase.openAt(dbPath());
      final source = _PagedSource();
      final repo = LibraryRepository(source: source, db: db);

      await repo.loadMedia(ContentKind.movie, loadAll: false);
      await repo.loadMoreMedia(ContentKind.movie);
      await repo.loadMoreMedia(ContentKind.movie);
      expect(source.requestedPages, [1, 2, 3]);

      final last = await repo.loadMoreMedia(ContentKind.movie);
      expect(source.requestedPages, [1, 2, 3, 4]);
      expect(last.loadedPages, kTotalPages);
      expect(last.totalPages, kTotalPages);
      expect(last.hasMore, isFalse);
      expect(last.items.length, kTotalPages * kRowsPerPage);

      // Nothing left: another press must not reach the provider at all.
      final callsBefore = source.requestedPages.length;
      await repo.loadMoreMedia(ContentKind.movie);
      expect(source.requestedPages.length, callsBefore);

      await db.close();
    },
  );

  test('a full load takes the whole catalogue in one pass', () async {
    final db = await AppDatabase.openAt(dbPath());
    final source = _PagedSource();
    final repo = LibraryRepository(source: source, db: db);

    // What every non-`providerOrder` grid sort asks for, so the list can be
    // ordered globally instead of page by page.
    final all = await repo.loadMedia(ContentKind.movie, loadAll: true);
    expect(source.requestedPages, [1, 2, 3, 4]);
    expect(all.loadedPages, kTotalPages);
    expect(all.hasMore, isFalse);
    expect(all.items.length, kTotalPages * kRowsPerPage);

    await db.close();
  });

  test('a sorted tab reads the catalogue in windows, not in one query', () async {
    // The lazy read: the provider is fetched whole (a sorted tab needs the whole
    // catalogue to order it), but the *Dart* side gets one window at a time. One
    // query for everything was 162 MB of platform-channel message on a real
    // 29k-item catalogue and killed the process.
    final db = await AppDatabase.openAt(dbPath());
    final source = _BulkSource();
    final repo = LibraryRepository(source: source, db: db);

    final first = await repo.loadMedia(
      ContentKind.movie,
      loadAll: true,
      order: MediaOrder.titleAsc,
    );
    expect(first.items.length, LibraryRepository.kMediaWindow);
    expect(first.itemsTotal, _BulkSource.count);
    expect(first.hasMoreItems, isTrue);

    final second = await repo.loadMoreMedia(
      ContentKind.movie,
      order: MediaOrder.titleAsc,
      offset: first.items.length,
    );
    expect(
      second.items.length,
      _BulkSource.count - LibraryRepository.kMediaWindow,
    );
    // The *repository* returns windows; the controller appends them into one
    // snapshot, and that merged list is the whole catalogue.
    expect(first.items.length + second.items.length, _BulkSource.count);
    expect(second.itemsTotal, _BulkSource.count);
    // The windows neither repeat nor skip: the second one starts after the
    // first one ended, in the same SQL order.
    expect(
      second.items.first.title.compareTo(first.items.last.title),
      greaterThan(0),
    );
    await db.close();
  });

  test('a warm tab is served from the cache, a window at a time', () async {
    // The first visit fetches; every later visit must be a *read*. If this
    // falls through to the provider the tab sits on a spinner for minutes,
    // which is exactly what a phone showed on Movies with a warm catalogue.
    final db = await AppDatabase.openAt(dbPath());
    final source = _BulkSource();
    final repo = LibraryRepository(source: source, db: db);

    final cold = await repo.loadMedia(
      ContentKind.movie,
      loadAll: true,
      order: MediaOrder.releaseDateDesc,
    );
    expect(cold.fromCache, isFalse);
    final pagesAfterCold = source.requestedPages;

    final warm = await repo.loadMedia(
      ContentKind.movie,
      order: MediaOrder.releaseDateDesc,
    );
    expect(warm.fromCache, isTrue);
    expect(warm.items.length, LibraryRepository.kMediaWindow);
    expect(warm.itemsTotal, _BulkSource.count);
    expect(
      source.requestedPages,
      pagesAfterCold,
      reason: 'a warm read must not touch the provider',
    );
    await db.close();
  });

  test('a full refresh invalidates every per-category cache', () async {
    // The reported bug: after a catalogue refresh that brought new films, a
    // category kept showing the list from *before* it, and only that category's
    // own refresh fixed it. The category's `media_page_state` row outlived the
    // full replace, so `loadMedia` considered the cache authoritative.
    final db = await AppDatabase.openAt(dbPath());
    final source = _GrowingSource();
    final repo = LibraryRepository(source: source, db: db);

    final first = await repo.loadMedia(ContentKind.movie, categoryId: 'c1');
    expect(first.items.map((i) => i.title), ['Old film']);
    final callsAfterFirstVisit = source.categoryCalls;

    // The provider gained a film; the All view is refreshed. `forceRefresh` is
    // what the toolbar's Refresh (and the scheduled pass) uses — without it the
    // cache legitimately answers.
    source.addFilm('New film');
    final all = await repo.loadMedia(
      ContentKind.movie,
      forceRefresh: true,
      loadAll: true,
    );
    expect(all.items.map((i) => i.title), contains('New film'));

    // Switching back to the category must re-read it, not serve the snapshot
    // taken before the refresh.
    final again = await repo.loadMedia(ContentKind.movie, categoryId: 'c1');
    expect(again.items.map((i) => i.title), ['Old film', 'New film']);
    expect(source.categoryCalls, greaterThan(callsAfterFirstVisit));
    await db.close();
  });
}

/// Windows can still hold the sqlite `-wal`/`-shm` files open when `close()`
/// completes, so a bare recursive delete races and fails with
/// ERROR_DIR_NOT_EMPTY (errno 145). A leftover directory under the OS temp path
/// is not a test failure.
Future<void> _deleteTempDir(Directory dir) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

class _PagedSource extends Source {
  /// Every page the repository asked for, in order.
  final List<int> requestedPages = [];

  @override
  String get id => 'paged';

  @override
  String get name => 'Paged';

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [
    Category(id: 'c1', title: 'General'),
  ];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => const [
    Channel(id: 'a', name: 'A', categoryId: 'c1'),
  ];

  @override
  Future<StreamInfo> resolve(Channel channel) async =>
      const StreamInfo(url: 'http://stream');

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async => [
    MediaCategory(id: 'm1', title: 'Movies', kind: kind),
  ];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    requestedPages.add(page);
    return MediaPage(
      items: [
        for (var i = 0; i < kRowsPerPage; i++)
          MediaItem(id: 'p${page}i$i', title: 'P$page-$i', kind: kind),
      ],
      page: page,
      totalPages: kTotalPages,
    );
  }
}

/// A single-page catalogue bigger than one lazy window: 300 movies, so the
/// window boundary is observable without a slow fixture.
class _BulkSource extends Source {
  static const int count = 300;

  /// Every page the repository asked for, so a warm read can prove it asked for
  /// none.
  final List<int> requestedPages = [];

  @override
  String get id => 'bulk';

  @override
  String get name => 'Bulk';

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [
    Category(id: 'c1', title: 'General'),
  ];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => const [];

  @override
  Future<StreamInfo> resolve(Channel channel) async =>
      const StreamInfo(url: 'http://stream');

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async => [
    MediaCategory(id: 'm1', title: 'Movies', kind: kind),
  ];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    requestedPages.add(page);
    return MediaPage(
      items: [
        for (var i = 0; i < count; i++)
          MediaItem(
            id: 'm$i',
            // Zero-padded so title order IS numeric order.
            title: 'Movie ${i.toString().padLeft(4, '0')}',
            kind: kind,
          ),
      ],
      page: 1,
      totalPages: 1,
    );
  }

  @override
  Future<void> dispose() async {}
}

/// A provider that gains a film between two loads, to pin the "refresh, then
/// switch category" invalidation.
class _GrowingSource extends Source {
  /// Per-category fetches, so the test can prove the switch re-read the
  /// provider instead of serving the pre-refresh snapshot.
  int categoryCalls = 0;

  final List<MediaItem> _films = [
    MediaItem(
      id: 'f1',
      title: 'Old film',
      kind: ContentKind.movie,
      categoryId: 'c1',
    ),
  ];

  void addFilm(String title) {
    _films.add(
      MediaItem(
        id: 'f${_films.length + 1}',
        title: title,
        kind: ContentKind.movie,
        categoryId: 'c1',
      ),
    );
  }

  @override
  String get id => 'growing';

  @override
  String get name => 'Growing';

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [
    Category(id: 'c1', title: 'General'),
  ];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => const [];

  @override
  Future<StreamInfo> resolve(Channel channel) async =>
      const StreamInfo(url: 'http://stream');

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async => [
    MediaCategory(id: 'c1', title: 'Films', kind: kind),
  ];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    if (categoryId != null) categoryCalls++;
    final items = [
      for (final film in _films)
        if (categoryId == null || film.categoryId == categoryId) film,
    ];
    return MediaPage(items: items, page: 1, totalPages: 1);
  }

  @override
  Future<void> dispose() async {}
}

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
    expect(source.requestedPages, [1, 2],
        reason: 'one press, one page - the button promises page 2 and nothing else');
    expect(second.loadedPages, 2);
    expect(second.items.length, 2 * kRowsPerPage);
    expect(second.hasMore, isTrue);

    final third = await repo.loadMoreMedia(ContentKind.movie);
    expect(source.requestedPages, [1, 2, 3]);
    expect(third.loadedPages, 3);
    expect(third.items.length, 3 * kRowsPerPage);

    await db.close();
  });

  test('the last page ends paging instead of asking past the catalogue',
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
  });

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

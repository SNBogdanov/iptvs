// The guide cache is the largest thing this app stores (the field database was
// 792 MiB, 69% of it programmes), so its retention window and the WAL cap are
// pinned here rather than left to a comment.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_epg_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Programme programme(DateTime start, String title) => Programme(
    channelId: 'c1',
    start: start,
    stop: start.add(const Duration(hours: 1)),
    title: title,
  );

  Future<List<String>> titlesIn(String sourceId) async {
    final rows = await db.programmesForChannel(
      sourceId,
      'c1',
      from: DateTime.now().subtract(const Duration(days: 60)),
      to: DateTime.now().add(const Duration(days: 60)),
    );
    return [for (final p in rows) p.title];
  }

  test('the prune keeps the retention window and nothing outside it', () async {
    final now = DateTime.now();
    await db.replaceEpg('s1', [
      programme(now.subtract(const Duration(hours: 50)), 'too old'),
      programme(now.subtract(const Duration(hours: 10)), 'recent'),
      programme(now, 'now'),
      programme(now.add(const Duration(days: 3)), 'soon'),
      programme(now.add(const Duration(days: 9)), 'too far'),
    ]);
    // The write path stores the guide as given; pruning is housekeeping.
    expect(await titlesIn('s1'), hasLength(5));

    final removed = await db.pruneExpiredProgrammes();
    expect(removed, 2);
    expect(await titlesIn('s1'), ['recent', 'now', 'soon']);
  });

  test('the prune is per source and works without a sources row', () async {
    final now = DateTime.now();
    await db.replaceEpg('s1', [programme(now, 'now')]);
    await db.replaceEpg('s2', [
      programme(now.subtract(const Duration(days: 5)), 's2 old'),
      programme(now.add(const Duration(days: 2)), 's2 soon'),
    ]);

    await db.pruneExpiredProgrammes();

    expect(await titlesIn('s1'), ['now']);
    expect(await titlesIn('s2'), ['s2 soon']);
  });

  test('a guide entirely outside the window is cleared', () async {
    await db.replaceEpg('s1', [
      programme(DateTime.now().subtract(const Duration(days: 5)), 'ancient'),
    ]);
    await db.pruneExpiredProgrammes();
    expect(await titlesIn('s1'), isEmpty);
  });

  test('the streamed guide write keeps its rows until the prune', () async {
    final now = DateTime.now();
    await db.replaceEpgStream(
      's1',
      Stream.value([
        programme(now.subtract(const Duration(hours: 50)), 'too old'),
        programme(now, 'now'),
      ]),
    );
    expect(await titlesIn('s1'), hasLength(2));

    await db.pruneExpiredProgrammes();
    expect(await titlesIn('s1'), ['now']);
  });

  test('purging a source removes its rows and leaves the others', () async {
    final now = DateTime.now();
    await db.replaceEpg('s1', [programme(now, 's1 now')]);
    await db.replaceEpg('s2', [programme(now, 's2 now')]);

    await db.purgeSourceData('s1');

    expect(await titlesIn('s1'), isEmpty);
    expect(await titlesIn('s2'), ['s2 now']);
  });

  test('the purge chunks its deletes instead of locking the database', () async {
    final now = DateTime.now();
    await db.replaceEpg('s1', [
      programme(now, 'a'),
      programme(now.add(const Duration(minutes: 1)), 'b'),
      programme(now.add(const Duration(minutes: 2)), 'c'),
    ]);

    // chunk: 1 forces three separate transactions through `_deleteInChunks` —
    // the path that replaced one 50-second DELETE.
    await db.purgeSourceData('s1', chunk: 1);

    expect(await titlesIn('s1'), isEmpty);
  });

  test('the orphan sweep purges only sources not configured', () async {
    final now = DateTime.now();
    await db.replaceEpg('keep', [programme(now, 'keep')]);
    await db.replaceEpg('gone', [programme(now, 'gone')]);

    expect(await db.pruneOrphanedSources({'keep'}), 1);
    expect(await titlesIn('keep'), ['keep']);
    expect(await titlesIn('gone'), isEmpty);
  });

  test('an empty configured list does not purge anything', () async {
    // A failed keychain read must not wipe a working install's cache.
    await db.replaceEpg('s1', [programme(DateTime.now(), 'x')]);
    expect(await db.pruneOrphanedSources(<String>{}), 0);
    expect(await titlesIn('s1'), ['x']);
  });

  test('the WAL is capped and can be checkpointed', () async {    // 64 MiB: the field log had a 278 MB WAL, and `journal_size_limit` is what
    // stops a starved checkpoint from keeping it.
    expect(AppDatabase.kWALSizeLimitBytes, 64 * 1024 * 1024);
    final busy = await db.checkpointWal();
    expect(busy, isNotNull);
  });
}

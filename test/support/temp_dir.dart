import 'dart:io';

/// Deletes a test's scratch directory, retrying while Windows still holds a
/// transient handle on it.
///
/// SQLite's close (or an antivirus/indexer scan of the just-written database)
/// can outlive `await db.close()` by a few milliseconds. A single recursive
/// delete then fails with `ERROR_DIR_NOT_EMPTY` even though the files are gone,
/// turning a passing test into a teardown failure. Retrying a bounded number of
/// times absorbs that OS-level race without hiding a real leak: a directory that
/// is still in use after the last attempt still fails the test.
Future<void> deleteTestTempDir(Directory dir) async {
  const attempts = 40;
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (!dir.existsSync()) return;
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == attempts - 1) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

import 'dart:io';

import 'package:path/path.dart' as p;

import 'diagnostics_log.dart';

/// The `%APPDATA%` folder the pre-fork builds used.
///
/// `path_provider` derives the application-support directory on Windows from
/// the executable's VERSIONINFO — `CompanyName\ProductName` — and the fork
/// renamed the company to `SNBogdanov` (`windows/runner/Runner.rc`). The folder
/// therefore moved from `%APPDATA%\GCHOfficial\iptvs` to
/// `%APPDATA%\SNBogdanov\iptvs`, and an existing install would otherwise come up
/// with an empty database, default settings and no secure-storage entries.
const List<String> _legacyOwnerSegments = ['GCHOfficial', 'iptvs'];

/// Moves an old build's data into [target] once.
///
/// Runs only when the target holds no `iptv.db` yet **and** the legacy folder
/// exists, so it is a one-shot upgrade path rather than something that runs on
/// every launch: after the copy the database is there, and the guard skips it.
/// Copy (not move) leaves the old folder intact for a rollback; failures are
/// logged and never block startup — a broken migration must not stop the app
/// from opening with a fresh profile.
Future<void> migrateLegacyWindowsData(Directory target) async {
  if (!Platform.isWindows) return;
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) return;

  final legacy = Directory(p.joinAll([appData, ..._legacyOwnerSegments]));
  if (!await legacy.exists()) return;
  if (identical(p.normalize(legacy.path), p.normalize(target.path))) return;
  if (await File(p.join(target.path, 'iptv.db')).exists()) return;

  try {
    final copied = await _copyTree(legacy, target);
    DiagnosticsLog.instance.add(
      'storage',
      'Migrated $copied file(s) from ${legacy.path}',
    );
  } catch (e) {
    DiagnosticsLog.instance.add(
      'storage',
      'Legacy data migration failed: $e',
    );
  }
}

/// Copies every file under [from] into [to], keeping the directory shape and
/// never overwriting a file the new install has already written.
Future<int> _copyTree(Directory from, Directory to) async {
  var copied = 0;
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: from.path);
    final destination = p.join(to.path, relative);
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
      continue;
    }
    if (entity is! File) continue;
    final target = File(destination);
    if (await target.exists()) continue;
    await target.parent.create(recursive: true);
    await entity.copy(destination);
    copied++;
  }
  return copied;
}

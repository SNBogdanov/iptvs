import '../sources/source_config.dart';
import 'app_database.dart';
import 'diagnostics_log.dart';
import 'net.dart' show redactText;

/// Moves pre-PR4 cache/user-state keys to the stable source and channel
/// identities before a [Source] can publish rows under those identities.
Future<void> migrateSourceIdentity(AppDatabase db, SourceConfig config) async {
  await db.migrateSourceNamespace(config.legacyCacheId, config.id);
  if (config.kind == SourceKind.m3u) {
    await db.migrateM3uChannelIds(config.id);
  }
}

/// Migrates every source's identities, **never throwing for one bad source**.
///
/// This runs from `main()` before `runApp`, so an exception escaping here aborts
/// startup with no first frame — no window, no on-screen error, just a process
/// that appears not to launch. A single source that cannot be migrated (a legacy
/// row the repair cannot resolve, a corrupt row) must not take the whole app
/// with it: the failure is logged, redacted, and the remaining sources are still
/// migrated, because they are independent namespaces.
Future<void> migrateAllSourceIdentities(
  AppDatabase db,
  Iterable<SourceConfig> configs,
) async {
  for (final config in configs) {
    try {
      await migrateSourceIdentity(db, config);
    } catch (error) {
      DiagnosticsLog.instance.addAndPrint(
        'boot',
        'source identity migration failed for "${redactText(config.label)}" '
        '(${config.kind.name}, ${redactText(config.id)}): '
        '${error.runtimeType}: ${redactText('$error')}',
      );
    }
  }
}

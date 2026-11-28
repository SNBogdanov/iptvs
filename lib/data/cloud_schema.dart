/// What the app expects from the cloud schema, and what the server reports.
///
/// The server stores a monotonic version in `app_schema` and exposes it through
/// the public `get_schema_version()` RPC. This constant is raised in the same
/// commit as the migration that needs it; comparing the two lets the app say
/// **why** a feature is unavailable instead of failing on a missing function.
///
/// Migration convention: every new migration ends with
/// `update app_schema set version = <new>` — see
/// `supabase/migrations/20261128010000_schema_version.sql`.
class CloudSchema {
  CloudSchema._();

  /// The schema this build understands. Must match the newest migration's
  /// `app_schema.version` (pinned by `test/cloud_schema_test.dart`).
  static const int currentVersion = 2026112801;

  /// First version that carries `device_settings` and its RPCs.
  static const int deviceSettingsVersion = 2026112801;

  /// Last version the server reported in this process, or null when it has not
  /// answered yet / could not be reached. `0` means an older server that does
  /// not expose `get_schema_version` at all.
  static int? knownServerVersion;

  /// Whether the currently known server has [feature] (a version constant).
  /// Unknown servers count as 0, so a feature is disabled until the version is
  /// actually read.
  static bool supports(int feature) => (knownServerVersion ?? 0) >= feature;

  static CloudSchemaState stateFor(int? serverVersion) {
    if (serverVersion == null) return CloudSchemaState.unknown;
    if (serverVersion <= 0) return CloudSchemaState.legacy;
    if (serverVersion < currentVersion) return CloudSchemaState.outdated;
    if (serverVersion > currentVersion) return CloudSchemaState.newer;
    return CloudSchemaState.upToDate;
  }

  /// Test isolation: the version is process-cached by design.
  static void resetForTest() => knownServerVersion = null;
}

enum CloudSchemaState {
  /// The server did not answer (offline) — do not draw a conclusion.
  unknown,

  /// A pre-versioning server: no `get_schema_version`.
  legacy,

  /// The server has fewer migrations than this app expects.
  outdated,

  /// Server and app agree.
  upToDate,

  /// The server is ahead of this app; an update is the fix.
  newer,
}

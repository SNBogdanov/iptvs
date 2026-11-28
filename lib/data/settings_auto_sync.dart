import 'dart:async';

import 'app_settings_store.dart';
import 'cloud_runtime.dart';
import 'cloud_schema.dart';
import 'cloud_sync.dart';
import 'device_identity.dart';

/// Whether the cloud copy should overwrite the local preference map.
///
/// No local marker means a fresh keychain (a reinstall) and the cloud wins; a
/// marker means this device has a local state and only a cloud copy newer than
/// that marker wins. Pure so the reinstall rule is pinned by a unit test.
bool shouldApplyCloudSettings({
  required DateTime? localSyncedAt,
  required DateTime? cloudUpdatedAt,
}) {
  if (localSyncedAt == null) return true;
  return cloudUpdatedAt != null && cloudUpdatedAt.isAfter(localSyncedAt);
}

/// Keeps the **app preferences of this physical device** in the cloud.
///
/// The profile sync (`CloudSync`) covers sources, metadata, favorites and watch
/// state. This service covers the other half: the key/value map in
/// [AppSettingsStore], keyed by [DeviceIdentity]'s hardware-derived hash, so a
/// reinstall on the same device can pull its settings back even though the new
/// install has a new anonymous Supabase user.
///
/// Rules:
/// - **Fresh keychain wins the cloud copy**: no local sync marker means this is
///   a reinstall; the cloud map is applied and then kept up to date.
/// - **Existing device is authoritative**: with a marker present, local changes
///   are pushed (debounced from [AppSettingsStore.changes]); the cloud copy is
///   applied only when it is newer than the marker.
/// - **Best effort**: no server, no session or an offline backend is a no-op;
///   cloud sync of sources must never be blocked by this.
/// - The server stores the whole map, last write wins by its `now()`.
class SettingsAutoSync {
  SettingsAutoSync._();

  static final SettingsAutoSync instance = SettingsAutoSync._();

  static const AppSettingsStore _store = AppSettingsStore();

  CloudSync? _sync;
  bool _started = false;
  bool _reconciling = false;
  bool _pushing = false;
  Timer? _debounce;
  Timer? _periodic;

  /// Starts listening for preference changes and performs an initial
  /// reconciliation. Safe to call more than once.
  static Future<void> start({CloudSync? sync}) async {
    final self = instance;
    if (!self._started) {
      self._started = true;
      self._sync = sync;
      AppSettingsStore.changes.addListener(self._onChanged);
      // A periodic flush covers changes made through stores this service does
      // not notify about (the profile-picker preference) and a missed debounce.
      self._periodic = Timer.periodic(
        const Duration(minutes: 5),
        (_) => unawaited(self._push()),
      );
    }
    await self._reconcile();
  }

  /// Pulls-or-pushes without waiting for a settings change. Called after
  /// pairing, on a manual Pull, and from [start].
  static Future<void> reconcile() => instance._reconcile();

  /// Publishes the current map now (app pause, "Push to panel", tests).
  static Future<void> pushNow() => instance._push();

  /// Test isolation: the service is process-wide by design.
  static void resetForTest() {
    final self = instance;
    AppSettingsStore.changes.removeListener(self._onChanged);
    self._started = false;
    self._sync = null;
    self._debounce?.cancel();
    self._debounce = null;
    self._periodic?.cancel();
    self._periodic = null;
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(seconds: 2),
      () => unawaited(_push()),
    );
  }

  Future<void> _reconcile() async {
    if (_reconciling) return;
    _reconciling = true;
    try {
      if (!CloudRuntime.hasServer) return;
      final sync = _sync ??= CloudSync();
      if (!sync.hasSession) return;

      // Device settings need the schema that introduced them. Read the version
      // once; an older server (or no function at all) makes this a no-op, and
      // the Cloud sync screen says so.
      if (!CloudSchema.supports(CloudSchema.deviceSettingsVersion)) {
        final version = await sync.schemaVersion();
        if (version == null || version < CloudSchema.deviceSettingsVersion) return;
      }

      final deviceKey = await DeviceIdentity.cloudDeviceKey();
      final local = await _store.settingsForCloud();
      final marker = await _store.cloudSettingsSyncedAt();
      final cloud = await sync.pullDeviceSettings(deviceKey);

      if (cloud != null) {
        final raw = cloud['settings'];
        final updated = DateTime.tryParse(
          cloud['updated_at']?.toString() ?? '',
        )?.toUtc();
        // A device that never synced (fresh install) and a cloud copy newer
        // than this device's marker both mean: the cloud wins.
        if (raw is Map &&
            shouldApplyCloudSettings(
              localSyncedAt: marker,
              cloudUpdatedAt: updated,
            )) {
          final settings = <String, String>{
            for (final entry in raw.entries)
              if (entry.value is String)
                entry.key.toString(): entry.value as String,
          };
          await _store.applyCloudSettings(settings);
          await _store.setCloudSettingsSyncedAt(
            updated ?? DateTime.now().toUtc(),
          );
          return;
        }
      }

      if (local.isNotEmpty) {
        await _push(sync: sync, deviceKey: deviceKey, settings: local);
      }
    } catch (_) {
      // Offline, older backend, or a transient RPC error: try again on the
      // next change / launch / manual pull.
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _push({
    CloudSync? sync,
    String? deviceKey,
    Map<String, String>? settings,
  }) async {
    if (_pushing) return;
    _pushing = true;
    try {
      if (!CloudRuntime.hasServer) return;
      final client = sync ?? (_sync ??= CloudSync());
      if (!client.hasSession) return;
      // Unknown/older schema: leave the local map alone rather than marking it
      // synced against a backend that will reject the RPC.
      if (!CloudSchema.supports(CloudSchema.deviceSettingsVersion)) {
        final version = await client.schemaVersion();
        if (version == null || version < CloudSchema.deviceSettingsVersion) return;
      }
      final key = deviceKey ?? await DeviceIdentity.cloudDeviceKey();
      final map = settings ?? await _store.settingsForCloud();
      if (map.isEmpty) return;
      final saved = await client.pushDeviceSettings(key, map);
      if (!saved) return;
      await _store.setCloudSettingsSyncedAt(DateTime.now().toUtc());
    } catch (_) {
      // Best effort; a later change or launch retries.
    } finally {
      _pushing = false;
    }
  }
}

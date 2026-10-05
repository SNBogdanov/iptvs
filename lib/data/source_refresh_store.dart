import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Device-local record of when each source's catalogue was last refreshed —
/// automatically or by hand — so [SourceRefreshInterval] can decide whether the
/// next load is due.
///
/// **Deliberately not `SourceConfig.settings`.** That blob rides the source row
/// into the cloud: a last-refresh timestamp there would push a timestamp-shaped
/// rewrite on every refresh, advance `profiles.updated_at` through
/// `touch_profile_snapshot_revision`, and hand a paired device a clock reading
/// that describes *this* device's schedule rather than anything account-wide.
/// The same argument [ExpiryCache] and [LastChannelStore] make.
///
/// **Not a database table either.** It is a timestamp per source with no query
/// surface, so a schema version and a migration would buy nothing over the
/// keychain the neighbouring device-local stores already use.
///
/// One keychain entry holding a `{sourceId: epochMs}` map rather than a key per
/// source: the whole source list already lives under a single storage key, so a
/// map stays smaller and never accumulates orphans for deleted sources.
class SourceRefreshStore {
  static const _key = 'source_last_refresh';

  final FlutterSecureStorage _storage;

  const SourceRefreshStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// The last refresh time for [sourceId], or null when it has never run.
  Future<DateTime?> lastRefresh(String sourceId) async {
    final all = await _readAll();
    final ms = all[sourceId];
    if (ms is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setLastRefresh(String sourceId, DateTime when) async {
    if (sourceId.isEmpty) return;
    final all = await _readAll();
    all[sourceId] = when.millisecondsSinceEpoch;
    await _writeAll(all);
  }

  /// Drops [sourceId]'s record — for a deleted source, so a later source that
  /// happens to take the id cannot inherit its schedule.
  Future<void> forget(String sourceId) async {
    final all = await _readAll();
    if (all.remove(sourceId) == null) return;
    await _writeAll(all);
  }

  Future<Map<String, dynamic>> _readAll() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeAll(Map<String, dynamic> all) async {
    if (all.isEmpty) {
      await _storage.delete(key: _key);
      return;
    }
    await _storage.write(key: _key, value: jsonEncode(all));
  }
}

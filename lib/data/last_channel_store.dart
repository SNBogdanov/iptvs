import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'cloud_config.dart';
import 'cloud_sync.dart';
import 'local_profile_store.dart';

/// The live channel a profile was last watching, and the source it belongs to.
///
/// Both halves are load-bearing. A channel id is unique only *within* a
/// provider, so [sourceId] is what makes [channelId] mean one channel — the
/// same reason the cross-source favorites view keys its EPG on
/// `(sourceId, channelId)`. And a record naming a different source than the
/// one now active describes a channel the app cannot draw, so the pair is
/// checked together rather than the id alone.
@immutable
class LastChannel {
  const LastChannel({required this.sourceId, required this.channelId});

  final String sourceId;
  final String channelId;

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'channelId': channelId,
  };

  /// Returns null rather than throwing for anything malformed: this is a
  /// disposable convenience record, and the correct response to a bad entry is
  /// to start normally — never to fail a launch over it.
  static LastChannel? fromJson(Object? json) {
    if (json is! Map) return null;
    final sourceId = json['sourceId'];
    final channelId = json['channelId'];
    if (sourceId is! String || channelId is! String) return null;
    if (sourceId.isEmpty || channelId.isEmpty) return null;
    return LastChannel(sourceId: sourceId, channelId: channelId);
  }

  @override
  bool operator ==(Object other) =>
      other is LastChannel &&
      other.sourceId == sourceId &&
      other.channelId == channelId;

  @override
  int get hashCode => Object.hash(sourceId, channelId);

  @override
  String toString() => 'LastChannel($sourceId, $channelId)';
}

/// The bucket an install with no active profile records under.
///
/// Deleting the active profile deliberately leaves the state *ownerless*
/// (nothing marked active) so nothing claims the empty baseline — and the
/// picker is still the way out of it. A resume feature that quietly stopped
/// working on exactly that state would be a poor trade for a tidy key, so
/// ownerless gets its own bucket instead of no bucket.
const String kNoProfileResumeKey = '@none';

/// Device-local record of the last live channel each profile was watching.
///
/// **Deliberately not `SourceConfig.settings`.** That blob rides the source row
/// into the cloud (`push_sources`), and this is the same argument
/// [ExpiryCache] makes: a last-watched channel is device-local, disposable and
/// derived — it describes *this* device's last few minutes, not account state
/// another device should adopt. Writing it into `settings` would push a
/// timestamp-shaped rewrite on every channel change, advance
/// `profiles.updated_at` through `touch_profile_snapshot_revision`, and hand a
/// paired phone the channel the television was watching.
///
/// **Not a database table either.** It is a two-field convenience record with
/// no query surface, so a schema version and a migration would buy nothing over
/// the keychain the neighbouring device-local stores already use (the whole
/// source list lives under one key there, so a map keyed by profile is
/// smaller than the alternatives).
///
/// The [enabled] half of the feature — whether to resume at all — is *not*
/// here. It is a deliberate user preference, so it lives on the source
/// ([SourceConfig.autoResumeLastChannel]) beside `aspectMode` and
/// `bufferPreset`, and travels with the source like them.
class LastChannelStore {
  static const _key = 'resume_last_channel';

  final FlutterSecureStorage _storage;

  const LastChannelStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// The channel [profileKey] was last watching, or null.
  Future<LastChannel?> read(String profileKey) async {
    final all = await _readAll();
    return LastChannel.fromJson(all[profileKey]);
  }

  Future<void> write(String profileKey, LastChannel channel) async {
    if (profileKey.isEmpty) return;
    final all = await _readAll();
    if (all[profileKey] == channel.toJson()) return; // nothing changed
    all[profileKey] = channel.toJson();
    await _writeAll(all);
  }

  /// Drops [profileKey]'s record — for a deleted profile, so a later profile
  /// that happens to take the id cannot inherit it.
  Future<void> forget(String profileKey) async {
    final all = await _readAll();
    if (all.remove(profileKey) == null) return;
    await _writeAll(all);
  }

  Future<void> clear() => _storage.delete(key: _key);

  /// The bucket the *currently active* profile records under.
  ///
  /// Local first, then cloud — the same precedence [HomeShell]'s profile info
  /// uses, so the avatar and this can never name different profiles. Reads two
  /// stores, so it is called on the boot path once and nowhere hot.
  ///
  /// Fails **closed to [kNoProfileResumeKey]**: an unreadable keychain must not
  /// disable resuming, it must just pick the ownerless bucket.
  static Future<String> activeProfileKey() async {
    try {
      final local = await LocalProfileStore().activeId();
      if (local != null && local.isNotEmpty) return local;
    } catch (_) {
      // Fall through to the cloud profile, then to the ownerless bucket.
    }
    if (CloudConfig.isConfigured) {
      try {
        final cloud = await CloudSync().activeProfileId();
        if (cloud != null && cloud.isNotEmpty) return cloud;
      } catch (_) {}
    }
    return kNoProfileResumeKey;
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

/// What start-up should do with a stored last channel.
enum ResumeAction {
  /// Leave the app's normal start alone.
  none,

  /// Put the cursor on the channel and scroll it into view.
  select,

  /// The same, and start its preview — but only where a preview is drawn.
  selectAndPreview,
}

/// The start-up decision, as a pure function so it is testable without a
/// keychain, a widget, or a provider.
///
/// The rules, and why each is here:
///
/// - **Off unless the source says otherwise** — [enabled] is the user's
///   preference, and its default lives on the config, not here.
/// - **The pair must match the active source.** A record from another source
///   names a channel this list cannot draw; the honest outcome is a normal
///   start, not a search for it.
/// - **[drawable] is the same requirement the typed-number jump has.** A
///   channel no view can draw cannot be selected, and naming it in the UI
///   without showing it is the one outcome worse than not resuming.
/// - **A preview only where one is drawn.** The narrow layout has no preview
///   panel, so starting one there would spend a provider connection on video
///   nobody can see — on a single-connection portal that connection is the
///   user's, not spare.
/// - **Never on top of something already playing.** Resolving into a running
///   preview would double-connect, and into a resolving one would race it.
ResumeAction planResumeAction({
  required bool enabled,
  required String activeSourceId,
  required LastChannel? stored,
  required bool drawable,
  required bool previewVisible,
  required bool somethingAlreadyPlaying,
}) {
  if (!enabled) return ResumeAction.none;
  if (stored == null) return ResumeAction.none;
  if (stored.sourceId != activeSourceId) return ResumeAction.none;
  if (!drawable) return ResumeAction.none;
  if (somethingAlreadyPlaying) return ResumeAction.none;
  return previewVisible ? ResumeAction.selectAndPreview : ResumeAction.select;
}

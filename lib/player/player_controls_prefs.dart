import 'package:flutter/foundation.dart';

import '../data/app_settings_store.dart';

/// One optional control in the player's chrome.
///
/// The list is deliberately the *user's* vocabulary, not the code's: the
/// setting exists because a full overlay on a phone was reported as "too
/// cluttered", so what can be turned off is every button that is not play/pause
/// — the one control a player cannot do without, and the one that holds the
/// overlay's initial focus.
enum PlayerControl {
  previousNext('previous_next', 'Previous / Next'),
  seek10('seek10', 'Back / forward 10 s'),
  mute('mute', 'Mute'),
  volume('volume', 'Volume bar'),
  quickList('quick_list', 'Channel list'),
  favorite('favorite', 'Favorite'),
  subtitles('subtitles', 'Subtitles'),
  aspect('aspect', 'Aspect ratio'),
  pip('pip', 'Picture in picture'),
  info('info', 'Stream info');

  const PlayerControl(this.storageName, this.label);

  /// Wire/disk name. Shared verbatim with the natives (`hidden_controls` on the
  /// Android open Intent), so it must not be renamed casually.
  final String storageName;
  final String label;

  static PlayerControl? parse(String? raw) {
    for (final value in PlayerControl.values) {
      if (value.storageName == raw) return value;
    }
    return null;
  }
}

/// Which of [PlayerControl] the user has switched off.
///
/// **Absence is the default, and it means everything is shown** — an install
/// that never opens this setting draws exactly the chrome it always has, and a
/// key written by a newer build can only ever hide a control this build also
/// knows (see [decode]).
@immutable
class PlayerControlsPrefs {
  const PlayerControlsPrefs({this.hidden = const {}});

  final Set<PlayerControl> hidden;

  bool shows(PlayerControl control) => !hidden.contains(control);

  /// The wire name list the Android player reads from its open Intent.
  String get wireValue =>
      (hidden.map((c) => c.storageName).toList()..sort()).join(',');

  /// Unknown names are dropped rather than rejected: a newer build may know a
  /// control this one does not, and refusing the whole value would resurrect
  /// every control the user did turn off.
  static PlayerControlsPrefs decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const PlayerControlsPrefs();
    final hidden = <PlayerControl>{};
    for (final part in raw.split(',')) {
      final control = PlayerControl.parse(part.trim());
      if (control != null) hidden.add(control);
    }
    return PlayerControlsPrefs(hidden: hidden);
  }

  PlayerControlsPrefs withVisible(PlayerControl control, bool visible) {
    final next = {...hidden};
    if (visible) {
      next.remove(control);
    } else {
      next.add(control);
    }
    return PlayerControlsPrefs(hidden: next);
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerControlsPrefs && setEquals(other.hidden, hidden);

  @override
  int get hashCode => Object.hashAllUnordered(hidden);
}

/// Live mirror of the stored choice; the settings screen and every overlay read
/// this, and nothing re-reads the keychain.
final ValueNotifier<PlayerControlsPrefs> playerControlsPrefs =
    ValueNotifier(const PlayerControlsPrefs());

/// Reads the stored choice into [playerControlsPrefs]. Called once at boot.
Future<void> loadPlayerControlsPrefs({AppSettingsStore? store}) async {
  final raw = await (store ?? const AppSettingsStore()).rawHiddenPlayerControls();
  playerControlsPrefs.value = PlayerControlsPrefs.decode(raw);
}

/// Sets one control's visibility and persists the whole set.
///
/// Publishes first, persists second — the same order as every other preference
/// here: a failed write must not leave the session drawing the old chrome after
/// the user watched the toggle move.
Future<void> setPlayerControlVisible(
  PlayerControl control,
  bool visible, {
  AppSettingsStore? store,
}) async {
  final next = playerControlsPrefs.value.withVisible(control, visible);
  playerControlsPrefs.value = next;
  await (store ?? const AppSettingsStore()).setRawHiddenPlayerControls(
    next.hidden.isEmpty ? null : next.wireValue,
  );
}

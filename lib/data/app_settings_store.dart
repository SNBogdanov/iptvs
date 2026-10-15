import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../player/next_video_policy.dart';
import '../player/seek_step.dart';

/// Global (profile-independent) app preferences, persisted in the OS keychain.
///
/// Deliberately separate from [SourceStore] (per-source) and the per-profile
/// stores: these are device-wide toggles that hold for every profile and
/// survive a profile switch. The app has no SharedPreferences, so the keychain
/// is the home for this the same way [UpdateStore] is for the updater.
class AppSettingsStore {
  static const _kCloseToTray = 'app_close_to_tray';
  static const _kRandomZapping = 'app_random_zapping';
  static const _kAlwaysOnTop = 'app_always_on_top';
  static const _kRememberPlacement = 'app_remember_window_placement';
  static const _kWindowPlacement = 'app_window_placement';
  static const _kVodCardOrientation = 'app_vod_card_orientation';
  static const _kShowPlayerClock = 'app_show_player_clock';
  static const _kShowPlaybackTimes = 'app_show_playback_times';
  static const _kShowChannelName = 'app_show_channel_name';
  static const _kAutoPlayNext = 'app_auto_play_next';
  static const _kNextVideoBehavior = 'app_next_video_behavior';
  static const _kSeekStepSeconds = 'app_seek_step_seconds';

  final FlutterSecureStorage _storage;

  const AppSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Whether closing the window hides it to the tray instead of quitting
  /// (Windows only; docs/player.md "System tray icon"). Defaults to true — only
  /// an explicit `false` is written, so an absent key reads as "on" and a stray
  /// value can never read as a toggle the user did not make.
  Future<bool> closeToTray() async =>
      (await _storage.read(key: _kCloseToTray)) != 'false';

  Future<void> setCloseToTray(bool value) async {
    if (value) {
      await _storage.delete(key: _kCloseToTray);
    } else {
      await _storage.write(key: _kCloseToTray, value: 'false');
    }
  }

  /// Whether zapping picks a random channel instead of the next one
  /// (docs/player.md "System tray icon" → "Random zapping"). Defaults to false;
  /// only an explicit `true` is written, so an absent key reads as "off".
  Future<bool> randomZapping() async =>
      (await _storage.read(key: _kRandomZapping)) == 'true';

  Future<void> setRandomZapping(bool value) async {
    if (value) {
      await _storage.write(key: _kRandomZapping, value: 'true');
    } else {
      await _storage.delete(key: _kRandomZapping);
    }
  }

  /// Whether the window stays above other windows while playback is running
  /// (Windows only; docs/player.md "System tray icon" → "Always on top during
  /// playback"). Defaults to false; only an explicit `true` is written.
  Future<bool> alwaysOnTop() async =>
      (await _storage.read(key: _kAlwaysOnTop)) == 'true';

  Future<void> setAlwaysOnTop(bool value) async {
    if (value) {
      await _storage.write(key: _kAlwaysOnTop, value: 'true');
    } else {
      await _storage.delete(key: _kAlwaysOnTop);
    }
  }

  /// Whether the window's position and size are remembered between runs
  /// (Windows only). Defaults to true - remembering is the whole point of the
  /// feature, so an absent key reads as "on" and only an explicit `false` is
  /// written. Turning it off also forgets what was recorded, rather than
  /// keeping a stale record the setting claims no longer applies.
  Future<bool> rememberWindowPlacement() async =>
      (await _storage.read(key: _kRememberPlacement)) != 'false';

  Future<void> setRememberWindowPlacement(bool value) async {
    if (value) {
      await _storage.delete(key: _kRememberPlacement);
      return;
    }
    await _storage.write(key: _kRememberPlacement, value: 'false');
    await _storage.delete(key: _kWindowPlacement);
  }

  /// The last recorded placement, as written by `WindowPlacement.encode`, or
  /// null when nothing was ever recorded. Physical pixels in the frame rect,
  /// the same space `setWindowPlacement` expects.
  Future<String?> windowPlacement() => _storage.read(key: _kWindowPlacement);

  Future<void> setWindowPlacement(String value) =>
      _storage.write(key: _kWindowPlacement, value: value);

  /// The stored VOD/series card orientation as `VodCardOrientation.storageValue`,
  /// or null when nothing was ever chosen — which reads as the default.
  ///
  /// Deliberately an opaque string rather than a typed getter, like
  /// [LastChannelStore]'s blob: the enum owns the encoding and this store owns
  /// none of it, so there is one place that knows what "landscape" is written
  /// as and it is not this file.
  Future<String?> rawVodCardOrientation() =>
      _storage.read(key: _kVodCardOrientation);

  /// Pass null to clear the key rather than to store an empty value — the
  /// default is *absence*, so a write of "portrait" would mean the same thing
  /// while making the keychain look like the user had chosen something.
  Future<void> setRawVodCardOrientation(String? value) async {
    if (value == null) {
      await _storage.delete(key: _kVodCardOrientation);
    } else {
      await _storage.write(key: _kVodCardOrientation, value: value);
    }
  }

  /// Whether the player's wall-clock badge is drawn (docs/player.md "The live
  /// chrome is one layout on every surface").
  ///
  /// Defaults to true — the clock is what every surface draws today, so this
  /// hides an existing badge rather than adding one, and only an explicit
  /// `false` is written. **When on it also keeps the clock on screen during
  /// playback**: the shared Flutter overlay draws it top-right while the chrome
  /// is hidden, not only while a panel is up, so the wall clock stays readable
  /// without moving the mouse. See `player_overlay.dart`'s `_persistentHud`.
  ///
  /// Android is the one surface that answers a *second* question here — its
  /// clock badge is TV-only (`PlayerUiState.isTv`), because a phone already
  /// shows the system clock in its status bar. Turning this off hides the badge
  /// where it exists and changes nothing where it never was.
  Future<bool> showPlayerClock() async =>
      (await _storage.read(key: _kShowPlayerClock)) != 'false';

  Future<void> setShowPlayerClock(bool value) async {
    if (value) {
      await _storage.delete(key: _kShowPlayerClock);
    } else {
      await _storage.write(key: _kShowPlayerClock, value: 'false');
    }
  }

  /// Whether the VOD position/duration readout is drawn beside the scrubber.
  ///
  /// Defaults to true; only an explicit `false` is written. VOD/series only —
  /// live has no scrubber and no readout on any surface, so the key has nothing
  /// to answer there. **Hides the labels, not the bar**: the scrubber stays
  /// draggable and keeps reporting position, so a hidden readout costs the user
  /// an at-a-glance position, not the ability to seek. When on, the shared
  /// Flutter overlay also keeps the readout bottom-right while the chrome is
  /// hidden (see [showPlayerClock]).
  Future<bool> showPlaybackTimes() async =>
      (await _storage.read(key: _kShowPlaybackTimes)) != 'false';

  Future<void> setShowPlaybackTimes(bool value) async {
    if (value) {
      await _storage.delete(key: _kShowPlaybackTimes);
    } else {
      await _storage.write(key: _kShowPlaybackTimes, value: 'false');
    }
  }

  /// Whether the channel/title name is drawn. Defaults to true; only an
  /// explicit `false` is written.
  ///
  /// The name lives in the chrome's top bar, so this is the peer of
  /// [showPlayerClock] for the picture's other side: **when on, the shared
  /// Flutter overlay also keeps the name top-left while the chrome is
  /// hidden** (see [showPlayerClock]) — the top-left counterpart of the clock
  /// badge it keeps top-right, so a live session still says which channel
  /// is on without moving the mouse.
  Future<bool> showChannelName() async =>
      (await _storage.read(key: _kShowChannelName)) != 'false';

  Future<void> setShowChannelName(bool value) async {
    if (value) {
      await _storage.delete(key: _kShowChannelName);
    } else {
      await _storage.write(key: _kShowChannelName, value: 'false');
    }
  }

  /// Whether a film or episode moves on to its sibling when it plays to the
  /// end (VOD/series only; live never completes). Defaults to false, so only an
  /// explicit `true` is written and an untouched install stops at the credits
  /// as it always has.
  ///
  /// Read by `channel_list_screen._playMedia` and carried on
  /// [PlaybackContext]; the player resolves the next title off the session it
  /// was launched with, never the catalogue.
  Future<bool> autoPlayNextVideo() async =>
      (await _storage.read(key: _kAutoPlayNext)) == 'true';

  Future<void> setAutoPlayNextVideo(bool value) async {
    if (value) {
      await _storage.write(key: _kAutoPlayNext, value: 'true');
    } else {
      await _storage.delete(key: _kAutoPlayNext);
    }
  }

  /// How auto-advance treats a next title that was already played. A no-op
  /// until [autoPlayNextVideo] is on; absent reads as
  /// [NextVideoPlayedBehavior.resumeOrSkip]. The enum owns the encoding, so
  /// this store carries an opaque string (same contract as
  /// [rawVodCardOrientation]).
  Future<NextVideoPlayedBehavior> nextVideoPlayedBehavior() async =>
      NextVideoPlayedBehavior.parse(await _storage.read(key: _kNextVideoBehavior));

  Future<void> setNextVideoPlayedBehavior(NextVideoPlayedBehavior value) async {
    // The default is absence, so writing it back would make the keychain look
    // like a choice the user made.
    if (value == NextVideoPlayedBehavior.resumeOrSkip) {
      await _storage.delete(key: _kNextVideoBehavior);
    } else {
      await _storage.write(key: _kNextVideoBehavior, value: value.storageValue);
    }
  }

  /// How far one Left/Right press, or one `-N`/`+N` tap, moves a VOD position
  /// (VOD/series only — live has no scrubber on any surface).
  ///
  /// Absent, or a value this build does not recognise, reads as
  /// [kDefaultSeekStepSeconds] (10 s — the step this preference replaced), so an
  /// install that never opens Settings seeks exactly as it always has. The
  /// allowed ladder lives in `player/seek_step.dart`; this store keeps only the
  /// number, and normalising on read means a hand-edited keychain cannot put a
  /// nonsense step on screen.
  Future<int> seekStepSeconds() async =>
      normalizeSeekStep(int.tryParse(await _storage.read(key: _kSeekStepSeconds) ?? ''));

  Future<void> setSeekStepSeconds(int value) async {
    final step = normalizeSeekStep(value);
    // Store the default as absence, the same contract as every other toggle
    // here: a written key should mean a choice the user actually made.
    if (step == kDefaultSeekStepSeconds) {
      await _storage.delete(key: _kSeekStepSeconds);
    } else {
      await _storage.write(key: _kSeekStepSeconds, value: '$step');
    }
  }
}

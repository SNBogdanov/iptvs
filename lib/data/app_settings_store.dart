import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
}

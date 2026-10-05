import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/player/linux_native_session.dart';
import 'package:iptvs/player/player_chrome_prefs.dart';

/// The two player-chrome preferences are one default-on boolean behind three
/// layers — the keychain, the notifier every surface reads, and each native
/// overlay's own default — and the only way they break is a disagreement
/// between them. So this drives the real store over the mocked keychain the
/// rest of the suite uses, rather than a fake, and pins the *direction* each
/// layer fails in: absence means "on" (what an untouched install draws), never
/// "off".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = AppSettingsStore();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    showPlayerClock.value = true;
    showPlaybackTimes.value = true;
  });

  group('the keychain contract', () {
    test('an untouched install reads both as on', () async {
      // The whole point of default-on: an absent key is what every surface
      // draws today, so a missing/never-written preference cannot be
      // distinguished from a user who never touched the tile.
      expect(await store.showPlayerClock(), isTrue);
      expect(await store.showPlaybackTimes(), isTrue);
    });

    test('only an explicit false turns one off', () async {
      await store.setShowPlayerClock(false);
      await store.setShowPlaybackTimes(false);

      expect(await store.showPlayerClock(), isFalse);
      expect(await store.showPlaybackTimes(), isFalse);
    });

    test('turning one back on deletes the key, not stores "true"', () async {
      // Same reason closeToTray does it: a keychain that reads "the user chose
      // this" for the default is a lie the next reader has to special-case.
      await store.setShowPlayerClock(false);
      await store.setShowPlayerClock(true);

      expect(await store.showPlayerClock(), isTrue);
      expect(
        await const FlutterSecureStorage().read(key: 'app_show_player_clock'),
        isNull,
      );
    });

    test('a stray value reads as on, never as a toggle', () async {
      // A keychain value written by a *newer* build must not be able to switch
      // chrome off on an older one by accident — the default has to be the
      // safe-looking answer, so only the exact 'false' counts.
      const storage = FlutterSecureStorage();
      await storage.write(key: 'app_show_player_clock', value: 'false');
      await storage.write(key: 'app_show_playback_times', value: 'no');

      expect(await store.showPlayerClock(), isFalse);
      expect(await store.showPlaybackTimes(), isTrue);
    });

    test('the two keys are independent', () async {
      await store.setShowPlayerClock(false);

      expect(await store.showPlayerClock(), isFalse);
      expect(await store.showPlaybackTimes(), isTrue);
    });
  });

  group('the notifier every surface reads', () {
    test('loads both stored values', () async {
      await store.setShowPlayerClock(false);
      await store.setShowPlaybackTimes(false);

      await loadPlayerChromePrefs(store: store);

      expect(showPlayerClock.value, isFalse);
      expect(showPlaybackTimes.value, isFalse);
    });

    test('an untouched install loads on', () async {
      await loadPlayerChromePrefs(store: store);

      expect(showPlayerClock.value, isTrue);
      expect(showPlaybackTimes.value, isTrue);
    });

    test('survives a reboot', () async {
      await store.setShowPlayerClock(false);

      // The notifier is process state; the store is what the next run reads.
      showPlayerClock.value = true;
      await loadPlayerChromePrefs(store: store);

      expect(showPlayerClock.value, isFalse);
      expect(showPlaybackTimes.value, isTrue);
    });
  });

  group("the Linux OSD's iptvs-state contract", () {
    Map<String, Object?> overlayState() {
      final command = LinuxNativeSession.buildOverlayStateCommand(
        title: 'BBC One',
        sourceName: null,
        epgNow: null,
        epgNext: null,
        canFavorite: true,
        favorite: false,
        isLive: false,
        liveSynced: true,
        aspectLabel: 'Fit',
      );
      // ['script-message-to', <target>, <name>, <json>]
      expect(command.take(3), ['script-message-to', 'iptvs_overlay', 'iptvs-state']);
      return jsonDecode(command[3]! as String) as Map<String, Object?>;
    }

    test('carries both preferences under the names the Lua reads', () {
      final state = overlayState();

      expect(state['showClock'], showPlayerClock.value);
      expect(state['showPlaybackTimes'], showPlaybackTimes.value);
    });

    test('reads the live notifier, so a later push follows a toggle', () {
      showPlayerClock.value = false;
      showPlaybackTimes.value = false;

      final state = overlayState();

      expect(state['showClock'], isFalse);
      expect(state['showPlaybackTimes'], isFalse);
    });
  });
}
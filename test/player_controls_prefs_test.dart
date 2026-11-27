import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/player/player_controls_prefs.dart';

/// The player-controls preference is one set behind three layers — the
/// keychain, the notifier the overlays read, and the `hidden_controls` string
/// the Android Activity parses. The only way it breaks is those disagreeing, so
/// these drive the real store over the mocked keychain the rest of the suite
/// uses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = AppSettingsStore();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    playerControlsPrefs.value = const PlayerControlsPrefs();
  });

  group('the default', () {
    test('shows every control and writes nothing', () async {
      expect(playerControlsPrefs.value.hidden, isEmpty);
      for (final control in PlayerControl.values) {
        expect(playerControlsPrefs.value.shows(control), isTrue);
      }
      expect(playerControlsPrefs.value.wireValue, isEmpty);
      expect(await store.rawHiddenPlayerControls(), isNull);
    });

    test('an absent or empty stored value decodes to "show everything"', () {
      expect(PlayerControlsPrefs.decode(null).hidden, isEmpty);
      expect(PlayerControlsPrefs.decode('').hidden, isEmpty);
      expect(PlayerControlsPrefs.decode('  ').hidden, isEmpty);
    });
  });

  group('encoding', () {
    test('round-trips every control, in a stable order', () {
      final all = PlayerControlsPrefs(hidden: PlayerControl.values.toSet());
      final decoded = PlayerControlsPrefs.decode(all.wireValue);
      expect(decoded, all);
      // Sorted, so the same set always produces the same wire string — the
      // Android side is parsed, and a test comparing values must not depend on
      // set iteration order.
      final names = all.wireValue.split(',');
      expect(names, [...names]..sort());
    });

    test('an unknown name is dropped, not fatal', () {
      // A newer build may hide a control this one does not know; refusing the
      // whole value would resurrect every control the user did turn off.
      final decoded = PlayerControlsPrefs.decode('volume,future_thing,info');
      expect(decoded.hidden, {PlayerControl.volume, PlayerControl.info});
    });

    test('every wire name is unique', () {
      final names = PlayerControl.values.map((c) => c.storageName).toSet();
      expect(names.length, PlayerControl.values.length);
    });
  });

  group('toggling', () {
    test('hiding one leaves the rest alone', () {
      final prefs = const PlayerControlsPrefs()
          .withVisible(PlayerControl.volume, false)
          .withVisible(PlayerControl.info, false);
      expect(prefs.hidden, {PlayerControl.volume, PlayerControl.info});
      expect(prefs.shows(PlayerControl.volume), isFalse);
      expect(prefs.shows(PlayerControl.aspect), isTrue);
    });

    test('showing it again restores the default state', () {
      final prefs = const PlayerControlsPrefs()
          .withVisible(PlayerControl.mute, false)
          .withVisible(PlayerControl.mute, true);
      expect(prefs.hidden, isEmpty);
    });
  });

  group('what the device offers', () {
    test('a television has no picture-in-picture row', () {
      final tv = playerControlsForDevice(
        television: true,
        pictureInPicture: true,
      );
      expect(tv, isNot(contains(PlayerControl.pip)));
      // Everything else still applies: the TV player draws the same chrome.
      expect(tv, contains(PlayerControl.quickList));
      expect(tv.length, PlayerControl.values.length - 1);
      // And the hidden set is untouched by the filtering, so a phone choice
      // of "PiP off" is still there if the same account returns to a phone.
      expect(
        const PlayerControlsPrefs(
          hidden: {PlayerControl.pip},
        ).shows(PlayerControl.volume),
        isTrue,
      );
    });

    test('only the surfaces that draw PiP offer the row', () {
      // Windows' mini-player and Android's PiP window.
      expect(
        playerControlsForDevice(television: false, pictureInPicture: true),
        PlayerControl.values,
      );
      // Linux, iOS — no mini-player, so the toggle would be dead.
      final noPip = playerControlsForDevice(
        television: false,
        pictureInPicture: false,
      );
      expect(noPip, isNot(contains(PlayerControl.pip)));
      expect(noPip.length, PlayerControl.values.length - 1);
    });
  });

  group('storage', () {
    test('set publishes first and persists the hidden set', () async {
      await setPlayerControlVisible(PlayerControl.volume, false, store: store);
      expect(playerControlsPrefs.value.shows(PlayerControl.volume), isFalse);
      expect(await store.rawHiddenPlayerControls(), 'volume');

      await setPlayerControlVisible(PlayerControl.aspect, false, store: store);
      expect(await store.rawHiddenPlayerControls(), 'aspect,volume');
    });

    test('turning the last one back on clears the key', () async {
      await setPlayerControlVisible(PlayerControl.info, false, store: store);
      expect(await store.rawHiddenPlayerControls(), 'info');
      await setPlayerControlVisible(PlayerControl.info, true, store: store);
      expect(await store.rawHiddenPlayerControls(), isNull);
      expect(playerControlsPrefs.value.hidden, isEmpty);
    });

    test('loads the stored value', () async {
      FlutterSecureStorage.setMockInitialValues({
        'app_hidden_player_controls': 'mute,volume',
      });
      await loadPlayerControlsPrefs(store: store);
      expect(playerControlsPrefs.value.hidden, {
        PlayerControl.mute,
        PlayerControl.volume,
      });
    });
  });
}

// The aspect mode is device-wide; a channel may carry its own pin. These pin
// the storage contract the player and the channel list both rely on.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/sources/source_config.dart';

SourceConfig configWith(Map<String, dynamic> settings) => SourceConfig(
  id: 'src1',
  kind: SourceKind.m3u,
  label: 'One',
  fields: const {'playlistUrl': 'http://example.test/list.m3u'},
  settings: settings,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('the global aspect is one device-wide value', () async {
    const store = AppSettingsStore();
    expect(await store.playerAspectMode(), isNull);

    await store.setPlayerAspectMode('Fill');
    expect(await store.playerAspectMode(), 'Fill');

    // A second write replaces it: the mode is not per source.
    await store.setPlayerAspectMode('Stretch');
    expect(await store.playerAspectMode(), 'Stretch');

    // Clearing removes the key, so an untouched install reads as "never
    // chosen" and keeps the platform default.
    await store.setPlayerAspectMode(null);
    expect(await store.playerAspectMode(), isNull);
  });

  test('a pin is per item and reads back from settings', () {
    final pinned = configWith(
      configWith(const {}).settingsWithAspectPin('ch-1', 'Stretch'),
    );
    expect(pinned.aspectPinFor('ch-1'), 'Stretch');
    expect(pinned.aspectPinFor('ch-2'), isNull);
    expect(pinned.aspectPins, {'ch-1': 'Stretch'});
  });

  test('removing one pin keeps the others', () {
    var config = configWith(const {});
    config = configWith(config.settingsWithAspectPin('ch-1', 'Stretch'));
    config = configWith(config.settingsWithAspectPin('ch-2', '16:9'));

    config = configWith(config.settingsWithAspectPin('ch-1', null));

    expect(config.aspectPinFor('ch-1'), isNull);
    expect(config.aspectPinFor('ch-2'), '16:9');
  });

  test('removing the last pin drops the key entirely', () {
    var config = configWith(const {'bufferPreset': 'high'});
    config = configWith(config.settingsWithAspectPin('ch-1', 'Stretch'));
    config = configWith(config.settingsWithAspectPin('ch-1', null));

    // A source that never pinned anything keeps a byte-identical settings
    // blob, exactly like the dwell/preset keys.
    expect(config.settings, {'bufferPreset': 'high'});
    expect(config.settings.containsKey('aspectPins'), isFalse);
  });

  test('a malformed stored map reads as no pins', () {
    final config = configWith(const {'aspectPins': 'not a map'});
    expect(config.aspectPins, isEmpty);
    expect(config.aspectPinFor('ch-1'), isNull);
  });
}

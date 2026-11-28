import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/data/device_identity.dart';
import 'package:iptvs/data/settings_auto_sync.dart';

/// The per-device settings backup: which keychain entries travel to the cloud,
/// how applying a cloud map restores defaults, and the reinstall rule.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('device key', () {
    test('is a namespaced SHA-256 of the raw platform id', () {
      final expected = sha256
          .convert(utf8.encode('iptvs-device-v1|android:abc123'))
          .toString();
      expect(DeviceIdentity.hashRaw('android:abc123'), expected);
      expect(expected, hasLength(64));
      expect(DeviceIdentity.hashRaw('android:abc123'), isNot(
        DeviceIdentity.hashRaw('windows:abc123'),
      ));
    });
  });

  group('settings map', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({
      'app_seek_step_seconds': '20',
      'profile_picker_startup': 'off',
      'cloud_server_url': 'https://cloud.example.com',
      'cloud_server_key': 'sb_publishable_abc',
      'local_profiles_v1': '[]',
      'active_local_profile_id': 'abc',
      'app_settings_cloud_synced_at': '2026-11-28T00:00:00.000Z',
    }));

    test('only preferences are exported, not the connection or profile data', () async {
      final map = await const AppSettingsStore().settingsForCloud();
      expect(map['app_seek_step_seconds'], '20');
      expect(map['profile_picker_startup'], 'off');
      expect(map.keys, isNot(contains('cloud_server_url')));
      expect(map.keys, isNot(contains('cloud_server_key')));
      expect(map.keys, isNot(contains('local_profiles_v1')));
      expect(map.keys, isNot(contains('active_local_profile_id')));
      expect(map.keys, isNot(contains('app_settings_cloud_synced_at')));
    });

    test('applying a cloud map replaces the synced set and keeps the rest', () async {
      const store = AppSettingsStore();
      await store.applyCloudSettings({
        'app_movie_quick_play': 'true',
        'profile_picker_startup': 'on',
        'cloud_server_url': 'ignored',
        'not_a_setting': 'ignored',
      });

      final all = await const FlutterSecureStorage().readAll();
      expect(all['app_movie_quick_play'], 'true');
      expect(all['profile_picker_startup'], 'on');
      // Present locally but absent from the cloud map: back to the default.
      expect(all.containsKey('app_seek_step_seconds'), isFalse);
      // Connection and foreign keys are untouched.
      expect(all['cloud_server_url'], 'https://cloud.example.com');
      expect(all.containsKey('not_a_setting'), isFalse);
    });

    test('the sync marker round-trips as UTC', () async {
      const store = AppSettingsStore();
      final marker = DateTime.utc(2026, 11, 28, 12, 34, 56);
      await store.setCloudSettingsSyncedAt(marker);
      expect(await store.cloudSettingsSyncedAt(), marker);
    });
  });

  group('reinstall rule', () {
    final cloud = DateTime.utc(2026, 11, 28, 12);
    final local = DateTime.utc(2026, 11, 28, 11);

    test('a fresh keychain takes the cloud copy', () {
      expect(
        shouldApplyCloudSettings(localSyncedAt: null, cloudUpdatedAt: cloud),
        isTrue,
      );
    });

    test('an existing device only takes a newer cloud copy', () {
      expect(
        shouldApplyCloudSettings(
          localSyncedAt: local,
          cloudUpdatedAt: cloud,
        ),
        isTrue,
      );
      expect(
        shouldApplyCloudSettings(
          localSyncedAt: cloud,
          cloudUpdatedAt: local,
        ),
        isFalse,
      );
      expect(
        shouldApplyCloudSettings(
          localSyncedAt: local,
          cloudUpdatedAt: null,
        ),
        isFalse,
      );
    });
  });
}

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/data/cloud_endpoint.dart';

/// The keychain contract behind option D: the endpoint is written once at
/// setup, read at every boot, and a half-written record reads as "no server"
/// rather than putting an unusable client on the boot path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('a server round-trips through the store', () async {
    const store = AppSettingsStore();
    expect(await store.cloudEndpoint(), isNull);

    final endpoint = CloudEndpoint.parse(
      url: 'https://cloud.example.com/',
      anonKey: 'sb_publishable_abc',
    )!;
    await store.setCloudEndpoint(endpoint);

    final read = await store.cloudEndpoint();
    expect(read, isNotNull);
    expect(read!.url, 'https://cloud.example.com');
    expect(read.anonKey, 'sb_publishable_abc');
    expect(read.panelUrl, 'https://cloud.example.com/');

    await store.clearCloudEndpoint();
    expect(await store.cloudEndpoint(), isNull);
  });

  test('an incomplete or invalid record reads as not configured', () async {
    FlutterSecureStorage.setMockInitialValues({
      'cloud_server_url': 'https://cloud.example.com',
    });
    expect(await const AppSettingsStore().cloudEndpoint(), isNull);

    FlutterSecureStorage.setMockInitialValues({
      'cloud_server_url': 'http://cloud.example.com',
      'cloud_server_key': 'sb_publishable_abc',
    });
    expect(await const AppSettingsStore().cloudEndpoint(), isNull);
  });

  test('a broken panel value falls back to the server address', () async {
    FlutterSecureStorage.setMockInitialValues({
      'cloud_server_url': 'https://cloud.example.com',
      'cloud_server_key': 'sb_publishable_abc',
      'cloud_server_panel': 'not a url',
    });
    final read = await const AppSettingsStore().cloudEndpoint();
    expect(read, isNotNull);
    expect(read!.panelUrl, 'https://cloud.example.com/');
  });
}

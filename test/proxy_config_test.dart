import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/data/proxy_config.dart';
import 'package:iptvs/data/stream_kind.dart';

/// The proxy choice is three layers again — the keychain, the live notifier the
/// Settings screen and the artwork fetcher read, and the platform lookup behind
/// "System" — so these drive the real store over the mocked keychain.
///
/// The bypass list gets its own group because it is the one part that failed in
/// the field: the phone's Wi-Fi proxy excludes `*.site` and one literal IP, and
/// ignoring that list forced the panel's own hosts through the proxy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = AppSettingsStore();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    proxyConfig.value = const ProxyConfig();
    effectiveProxy.value = null;
    debugResetDirectFailures();
  });

  group('the mode', () {
    test('defaults to system and is never written', () {
      expect(ProxyMode.system.storageValue, isNull);
      expect(ProxyMode.custom.storageValue, 'custom');
      expect(ProxyMode.off.storageValue, 'off');
    });

    test('an unknown or absent value reads as system', () {
      expect(ProxyMode.parse(null), ProxyMode.system);
      expect(ProxyMode.parse(''), ProxyMode.system);
      expect(ProxyMode.parse('socks5'), ProxyMode.system);
    });

    test('cycles system -> custom -> off -> system', () {
      expect(ProxyMode.system.next, ProxyMode.custom);
      expect(ProxyMode.custom.next, ProxyMode.off);
      expect(ProxyMode.off.next, ProxyMode.system);
    });

    test('the labels are what the tile prints', () {
      expect(ProxyMode.system.label, 'System');
      expect(ProxyMode.custom.label, 'Custom');
      expect(ProxyMode.off.label, 'Off');
    });
  });

  group('storage', () {
    test('an untouched install stores nothing', () async {
      expect(await store.rawProxyConfig(), isNull);
    });

    test('round-trips mode, host and port', () async {
      await setProxyConfig(
        const ProxyConfig(
          mode: ProxyMode.custom,
          host: '192.168.1.4',
          port: 8888,
        ),
        store: store,
      );
      expect(await store.rawProxyConfig(), {
        'mode': 'custom',
        'host': '192.168.1.4',
        'port': '8888',
      });
      expect(proxyConfig.value.mode, ProxyMode.custom);
      expect(proxyConfig.value.host, '192.168.1.4');
      expect(proxyConfig.value.port, 8888);
    });

    test('switching back to system clears the address', () async {
      await setProxyConfig(
        const ProxyConfig(mode: ProxyMode.custom, host: '10.0.0.2', port: 3128),
        store: store,
      );
      await setProxyConfig(
        const ProxyConfig(mode: ProxyMode.system),
        store: store,
      );
      expect(await store.rawProxyConfig(), isNull);
      expect(effectiveProxy.value, isNull);
    });

    test('a corrupt record reads as absent rather than throwing', () async {
      FlutterSecureStorage.setMockInitialValues({
        'app_http_proxy': 'custom;192.168.1.4',
      });
      expect(await store.rawProxyConfig(), isNull);
    });
  });

  group('bypass list', () {
    test('a wildcard suffix covers the domain and its subdomains', () {
      expect(ProxyEndpoint.isExcluded('site', ['*.site']), isTrue);
      expect(ProxyEndpoint.isExcluded('panel.site', ['*.site']), isTrue);
      expect(ProxyEndpoint.isExcluded('a.b.site', ['*.site']), isTrue);
      expect(ProxyEndpoint.isExcluded('notsite', ['*.site']), isFalse);
      expect(ProxyEndpoint.isExcluded('site.evil', ['*.site']), isFalse);
    });

    test('a literal host or IP matches exactly', () {
      expect(ProxyEndpoint.isExcluded('37.1.194.25', ['37.1.194.25']), isTrue);
      expect(ProxyEndpoint.isExcluded('37.1.194.26', ['37.1.194.25']), isFalse);
    });

    test('<local> covers dotless LAN hostnames', () {
      expect(ProxyEndpoint.isExcluded('nas', ['<local>']), isTrue);
      expect(ProxyEndpoint.isExcluded('nas.lan', ['<local>']), isFalse);
    });

    test('a bare star bypasses everything, an empty entry nothing', () {
      expect(ProxyEndpoint.isExcluded('example.com', ['*']), isTrue);
      expect(ProxyEndpoint.isExcluded('example.com', ['', '  ']), isFalse);
    });

    test('an interior wildcard still matches', () {
      expect(
        ProxyEndpoint.isExcluded('cdn1.test.dev', ['cdn*.test.dev']),
        isTrue,
      );
      expect(
        ProxyEndpoint.isExcluded('cdnx.other.dev', ['cdn*.test.dev']),
        isFalse,
      );
    });

    test('an excluded host is asked for DIRECT', () {
      const endpoint = ProxyEndpoint(
        host: '192.168.1.4',
        port: 8888,
        exclusions: ['*.site'],
      );
      expect(
        endpoint.findProxyFor(Uri.parse('https://panel.site/api')),
        'DIRECT',
      );
      expect(
        endpoint.findProxyFor(Uri.parse('https://thumbs.example.com/a.jpg')),
        'PROXY 192.168.1.4:8888',
      );
    });

    test('a SOCKS endpoint keeps its type', () {
      const endpoint = ProxyEndpoint(
        host: '127.0.0.1',
        port: 1080,
        type: 'SOCKS',
      );
      expect(
        endpoint.findProxyFor(Uri.parse('https://example.com/')),
        'SOCKS 127.0.0.1:1080',
      );
    });

    test('a LAN name is never sent to the proxy', () {
      // The report: the panel is at http://transmission/... (a dotless LAN
      // name), and the proxy closed the connection — "Connection closed before
      // full header was received" — while the same URL worked through curl,
      // which bypasses LAN names.
      const endpoint = ProxyEndpoint(host: 'proxy', port: 8888);
      expect(
        endpoint.findProxyFor(Uri.parse('http://transmission/player_api.php')),
        'DIRECT',
      );
      expect(
        endpoint.findProxyFor(Uri.parse('http://192.168.1.10/api')),
        'DIRECT',
      );
      expect(
        endpoint.findProxyFor(Uri.parse('https://thumbs.example.com/a.jpg')),
        'PROXY proxy:8888',
      );
    });

    test('private and local addresses are recognised', () {
      for (final host in const [
        'localhost',
        'nas',
        'proxy',
        'box.local',
        '10.0.0.5',
        '172.16.4.4',
        '172.31.255.254',
        '192.168.0.1',
        '127.0.0.1',
        '169.254.1.2',
        '::1',
        'fe80::1',
        'fd00::5',
      ]) {
        expect(ProxyEndpoint.isLocalHost(host), isTrue, reason: host);
      }
      for (final host in const [
        'example.com',
        'thumbs.mega-porno.love',
        '172.32.0.1',
        '8.8.8.8',
        '',
      ]) {
        expect(ProxyEndpoint.isLocalHost(host), isFalse, reason: host);
      }
    });
  });

  group('direct-first gate', () {
    test('needs a proxy, a non-local host and no recent failure', () {
      expect(shouldTryDirectFirst('cdn.example.com'), isFalse);
      effectiveProxy.value = const ProxyEndpoint(
        host: 'proxy',
        port: 8888,
        exclusions: ['*.site'],
      );
      expect(shouldTryDirectFirst('cdn.example.com'), isTrue);
      // Platform bypass and the LAN rule answer DIRECT on their own, so a
      // direct-first attempt is not even made for them.
      expect(shouldTryDirectFirst('panel.site'), isFalse);
      expect(shouldTryDirectFirst('transmission'), isFalse);

      noteDirectFailure('cdn.example.com');
      expect(shouldTryDirectFirst('cdn.example.com'), isFalse);
      // The memory expires, so a network change can unblock the host again.
      directFailureWindow = Duration.zero;
      expect(shouldTryDirectFirst('cdn.example.com'), isTrue);
    });
  });

  group('streams through the proxy', () {
    test('defaults off, so an untouched install stays direct', () async {
      for (final kind in StreamKind.values) {
        expect(await store.streamProxy(kind), isFalse, reason: kind.name);
        expect(
          await streamProxyEndpointFor(kind, store: store),
          isNull,
          reason: kind.name,
        );
      }
    });

    test('the switch is per kind and survives a restart', () async {
      await store.setStreamProxy(StreamKind.movie, true);
      expect(await store.streamProxy(StreamKind.movie), isTrue);
      // The other two kinds are untouched: a film user is not a channel user.
      expect(await store.streamProxy(StreamKind.live), isFalse);
      expect(await store.streamProxy(StreamKind.series), isFalse);
      await store.setStreamProxy(StreamKind.movie, false);
      expect(await store.streamProxy(StreamKind.movie), isFalse);
    });

    test('a switch with no proxy in effect is still direct', () async {
      await store.setStreamProxy(StreamKind.live, true);
      // Mode Off: the switch cannot conjure a route the user turned off.
      proxyConfig.value = const ProxyConfig(
        mode: ProxyMode.off,
        host: '192.168.1.4',
        port: 8888,
      );
      effectiveProxy.value = null;
      expect(
        await streamProxyEndpointFor(StreamKind.live, store: store),
        isNull,
      );
    });

    test('a switched-on kind gets the proxy the app already uses', () async {
      await store.setStreamProxy(StreamKind.series, true);
      proxyConfig.value = const ProxyConfig(
        mode: ProxyMode.custom,
        host: '192.168.1.4',
        port: 8888,
      );
      effectiveProxy.value = null;
      expect(
        await streamProxyEndpointFor(StreamKind.series, store: store),
        const ProxyEndpoint(host: '192.168.1.4', port: 8888),
      );
      // And the live switch, still off, stays direct on the same config.
      expect(
        await streamProxyEndpointFor(StreamKind.live, store: store),
        isNull,
      );
    });

    test('the resolved endpoint wins over re-resolving the config', () async {
      // The system proxy is what the app's own client is using, so a stream
      // must not resolve differently from the API call that led to it.
      await store.setStreamProxy(StreamKind.live, true);
      proxyConfig.value = const ProxyConfig(mode: ProxyMode.system);
      effectiveProxy.value = const ProxyEndpoint(
        host: '192.168.1.4',
        port: 8888,
      );
      expect(
        await streamProxyEndpointFor(StreamKind.live, store: store),
        effectiveProxy.value,
      );
    });

    test('mpv gets a scheme-carrying value for both proxy types', () {
      expect(
        mpvProxyOptionValue(
          const ProxyEndpoint(host: '192.168.1.4', port: 8888),
        ),
        'http://192.168.1.4:8888',
      );
      expect(
        mpvProxyOptionValue(
          const ProxyEndpoint(host: '127.0.0.1', port: 1080, type: 'SOCKS'),
        ),
        'socks5://127.0.0.1:1080',
      );
    });
  });

  group('resolving the choice', () {
    test('off is direct, whatever the address says', () async {
      final endpoint = await resolveProxyEndpoint(
        const ProxyConfig(mode: ProxyMode.off, host: '192.168.1.4', port: 8888),
      );
      expect(endpoint, isNull);
    });

    test('a complete custom address is used as written', () async {
      final endpoint = await resolveProxyEndpoint(
        const ProxyConfig(
          mode: ProxyMode.custom,
          host: ' 192.168.1.4 ',
          port: 8888,
        ),
      );
      expect(endpoint, const ProxyEndpoint(host: '192.168.1.4', port: 8888));
    });

    test('a half-filled custom address falls back to direct', () async {
      expect(
        await resolveProxyEndpoint(
          const ProxyConfig(mode: ProxyMode.custom, host: '', port: 8888),
        ),
        isNull,
      );
      expect(
        await resolveProxyEndpoint(
          const ProxyConfig(mode: ProxyMode.custom, host: '192.168.1.4'),
        ),
        isNull,
      );
      expect(
        await resolveProxyEndpoint(
          const ProxyConfig(mode: ProxyMode.custom, host: 'h', port: 70000),
        ),
        isNull,
      );
    });
  });
}

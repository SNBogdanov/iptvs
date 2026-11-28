import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_endpoint.dart';

String _jwt(Map<String, Object?> payload) {
  String encode(Map<String, Object?> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode(payload)}.not-a-real-signature';
}

void main() {
  group('server URL', () {
    test('a bare host becomes an https URL', () {
      expect(normalizeCloudUrl('cloud.example.com'), 'https://cloud.example.com');
      expect(
        normalizeCloudUrl('  Cloud.Example.COM/  '),
        'https://cloud.example.com',
      );
    });

    test('a trailing slash, query and fragment are removed', () {
      expect(
        normalizeCloudUrl('https://cloud.example.com///'),
        'https://cloud.example.com',
      );
      expect(normalizeCloudUrl('https://cloud.example.com?x=1'), isNull);
      expect(normalizeCloudUrl('https://cloud.example.com/#y'), isNull);
    });

    test('a base path and a port are kept', () {
      expect(
        normalizeCloudUrl('https://example.com:8443/supabase/'),
        'https://example.com:8443/supabase',
      );
    });

    test('plain http is refused for the API except on loopback', () {
      expect(normalizeCloudUrl('http://cloud.example.com'), isNull);
      expect(normalizeCloudUrl('http://localhost:54321'), 'http://localhost:54321');
      expect(normalizeCloudUrl('http://127.0.0.1:8000'), 'http://127.0.0.1:8000');
    });

    test('the panel and the discovery address may be plain http on a LAN', () {
      // `transmission` is a single-label LAN name: valid for a panel link, not
      // for the API (credentials/hashes must not cross plain http).
      expect(
        normalizeCloudPanelUrl('http://transmission/iptvs'),
        'http://transmission/iptvs/',
      );
      expect(
        normalizeCloudDiscoveryUrl('http://transmission/iptvs'),
        'http://transmission/iptvs',
      );
      expect(normalizeCloudUrl('http://transmission'), isNull);
    });

    test('credentials and unparsable values are refused', () {
      expect(normalizeCloudUrl('https://user:pass@example.com'), isNull);
      expect(normalizeCloudUrl('ftp://example.com'), isNull);
      expect(normalizeCloudUrl(''), isNull);
      expect(normalizeCloudUrl('   '), isNull);
    });

    test('the panel URL always ends in a slash', () {
      expect(
        normalizeCloudPanelUrl('https://cloud.example.com'),
        'https://cloud.example.com/',
      );
      expect(
        normalizeCloudPanelUrl('https://cloud.example.com/panel'),
        'https://cloud.example.com/panel/',
      );
    });
  });

  group('publishable key', () {
    test('the modern publishable form is accepted', () {
      expect(
        normalizeCloudAnonKey(' sb_publishable_abc123 '),
        'sb_publishable_abc123',
      );
    });

    test('a legacy anon JWT is accepted', () {
      final key = _jwt({'role': 'anon', 'iss': 'supabase'});
      expect(normalizeCloudAnonKey(key), key);
    });

    test('a service_role JWT is refused', () {
      expect(normalizeCloudAnonKey(_jwt({'role': 'service_role'})), isNull);
    });

    test('other JWT roles are refused', () {
      expect(normalizeCloudAnonKey(_jwt({'role': 'authenticated'})), isNull);
    });

    test('empty, whitespace and oversized values are refused', () {
      expect(normalizeCloudAnonKey(''), isNull);
      expect(normalizeCloudAnonKey('two words'), isNull);
      expect(normalizeCloudAnonKey('x' * 5000), isNull);
    });
  });

  group('endpoint', () {
    test('the panel defaults to the server address', () {
      final endpoint = CloudEndpoint.parse(
        url: 'https://cloud.example.com/',
        anonKey: 'sb_publishable_abc',
      );
      expect(endpoint, isNotNull);
      expect(endpoint!.url, 'https://cloud.example.com');
      expect(endpoint.panelUrl, 'https://cloud.example.com/');
      expect(endpoint.host, 'cloud.example.com');
    });

    test('an explicit panel is kept, including plain http on a LAN', () {
      final endpoint = CloudEndpoint.parse(
        url: 'https://api.example.com',
        anonKey: 'sb_publishable_abc',
        panelUrl: 'https://panel.example.com',
      );
      expect(endpoint!.panelUrl, 'https://panel.example.com/');

      final lan = CloudEndpoint.parse(
        url: 'https://api.example.com',
        anonKey: 'sb_publishable_abc',
        panelUrl: 'http://transmission/iptvs',
      );
      expect(lan!.panelUrl, 'http://transmission/iptvs/');
    });

    test('a broken key or URL produces no endpoint', () {
      expect(
        CloudEndpoint.parse(
          url: 'https://cloud.example.com',
          anonKey: '',
        ),
        isNull,
      );
      expect(
        CloudEndpoint.parse(
          url: 'not a url',
          anonKey: 'sb_publishable_abc',
        ),
        isNull,
      );
    });

    test('same server means the same URL, not the same key', () {
      final first = CloudEndpoint.parse(
        url: 'https://cloud.example.com',
        anonKey: 'sb_publishable_one',
      )!;
      final rotated = CloudEndpoint.parse(
        url: 'https://cloud.example.com/',
        anonKey: 'sb_publishable_two',
      )!;
      final other = CloudEndpoint.parse(
        url: 'https://other.example.com',
        anonKey: 'sb_publishable_one',
      )!;
      expect(first.sameServerAs(rotated), isTrue);
      expect(first.sameServerAs(other), isFalse);
    });
  });

  group('well-known configuration', () {
    const base = 'https://cloud.example.com';

    test('a complete document is read', () {
      final endpoint = parseCloudWellKnown(
        jsonEncode({
          'version': 1,
          'url': 'https://api.example.com',
          'anonKey': 'sb_publishable_abc',
          'panelUrl': 'https://panel.example.com',
        }),
        baseUrl: base,
      );
      expect(endpoint, isNotNull);
      expect(endpoint!.url, 'https://api.example.com');
      expect(endpoint.panelUrl, 'https://panel.example.com/');
    });

    test('a missing url falls back to the address the user typed', () {
      final endpoint = parseCloudWellKnown(
        jsonEncode({'anonKey': 'sb_publishable_abc'}),
        baseUrl: base,
      );
      expect(endpoint!.url, base);
      expect(endpoint.panelUrl, '$base/');
    });

    test('the panel stays on the address that served the file', () {
      // The panel host and the API are different origins: the QR and the
      // "open panel" link must point back at the host the user typed.
      final endpoint = parseCloudWellKnown(
        jsonEncode({
          'url': 'https://api.example.com',
          'anonKey': 'sb_publishable_abc',
        }),
        baseUrl: base,
      );
      expect(endpoint!.url, 'https://api.example.com');
      expect(endpoint.panelUrl, '$base/');
    });

    test('a LAN panel may serve the file over http for an https API', () {
      final endpoint = parseCloudWellKnown(
        jsonEncode({
          'url': 'https://api.example.com',
          'anonKey': 'sb_publishable_abc',
        }),
        baseUrl: 'http://transmission/iptvs',
      );
      expect(endpoint!.url, 'https://api.example.com');
      expect(endpoint.panelUrl, 'http://transmission/iptvs/');
    });

    test('an http API url in the file is refused', () {
      final endpoint = parseCloudWellKnown(
        jsonEncode({
          'url': 'http://api.example.com',
          'anonKey': 'sb_publishable_abc',
        }),
        baseUrl: 'http://transmission/iptvs',
      );
      expect(endpoint, isNull);
    });

    test('a missing key, an unknown version and garbage are refused', () {
      expect(
        parseCloudWellKnown(jsonEncode({'url': base}), baseUrl: base),
        isNull,
      );
      expect(
        parseCloudWellKnown(
          jsonEncode({'version': 2, 'anonKey': 'sb_publishable_abc'}),
          baseUrl: base,
        ),
        isNull,
      );
      expect(parseCloudWellKnown('not json', baseUrl: base), isNull);
      expect(parseCloudWellKnown('[]', baseUrl: base), isNull);
      expect(parseCloudWellKnown('', baseUrl: base), isNull);
    });

    test('a service_role key is refused here too', () {
      final endpoint = parseCloudWellKnown(
        jsonEncode({'anonKey': _jwt({'role': 'service_role'})}),
        baseUrl: base,
      );
      expect(endpoint, isNull);
    });

    test('an oversized document is refused', () {
      final endpoint = parseCloudWellKnown(
        'x' * (64 * 1024 + 1),
        baseUrl: base,
      );
      expect(endpoint, isNull);
    });
  });

  group('boot resolution', () {
    final stored = CloudEndpoint.parse(
      url: 'https://stored.example.com',
      anonKey: 'sb_publishable_stored',
    )!;
    final buildDefault = CloudEndpoint.parse(
      url: 'https://build.example.com',
      anonKey: 'sb_publishable_build',
    )!;

    test('a stored choice wins over the build default', () {
      final resolution = resolveCloudEndpoint(
        stored: stored,
        buildDefault: buildDefault,
      );
      expect(resolution.endpoint, stored);
      expect(resolution.fromBuild, isFalse);
    });

    test('the build default is used and marked for migration', () {
      final resolution = resolveCloudEndpoint(
        stored: null,
        buildDefault: buildDefault,
      );
      expect(resolution.endpoint, buildDefault);
      expect(resolution.fromBuild, isTrue);
    });

    test('nothing configured stays unconfigured', () {
      final resolution = resolveCloudEndpoint(
        stored: null,
        buildDefault: null,
      );
      expect(resolution.endpoint, isNull);
      expect(resolution.configured, isFalse);
    });
  });
}

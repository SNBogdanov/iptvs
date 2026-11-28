import 'dart:convert';

/// The cloud server this device talks to: a Supabase URL, its publishable
/// (anon) key, and the web panel's base URL.
///
/// Pure Dart on purpose. Everything here is arithmetic over strings, so the
/// validation rules — scheme, normalization, the `service_role` refusal and the
/// well-known file's shape — are pinned by ordinary unit tests instead of by
/// trying a TV remote. Runtime state lives in `cloud_runtime.dart`; persistence
/// lives in `AppSettingsStore`.
class CloudEndpoint {
  const CloudEndpoint({
    required this.url,
    required this.anonKey,
    required this.panelUrl,
  });

  /// Normalized `https://host[:port][/path]` — no trailing slash, no query.
  final String url;

  /// Publishable, legacy anon, or any key that is not a `service_role` JWT.
  final String anonKey;

  /// Normalized panel base URL, always with a trailing slash (`…/`).
  final String panelUrl;

  /// Validates and normalizes a manually entered endpoint, or returns null.
  ///
  /// [panelUrl] defaults to the server URL itself, which is where a
  /// self-hosted stack serves the panel; a managed project that hosts the panel
  /// elsewhere passes it explicitly.
  static CloudEndpoint? parse({
    required String url,
    required String anonKey,
    String? panelUrl,
  }) {
    final normalizedUrl = normalizeCloudUrl(url);
    final key = normalizeCloudAnonKey(anonKey);
    if (normalizedUrl == null || key == null) return null;
    final String panel;
    if (panelUrl == null || panelUrl.trim().isEmpty) {
      panel = '$normalizedUrl/';
    } else {
      final normalized = normalizeCloudPanelUrl(panelUrl);
      if (normalized == null) return null;
      panel = normalized;
    }
    return CloudEndpoint(url: normalizedUrl, anonKey: key, panelUrl: panel);
  }

  /// Whether two endpoints address the same server. The key may be rotated on
  /// the same server without the device's data becoming meaningless, so a key
  /// or panel change must not count as a server switch.
  bool sameServerAs(CloudEndpoint other) =>
      url.toLowerCase() == other.url.toLowerCase();

  String get host => Uri.tryParse(url)?.host ?? url;

  @override
  String toString() => 'CloudEndpoint($url)';
}

/// Normalizes a **server** (Supabase API) URL. Accepts a bare host
/// (`cloud.example.com`) and assumes https, as every real deployment should.
///
/// Rejected: anything that is not `https` (except localhost/loopback, for
/// development), credentials in the URL, a query or fragment, and an empty
/// host. The path is kept (a deployment may live under `/supabase`), but a
/// trailing slash is removed so two spellings of one server compare equal.
String? normalizeCloudUrl(String raw) => _normalizeUrl(raw, allowPlainHttp: false);

/// Normalizes the panel base URL: same rules as [normalizeCloudUrl] but plain
/// `http` is allowed for **any** host — the panel is a link/QR target, not the
/// credential-bearing API, and a LAN deployment (e.g. `http://transmission`)
/// is a normal setup. The trailing slash is guaranteed so `Uri.resolve` and
/// the pairing QR build paths the same way everywhere.
String? normalizeCloudPanelUrl(String raw) {
  final base = _normalizeUrl(raw, allowPlainHttp: true);
  return base == null ? null : '$base/';
}

/// Normalizes an address the user types into the "check the server" field.
///
/// That address is the **host that serves the well-known file** (normally the
/// panel host), so both schemes are accepted; the API `url` the file returns
/// still has to pass [normalizeCloudUrl], which keeps the credentials on https.
String? normalizeCloudDiscoveryUrl(String raw) =>
    _normalizeUrl(raw, allowPlainHttp: true);

String? _normalizeUrl(String raw, {required bool allowPlainHttp}) {
  final text = _withScheme(raw);
  if (text == null) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  if (!_validHost(uri)) return null;
  if (uri.hasQuery || uri.hasFragment) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'https' &&
      !(scheme == 'http' && (allowPlainHttp || _isLoopback(uri.host)))) {
    return null;
  }
  var path = uri.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path == '/') path = '';
  return '$scheme://${_authority(uri)}$path';
}

/// Validates a publishable/anon key and returns it trimmed, or null.
///
/// A JWT-shaped key is decoded and its `role` checked: `service_role` is
/// refused outright, and so is any other JWT role (`authenticated` is not a
/// client key). A key that is not a JWT — the modern `sb_publishable_…` form —
/// is accepted as opaque.
String? normalizeCloudAnonKey(String raw) {
  final key = raw.trim();
  if (key.isEmpty || key.length > 4096) return null;
  if (key.contains(RegExp(r'\s'))) return null;
  final role = _jwtRole(key);
  if (role != null && role != 'anon') return null;
  return key;
}

/// The role inside a JWT-shaped key, or null when the string is not a JWT.
///
/// Deliberately tolerant: a publishable key is not a JWT, and a malformed token
/// must not throw on the settings screen. A token that *does* decode and names
/// a role is judged by that role.
String? jwtRole(String token) => _jwtRole(token);

String? _jwtRole(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final decoded = jsonDecode(payload);
    if (decoded is Map && decoded['role'] is String) {
      return (decoded['role'] as String).toLowerCase();
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// Which endpoint a boot should use.
class CloudEndpointResolution {
  const CloudEndpointResolution({
    required this.endpoint,
    required this.fromBuild,
  });

  final CloudEndpoint? endpoint;

  /// True when [endpoint] came from the build's compile-time default and must
  /// be copied into the keychain, so a later build without the defines keeps
  /// the server.
  final bool fromBuild;

  bool get configured => endpoint != null;
}

/// Resolution rule for the boot path: a stored choice always wins; the build
/// default is used only when nothing is stored.
CloudEndpointResolution resolveCloudEndpoint({
  required CloudEndpoint? stored,
  required CloudEndpoint? buildDefault,
}) {
  if (stored != null) {
    return CloudEndpointResolution(endpoint: stored, fromBuild: false);
  }
  if (buildDefault != null) {
    return CloudEndpointResolution(endpoint: buildDefault, fromBuild: true);
  }
  return const CloudEndpointResolution(endpoint: null, fromBuild: false);
}

/// Well-known location a server may publish endpoints at.
const String kCloudWellKnownPath = '/.well-known/iptvs-cloud.json';

/// Parses a server's well-known document, or null when it is not usable.
///
/// The contract is deliberately small and strict — this is a file fetched from
/// an address the user typed, so it must not be able to smuggle anything in:
/// at most 64 KiB, a JSON object, `version` 1 when present, a `url` (optional;
/// the entered address is the default), an `anonKey`, and an optional
/// `panelUrl`. Every field goes through the same normalization as manual entry,
/// so the `service_role` refusal applies here too.
CloudEndpoint? parseCloudWellKnown(String body, {required String baseUrl}) {
  if (body.isEmpty || body.length > 64 * 1024) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final version = decoded['version'];
  if (version != null && version != 1) return null;
  final rawUrl = decoded['url'];
  final url = rawUrl is String && rawUrl.trim().isNotEmpty ? rawUrl : baseUrl;
  final rawKey = decoded['anonKey'];
  if (rawKey is! String) return null;
  final rawPanel = decoded['panelUrl'];
  // The panel defaults to the address that served this document, not to the API
  // URL: a panel host commonly points at a Supabase project on another origin,
  // and the pairing QR/link must stay on the host the user typed.
  final panelUrl = rawPanel is String && rawPanel.trim().isNotEmpty
      ? rawPanel
      : baseUrl;
  return CloudEndpoint.parse(
    url: url,
    anonKey: rawKey,
    panelUrl: panelUrl,
  );
}

String? _withScheme(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  return text.contains('://') ? text : 'https://$text';
}

/// A host must look like a DNS name, an IPv4 address or an IPv6 literal.
///
/// `Uri` happily percent-encodes a space into `not%20a%20url`, which is a
/// "host" no client can connect to; refusing it here keeps that mistake on the
/// settings screen instead of at the first request.
bool _validHost(Uri uri) {
  final host = uri.host.toLowerCase();
  if (host.isEmpty || host.contains('%') || host.contains(' ')) return false;
  if (host.contains(':')) {
    // IPv6 literal; Uri has already validated the bracket syntax.
    return RegExp(r'^[0-9a-f:.]+$').hasMatch(host);
  }
  return RegExp(
    r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$',
  ).hasMatch(host);
}

bool _isLoopback(String host) {
  final value = host.toLowerCase();
  return value == 'localhost' || value == '127.0.0.1' || value == '::1';
}

/// `host[:port]`, with IPv6 hosts bracketed again (Uri.host strips them).
String _authority(Uri uri) {
  final host = uri.host.toLowerCase();
  final bracketed = host.contains(':') ? '[$host]' : host;
  return uri.hasPort ? '$bracketed:${uri.port}' : bracketed;
}

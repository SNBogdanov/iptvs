import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_settings_store.dart';
import 'diagnostics_log.dart';

/// How the app decides which HTTP proxy to use.
///
/// **System is the default, and it is the absent key too.** Every install that
/// predates this setting was already following the device's proxy (through the
/// Android bridge in [resolveProxyEndpoint]), so reading an unset value as
/// anything else would silently change how those installs reach the network.
enum ProxyMode {
  system,
  custom,
  off;

  String get label => switch (this) {
    ProxyMode.system => 'System',
    ProxyMode.custom => 'Custom',
    ProxyMode.off => 'Off',
  };

  /// Only a non-default choice is written, matching every other preference in
  /// [AppSettingsStore].
  String? get storageValue => switch (this) {
    ProxyMode.system => null,
    ProxyMode.custom => 'custom',
    ProxyMode.off => 'off',
  };

  static ProxyMode parse(String? raw) {
    for (final value in ProxyMode.values) {
      if (value.storageValue == raw) return value;
    }
    return ProxyMode.system;
  }

  ProxyMode get next => switch (this) {
    ProxyMode.system => ProxyMode.custom,
    ProxyMode.custom => ProxyMode.off,
    ProxyMode.off => ProxyMode.system,
  };
}

/// One proxy address, resolved and ready to hand to `HttpClient.findProxy`.
///
/// [exclusions] mirrors the platform's bypass list (Android's
/// `ProxyInfo.exclusionList`, Windows' `ProxyOverride`). It matters: the phone's
/// Wi-Fi proxy in the field excludes `*.site` and one literal IP, and forcing
/// those through the proxy breaks the panel they exist for.
@immutable
class ProxyEndpoint {
  const ProxyEndpoint({
    required this.host,
    required this.port,
    this.type = 'HTTP',
    this.exclusions = const [],
  });

  final String host;
  final int port;

  /// `HTTP` or `SOCKS`.
  final String type;
  final List<String> exclusions;

  String get label => '$host:$port';

  /// What `HttpClient.findProxy` expects for a request to [uri].
  String findProxyFor(Uri uri) {
    if (excludes(uri.host) || isLocalHost(uri.host)) return 'DIRECT';
    return type == 'SOCKS' ? 'SOCKS $host:$port' : 'PROXY $host:$port';
  }

  /// Whether [host] is a LAN/local address that must never be sent to a proxy.
  ///
  /// **This is the `ProxyOverride` `<local>` rule, and it is not optional.** The
  /// panel can live on a dotless LAN name (`http://transmission/...`), and a
  /// real proxy answers such a request by closing the connection — reported as
  /// "Connection closed before full header was received" on Android while the
  /// very same URL worked through curl, which bypasses LAN names by default.
  /// A proxy is for the internet; a name the router resolves is not the
  /// internet.
  @visibleForTesting
  static bool isLocalHost(String host) {
    final h = host.trim().toLowerCase();
    if (h.isEmpty) return false;
    if (h == 'localhost' || h.endsWith('.localhost')) return true;
    // mDNS names are LAN by definition.
    if (h.endsWith('.local')) return true;
    // IPv6 literal: loopback, link-local and unique-local are all "here".
    if (h.contains(':')) {
      return h == '::1' ||
          h.startsWith('fe80:') ||
          h.startsWith('fc') ||
          h.startsWith('fd');
    }
    // A single-label name has no public DNS meaning; it is resolved by the
    // router's search domain (`transmission`, `nas`, `proxy`).
    if (!h.contains('.')) return true;
    final parts = h.split('.');
    if (parts.length != 4) return false;
    final octets = [for (final part in parts) int.tryParse(part)];
    if (octets.any((value) => value == null || value < 0 || value > 255)) {
      return false;
    }
    final a = octets[0]!;
    final b = octets[1]!;
    if (a == 10 || a == 127) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 169 && b == 254) return true;
    return false;
  }

  /// Whether [host] is on this endpoint's bypass list.
  bool excludes(String host) => isExcluded(host, exclusions);

  @override
  bool operator ==(Object other) =>
      other is ProxyEndpoint &&
      other.host == host &&
      other.port == port &&
      other.type == type &&
      listEquals(other.exclusions, exclusions);

  @override
  int get hashCode => Object.hash(host, port, type, Object.hashAll(exclusions));

  /// Whether [host] is on a platform bypass list.
  ///
  /// The shapes platforms actually ship: a literal host or IP, `*.example.com`,
  /// `.example.com`, `<local>` (a bare hostname with no dots — the LAN), a bare
  /// `*` (bypass everything), and the odd interior wildcard. Matching is
  /// case-insensitive and ignores surrounding whitespace.
  static bool isExcluded(String host, List<String> patterns) {
    final target = host.trim().toLowerCase();
    for (final raw in patterns) {
      var pattern = raw.trim().toLowerCase();
      if (pattern.isEmpty) continue;
      if (pattern == '*') return true;
      if (pattern == '<local>') {
        if (!target.contains('.')) return true;
        continue;
      }
      if (pattern.startsWith('*')) pattern = pattern.substring(1);
      if (pattern.startsWith('.')) {
        if (target == pattern.substring(1) || target.endsWith(pattern)) {
          return true;
        }
        continue;
      }
      if (pattern.contains('*')) {
        if (_wildcardMatches(pattern, target)) return true;
        continue;
      }
      if (target == pattern) return true;
    }
    return false;
  }

  static bool _wildcardMatches(String pattern, String target) {
    final buffer = StringBuffer('^');
    for (final rune in pattern.runes) {
      final char = String.fromCharCode(rune);
      buffer.write(char == '*' ? '.*' : RegExp.escape(char));
    }
    buffer.write(r'$');
    return RegExp(buffer.toString()).hasMatch(target);
  }
}

/// The user's proxy choice, as stored. [host]/[port] only matter in
/// [ProxyMode.custom].
@immutable
class ProxyConfig {
  const ProxyConfig({
    this.mode = ProxyMode.system,
    this.host = '',
    this.port = 0,
  });

  final ProxyMode mode;
  final String host;
  final int port;

  bool get isCustomValid =>
      mode == ProxyMode.custom && _validHost(host) && port > 0;

  ProxyConfig copyWith({ProxyMode? mode, String? host, int? port}) =>
      ProxyConfig(
        mode: mode ?? this.mode,
        host: host ?? this.host,
        port: port ?? this.port,
      );

  static bool _validHost(String value) => value.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ProxyConfig &&
      other.mode == mode &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(mode, host, port);
}

/// The stored choice. Read once at boot, written from Settings.
final ValueNotifier<ProxyConfig> proxyConfig = ValueNotifier(
  const ProxyConfig(),
);

/// What [HttpOverrides] is currently answering with, for the Settings subtitle
/// and the diagnostics log. `null` means direct.
final ValueNotifier<ProxyEndpoint?> effectiveProxy = ValueNotifier(null);

/// Reads the stored proxy choice into [proxyConfig] and applies it. Called once
/// at boot, before the first `HttpClient` exists.
Future<void> loadProxyConfig({AppSettingsStore? store}) async {
  const settings = AppSettingsStore();
  final raw = await (store ?? settings).rawProxyConfig();
  proxyConfig.value = ProxyConfig(
    mode: ProxyMode.parse(raw?['mode']),
    host: raw?['host'] ?? '',
    port: int.tryParse(raw?['port'] ?? '') ?? 0,
  );
  await applyProxyConfig();
}

/// Sets the choice, publishes it (so a live Settings change lands at once) and
/// persists it.
///
/// Publication is first on purpose, the same order as the card-shape setting:
/// the write can fail (a locked keychain) and it must not be able to leave the
/// session deciding with the old proxy after the user watched the label change.
Future<void> setProxyConfig(
  ProxyConfig value, {
  AppSettingsStore? store,
}) async {
  proxyConfig.value = value;
  await applyProxyConfig();
  await (store ?? const AppSettingsStore()).setRawProxyConfig({
    'mode': value.mode.storageValue ?? '',
    'host': value.host,
    'port': value.port > 0 ? '${value.port}' : '',
  });
}

/// Resolves [proxyConfig] against the platform and installs the result.
Future<void> applyProxyConfig() async {
  final endpoint = await resolveProxyEndpoint(proxyConfig.value);
  effectiveProxy.value = endpoint;
  installProxyOverride();
  DiagnosticsLog.instance.addAndPrint(
    'net',
    endpoint == null
        ? 'no proxy (mode=${proxyConfig.value.mode.name}, direct)'
        : 'proxy ${endpoint.label} (${endpoint.type}, '
              'mode=${proxyConfig.value.mode.name}, '
              'bypass=${endpoint.exclusions.length})',
  );
}

/// Installs the app-wide override without resolving anything.
///
/// Called synchronously at boot so **every** `HttpClient` from the first frame
/// on can answer with the current proxy. The answer is read per request from
/// [effectiveProxy], so a client created before the platform lookup finishes
/// still uses the proxy for its requests — there is no race to lose.
void installProxyOverride() {
  HttpOverrides.global = _AppProxyOverrides();
}

/// The endpoint [config] resolves to right now, or null for a direct connection.
@visibleForTesting
Future<ProxyEndpoint?> resolveProxyEndpoint(ProxyConfig config) async {
  switch (config.mode) {
    case ProxyMode.off:
      return null;
    case ProxyMode.custom:
      final host = config.host.trim();
      if (host.isEmpty || config.port <= 0 || config.port > 65535) {
        // A half-filled Custom choice must not silently send traffic nowhere:
        // direct is what the install had before, so it fails soft.
        return null;
      }
      return ProxyEndpoint(host: host, port: config.port);
    case ProxyMode.system:
      return _systemProxy();
  }
}

Future<ProxyEndpoint?> _systemProxy() async {
  if (Platform.isAndroid) return _androidProxy();
  if (Platform.isWindows) return _windowsProxy();
  return _environmentProxy();
}

/// Android's per-network Wi-Fi proxy, through `iptvs/device`.
Future<ProxyEndpoint?> _androidProxy() async {
  try {
    const channel = MethodChannel('iptvs/device');
    final map = await channel.invokeMapMethod<String, Object?>('proxy');
    final host = map?['host'] as String?;
    final port = (map?['port'] as num?)?.toInt();
    if (host == null || host.isEmpty || port == null || port <= 0) return null;
    return ProxyEndpoint(
      host: host,
      port: port,
      type: (map?['type'] as String?) ?? 'HTTP',
      exclusions: [
        for (final value in (map?['exclusions'] as List?) ?? const [])
          if (value is String) value,
      ],
    );
  } catch (error) {
    // No runner answer, or a platform without the handler: direct.
    DiagnosticsLog.instance.addAndPrint('net', 'android proxy lookup: $error');
    return null;
  }
}

/// Windows' "Proxy settings" dialog, which lives in the registry and is not
/// exported to the environment.
///
/// `ProxyServer` is either `host:port` or a per-scheme run like
/// `http=h:p;https=h:p;socks=h:p`. HTTPS is preferred when present (every image
/// and API call here is HTTPS), then HTTP, then whatever is first — and a
/// `socks` entry switches the type, because `findProxy` must name it.
Future<ProxyEndpoint?> _windowsProxy() async {
  try {
    final values = await _regQuery(
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
    );
    if (values['ProxyEnable'] != '1') return null;
    final server = values['ProxyServer'] ?? '';
    if (server.isEmpty) return null;
    final entries = <String, String>{};
    if (server.contains('=')) {
      for (final part in server.split(';')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        entries[part.substring(0, eq).trim().toLowerCase()] = part
            .substring(eq + 1)
            .trim();
      }
    } else {
      entries['https'] = server.trim();
      entries['http'] = server.trim();
    }
    final scheme = entries.containsKey('https')
        ? 'https'
        : entries.containsKey('http')
        ? 'http'
        : (entries.isEmpty ? null : entries.keys.first);
    if (scheme == null) return null;
    final address = entries[scheme] ?? '';
    final split = _splitHostPort(address, defaultPort: 1080);
    if (split == null) return null;
    final override = values['ProxyOverride'] ?? '';
    return ProxyEndpoint(
      host: split.$1,
      port: split.$2,
      type: scheme == 'socks' ? 'SOCKS' : 'HTTP',
      exclusions: [
        for (final part in override.split(';'))
          if (part.trim().isNotEmpty) part.trim(),
      ],
    );
  } catch (error) {
    DiagnosticsLog.instance.addAndPrint('net', 'windows proxy lookup: $error');
    return null;
  }
}

Future<Map<String, String>> _regQuery(String key) async {
  final result = await Process.run('reg', ['query', key]);
  final values = <String, String>{};
  if (result.exitCode != 0) return values;
  for (final line in (result.stdout as String).split(RegExp(r'\r?\n'))) {
    final match = RegExp(
      r'^\s{2,}(\S+)\s{2,}REG_\w+\s{2,}(.*)$',
    ).firstMatch(line);
    if (match == null) continue;
    values[match.group(1)!] = match.group(2)!.trim();
  }
  return values;
}

/// The `http_proxy` family, for the platforms without a system-proxy bridge
/// (Linux, macOS). Same `host:port` shape, `socks5://` and a scheme prefix
/// accepted.
ProxyEndpoint? _environmentProxy() {
  final env = Platform.environment;
  for (final key in const [
    'https_proxy',
    'HTTPS_PROXY',
    'http_proxy',
    'HTTP_PROXY',
    'all_proxy',
    'ALL_PROXY',
  ]) {
    final value = env[key]?.trim();
    if (value == null || value.isEmpty) continue;
    final isSocks = value.toLowerCase().startsWith('socks');
    final withoutScheme = value.contains('://')
        ? value.substring(value.indexOf('://') + 3)
        : value;
    final authority = withoutScheme.split('/').first;
    final split = _splitHostPort(
      authority.contains('@') ? authority.split('@').last : authority,
      defaultPort: isSocks ? 1080 : 8080,
    );
    if (split == null) continue;
    return ProxyEndpoint(
      host: split.$1,
      port: split.$2,
      type: isSocks ? 'SOCKS' : 'HTTP',
    );
  }
  return null;
}

(String, int)? _splitHostPort(String value, {int defaultPort = 8080}) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('[')) {
    final close = trimmed.indexOf(']');
    if (close < 0) return null;
    final host = trimmed.substring(1, close);
    final rest = trimmed.substring(close + 1);
    final port = rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null;
    if (host.isEmpty) return null;
    return (host, port ?? defaultPort);
  }
  final colon = trimmed.lastIndexOf(':');
  if (colon < 0) return (trimmed, defaultPort);
  final host = trimmed.substring(0, colon).trim();
  final port = int.tryParse(trimmed.substring(colon + 1).trim());
  if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
  return (host, port);
}

/// Applies [effectiveProxy] to every `HttpClient` the app creates.
///
/// `dart:io` deliberately ignores the platform proxy, and `package:http`/
/// `flutter_cache_manager` sit on top of it, so this one hook reaches API calls
/// and artwork alike. The answer is read per request rather than captured, so a
/// Settings change applies to the next request without rebuilding anything.
class _AppProxyOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) =>
        effectiveProxy.value?.findProxyFor(uri) ?? 'DIRECT';
    return client;
  }
}

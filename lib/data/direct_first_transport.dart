import 'dart:io';

import 'diagnostics_log.dart';
import 'proxy_config.dart';

/// A fetch that tries the **direct** route first and falls back to the
/// configured proxy, for one-off downloads.
///
/// The rule this exists for: a proxy is a detour, and everything reachable
/// without one should not take it. Guides (XMLTV) and artwork are the two things
/// fetched outside the provider's own API — a guide often sits on the same LAN
/// host as the panel, and a filtered CDN refuses the direct connection but works
/// through the proxy. Both failure modes are covered by trying direct and
/// retrying on failure, instead of picking one route for everything.
///
/// [fallback] is the caller's own client (timeouts, user agent, TLS settings),
/// which already follows the app-wide proxy policy. The direct client is created
/// here, ignores every override and states `DIRECT` explicitly — the same trick
/// `lib/widgets/artwork_cache.dart` uses.
///
/// A host that fails direct is remembered by
/// [noteDirectFailure]/[shouldTryDirectFirst], shared with artwork, so a guide
/// refresh (or a grid of posters) pays the timeout once per host rather than once
/// per request.
class DirectFirstTransport {
  DirectFirstTransport(
    this.fallback, {
    this.directTimeout = const Duration(seconds: 6),
  });

  final HttpClient fallback;

  /// Short on purpose: this attempt precedes every download, so a dropped
  /// connection must not stall a refresh for the client's own timeout.
  final Duration directTimeout;

  HttpClient? _direct;

  HttpClient get _directClient => _direct ??= _newDirectClient(directTimeout);

  /// Runs [attempt] against the direct client when that is worth trying, and
  /// against [fallback] otherwise or after a failure.
  Future<T> run<T>(
    Uri uri,
    Future<T> Function(HttpClient client) attempt,
  ) async {
    if (!shouldTryDirectFirst(uri.host)) return attempt(fallback);
    try {
      return await attempt(_directClient);
    } catch (error) {
      noteDirectFailure(uri.host);
      DiagnosticsLog.instance.addAndPrint(
        'net',
        'direct fetch failed host=${uri.host} '
            '($error) — retrying through the proxy',
      );
      return attempt(fallback);
    }
  }

  void close() {
    _direct?.close(force: true);
    _direct = null;
  }
}

HttpClient _newDirectClient(Duration timeout) {
  // `runWithHttpOverrides` is the only documented way to get an `HttpClient`
  // that ignores `HttpOverrides.global`; a bare subclass asks for the raw
  // client, and `findProxy` then states the policy this transport wants.
  final client = HttpOverrides.runWithHttpOverrides(
      () => HttpClient(), _PlainHttpOverrides())
    ..connectionTimeout = timeout
    ..idleTimeout = const Duration(seconds: 15);
  client.findProxy = (_) => 'DIRECT';
  return client;
}

class _PlainHttpOverrides extends HttpOverrides {}

import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../data/proxy_config.dart';

/// Cache key of the artwork cache.
///
/// **The same key the default cache manager uses**, so this manager reuses the
/// files an older build already downloaded instead of starting a second copy of
/// a catalogue-sized cache on disk.
const String kArtworkCacheKey = 'libCachedImageData';

/// The one cache manager behind every `CachedNetworkImage` in the app.
///
/// It exists for its [FileService]: artwork is fetched **direct first and
/// through the proxy only if that fails**, which is the opposite of the API
/// traffic (that follows the proxy setting as configured). Posters routinely
/// come from a LAN address next to the panel, and a phone's Wi-Fi proxy would
/// otherwise send a local host through the proxy and break every thumbnail —
/// the failure that prompted this. A CDN the network blocks, on the other hand,
/// fails direct and then succeeds through the proxy.
final CacheManager artworkCacheManager = CacheManager(
  Config(
    kArtworkCacheKey,
    stalePeriod: const Duration(days: 30),
    maxNrOfCacheObjects: 200,
    fileService: ProxyAwareFileService(),
  ),
);

/// A [FileService] that tries the direct connection first and retries through
/// the configured proxy when that fails.
///
/// "Fails" is either an exception (the connect is dropped — what a filtered
/// domain looks like) or a non-success status (a block page answered 403).
/// Both are retried, because the point is to be indistinguishable from the
/// network's point of view: whichever route works is the route that wins.
///
/// **A host that fails direct is remembered**, so a grid of twenty posters on a
/// blocked CDN pays the direct timeout once rather than twenty times. The memory
/// is temporary (a network change can unblock a host) and bounded.
class ProxyAwareFileService extends FileService {
  ProxyAwareFileService({
    this.directTimeout = const Duration(seconds: 4),
    this.proxyTimeout = const Duration(seconds: 20),
  });

  /// Short on purpose: this attempt precedes every artwork download, so a
  /// dropped connection must not stall the grid for the default 20 s.
  final Duration directTimeout;
  final Duration proxyTimeout;

  HttpFileService? _directService;
  HttpFileService? _proxyService;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final uri = Uri.tryParse(url);
    final endpoint = effectiveProxy.value;
    if (uri == null || endpoint == null || endpoint.excludes(uri.host)) {
      return _directFetcher.get(url, headers: headers);
    }
    // The host memory is **shared** with guide downloads
    // (`lib/data/proxy_fetch.dart`): a host that fails direct fails for both,
    // and one timeout per host is enough.
    if (shouldTryDirectFirst(uri.host)) {
      try {
        final response = await _directFetcher.get(url, headers: headers);
        if (_isSuccess(response.statusCode)) return response;
        // Drain and drop the block page: its socket is otherwise left open
        // until GC, and a filtered CDN answers one of these per poster.
        unawaited(response.content.listen(null).cancel());
        noteDirectFailure(uri.host);
      } catch (error) {
        noteDirectFailure(uri.host);
      }
    }
    return _proxyFetcher.get(url, headers: headers);
  }

  HttpFileService get _directFetcher =>
      _directService ??= HttpFileService(httpClient: _client(direct: true));

  HttpFileService get _proxyFetcher =>
      _proxyService ??= HttpFileService(httpClient: _client(direct: false));

  http.Client _client({required bool direct}) {
    // `runWithHttpOverrides` is the only documented way to get an
    // `HttpClient` that ignores `HttpOverrides.global`, which `dart:io` sets for
    // the whole app from the proxy setting. A bare `HttpOverrides` subclasses
    // nothing, so the client it builds has no proxy policy of its own — this
    // function then states one: DIRECT, or whatever the setting currently
    // resolves to (read per request, so a Settings change needs no new client).
    final io =
        HttpOverrides.runWithHttpOverrides(
            () => HttpClient(),
            _PlainOverrides(),
          )
          ..connectionTimeout = direct ? directTimeout : proxyTimeout
          ..idleTimeout = const Duration(seconds: 15);
    io.findProxy = direct
        ? (_) => 'DIRECT'
        : (uri) => effectiveProxy.value?.findProxyFor(uri) ?? 'DIRECT';
    return IOClient(io);
  }

  static bool _isSuccess(int statusCode) =>
      statusCode == HttpStatus.ok ||
      statusCode == HttpStatus.accepted ||
      statusCode == HttpStatus.notModified;
}

/// The proxy-free `HttpOverrides`: it overrides nothing, so the client it
/// builds is the raw `dart:io` one. Exists only to let [ProxyAwareFileService]
/// ask for a connection policy the app-wide override does not apply to.
class _PlainOverrides extends HttpOverrides {}

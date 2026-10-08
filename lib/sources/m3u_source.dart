import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import '../data/load_token.dart';
import '../data/diagnostics_log.dart';
import '../data/net.dart';
import '../data/secret_locator_vault.dart' show hasSealedLocator;
import 'epg_guides.dart';
import 'epg_matching.dart';
import 'expiry.dart';
import 'source.dart';
import 'source_identity.dart';
// For the Xtream-panel expiry probe in [M3uSource.subscriptionExpiry]. One-way:
// `xtream_source.dart` does not import this file, so there is no cycle.
import 'xtream_source.dart';

/// A [Source] backed by an extended M3U/M3U8 playlist (URL).
///
/// Stream URLs are static, so resolving needs no network. EPG comes from an
/// XMLTV guide — either an explicit [epgUrl] or the playlist's own
/// `url-tvg`/`x-tvg-url` header attribute.
class M3uSource
    implements
        Source,
        BatchedEpgSource,
        CatchupSource,
        SourceCapabilityReporter,
        RefreshableSource {
  final String sourceId;
  final String playlistUrl;
  final String? epgUrl;

  /// Extra XMLTV guides layered *under* [epgUrl]/`url-tvg`, in priority order.
  /// See [mergeEpgGuides] for what "under" means: a channel is served by the
  /// first guide that carries it, never by two at once.
  final List<String> extraEpgUrls;

  final String? userAgent;
  final String? catchupTimezone;
  final int? catchupOffsetMinutes;
  final int? catchupMaxDays;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..autoUncompress = false;

  List<Channel>? _channels;
  List<Category>? _categories;
  List<MediaItem>? _media;
  List<MediaCategory>? _mediaCategories;
  String? _headerEpgUrl;
  CatchupCapability _catchupCapability = CatchupCapability.unsupported;

  M3uSource({
    required this.sourceId,
    required this.playlistUrl,
    this.epgUrl,
    this.extraEpgUrls = const [],
    this.userAgent,
    this.catchupTimezone,
    this.catchupOffsetMinutes,
    this.catchupMaxDays,
    this.displayName,
    this.debugXtreamApi,
    this.debugPlaylistLoader,
  });

  /// User-assigned label (from SourceConfig); preferred over the derived name.
  final String? displayName;

/// Test seam for the Xtream panel probe in [subscriptionExpiry], threaded
  /// straight through to [XtreamSource.debugApi] so a test can exercise the
  /// `get.php` → `player_api.php` path without HTTP. Null in production.
  @visibleForTesting
  final Future<dynamic> Function(Map<String, String> params)? debugXtreamApi;

  /// Test seam for [playlistUrl]'s fetch: returning bytes here lets a test
  /// exercise parsing and the catalogue methods without HTTP. Null in
  /// production, where [_download] is used.
  @visibleForTesting
  final Future<Uint8List> Function()? debugPlaylistLoader;

  @override
  String get id => sourceId;

  @override
  String get name => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : 'M3U · ${Uri.tryParse(playlistUrl)?.host ?? 'playlist'}';

  @override
  CatchupCapability get catchupCapability => _catchupCapability;

  @override
  SourceCapabilities get sourceCapabilities => SourceCapabilities(
    epg: (epgUrl != null || extraEpgUrls.isNotEmpty)
        ? CapabilityAvailability.supported
        : (_headerEpgUrl != null
              ? CapabilityAvailability.supported
              : CapabilityAvailability.unknown),
    catchup: _channels == null
        ? CapabilityAvailability.unknown
        : (_catchupCapability.supported
              ? CapabilityAvailability.supported
              : CapabilityAvailability.unavailable),
    resolution: ResolutionCapability.playlistDefined,
  );

  @override
  Future<void> connect() async {} // nothing to authenticate

  @override
  Future<List<Category>> categories() async {
    await _ensureParsed();
    return _categories!;
  }

  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    await _ensureParsed();
    if (categoryId == null) return _channels!;
    return _channels!.where((c) => c.categoryId == categoryId).toList();
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    assert(
      !hasSealedLocator(channel.extra),
      'sealed locator reached M3uSource.resolve — reveal it in '
      'LibraryRepository first',
    );
    final url = channel.extra['url']?.toString();
    if (url == null || url.isEmpty) {
      throw StateError('Channel "${channel.name}" has no stream URL');
    }
    return StreamInfo(
      url: url,
      headers: userAgent != null ? {'User-Agent': userAgent!} : const {},
    );
  }

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async {
    assert(
      !hasSealedLocator(channel.extra),
      'sealed locator reached M3uSource.resolveArchive — reveal it in '
      'LibraryRepository first',
    );
    final template =
        channel.extra['catchupSource']?.toString() ??
        catchupCapability.template;
    if (template == null || template.isEmpty) {
      throw UnsupportedError('M3U channel does not advertise catch-up');
    }
    final start = programme.start.toUtc().millisecondsSinceEpoch ~/ 1000;
    final end = programme.stop.toUtc().millisecondsSinceEpoch ~/ 1000;
    final url = template
        .replaceAll('{start}', '$start')
        .replaceAll('{end}', '$end')
        .replaceAll('%START%', '$start')
        .replaceAll('%END%', '$end');
    return StreamInfo(
      url: url,
      headers: userAgent == null ? const {} : {'User-Agent': userAgent!},
      isLive: false,
    );
  }

  /// Unbatched fallback, kept for [Source]'s contract. Drains the same merged
  /// feed [epgBatched] builds, so the two can't diverge in matching or merge
  /// order — only in whether the result is held in memory at once.
  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    final feeds = _guideFeeds(channels, null);
    if (feeds.isEmpty) return const [];
    final out = <Programme>[];
    await for (final batch in mergeEpgGuides(feeds)) {
      out.addAll(batch);
    }
    return out;
  }

  @override
  Stream<List<Programme>>? epgBatched(
    List<Channel> channels, {
    LoadToken? token,
  }) {
    final feeds = _guideFeeds(channels, token);
    return feeds.isEmpty ? null : mergeEpgGuides(feeds, token: token);
  }

  /// The guides this source should ingest, in priority order: the playlist's
  /// own (explicit [epgUrl] or its `url-tvg` header) first, then [extraEpgUrls].
  ///
  /// Empty — which both EPG entry points report as "no guide configured" — when
  /// there is no URL, or when the channels offer nothing to match *on*. That
  /// second test now accepts a name index as well as `tvg-id`s: a playlist
  /// carrying no `tvg-id` at all used to skip its guide outright, and is
  /// exactly the playlist a third-party guide is added for.
  List<EpgGuideFeed> _guideFeeds(List<Channel> channels, LoadToken? token) {
    final primary = epgUrl ?? _headerEpgUrl;
    final hasPrimary = primary != null && primary.isNotEmpty;
    final urls = <String>[
      if (hasPrimary) primary,
      for (final url in extraEpgUrls)
        if (url.isNotEmpty && url != primary) url,
    ];
    if (urls.isEmpty) return const [];
    final tvgIds = buildTvgIdIndex(channels);
    final names = epgNameIndexFor(channels, extraCount: urls.length - 1);
    if (tvgIds.isEmpty && names.isEmpty) return const [];
    return [
      for (var i = 0; i < urls.length && i < kMaxEpgGuides; i++)
        xmltvGuideFeed(
          url: urls[i],
          download: (uri) => _download(uri, kEpgWorkload),
          tvgIdToChannelId: tvgIds,
          nameToChannelIds: hasPrimary && i == 0 ? const {} : names,
          token: token,
        ),
    ];
  }

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async {
    await _ensureParsed();
    // File-backed M3U rows are movies only — nothing here can distinguish a
    // series from a movie without the panel's metadata, so the series tab
    // stays empty for a flat playlist.
    return kind == ContentKind.movie ? _mediaCategories! : const [];
  }

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async {
    await _ensureParsed();
    if (kind != ContentKind.movie || parent != null) return const [];
    final all = _mediaInCategory(categoryId);
    final cap = maxPages == null ? all.length : maxPages * kM3uMediaPageSize;
    return all.take(cap).toList();
  }

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    await _ensureParsed();
    if (kind != ContentKind.movie || parent != null) {
      return MediaPage(items: const [], page: page, totalPages: 0);
    }
    final all = _mediaInCategory(categoryId);
    final totalPages = all.isEmpty ? 0 : (all.length / kM3uMediaPageSize).ceil();
    final safePage = page < 1 ? 1 : page;
    final start = (safePage - 1) * kM3uMediaPageSize;
    if (start >= all.length) {
      return MediaPage(items: const [], page: safePage, totalPages: totalPages);
    }
    final end = min(start + kM3uMediaPageSize, all.length);
    return MediaPage(
      items: all.sublist(start, end),
      page: safePage,
      totalPages: totalPages,
    );
  }

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    await _ensureParsed();
    if (kind != ContentKind.movie || query.trim().isEmpty) return const [];
    final needle = query.trim().toLowerCase();
    return _mediaInCategory(categoryId)
        .where((m) => m.title.toLowerCase().contains(needle))
        .take(200)
        .toList();
  }

  List<MediaItem> _mediaInCategory(String? categoryId) {
    final all = _media!;
    if (categoryId == null) return all;
    return all.where((m) => m.categoryId == categoryId).toList();
  }

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async {
    assert(
      !hasSealedLocator(item.extra),
      'sealed locator reached M3uSource.resolveMedia — reveal it in '
      'LibraryRepository first',
    );
    final url = item.extra['url']?.toString();
    if (url == null || url.isEmpty) {
      throw StateError('"${item.title}" has no stream URL');
    }
    // A file plays with a finite duration: seek bar, runtime, speed menu.
    // `isLive` is provider metadata — the URL extension was the provider's own
    // answer to "is this a stream", set once by the parser.
    return StreamInfo(
      url: url,
      headers: userAgent != null ? {'User-Agent': userAgent!} : const {},
      isLive: false,
    );
  }

  /// Playlist expiry, from the URL when it carries one and from the panel when
  /// the URL is really an Xtream link.
  ///
  /// A plain M3U genuinely has no expiry metadata, so the URL-parameter read
  /// ([subscriptionExpiryFromPlaylistUrl]) is all there is — and for a hand-
  /// written playlist "unknown" is the honest answer. But a very large share of
  /// M3U sources are an Xtream panel's `get.php` link, which carries
  /// `username`/`password` and **no expiry parameter at all**: nothing for the
  /// URL read to find, so those reported unknown forever while the panel would
  /// have answered on request. `player_api.php` is exactly where
  /// [XtreamSource.subscriptionExpiry] gets it, so this asks the same question
  /// the same way rather than reimplementing it — the probe is short-lived and
  /// disposed, and it only runs when the URL actually looks like a panel link.
  ///
  /// The add-source flow already offers to convert such a source to a real
  /// Xtream config (`_maybeConvertM3uToXtream`), which is the better outcome
  /// because it also unlocks Movies/Series. This covers the ones that stayed
  /// M3U anyway: added before that existed, or converted-probe failed at the
  /// time, or deliberately kept flat.
  @override
  Future<SubscriptionExpiry> subscriptionExpiry() async {
    final fromUrl = subscriptionExpiryFromPlaylistUrl(playlistUrl);
    if (fromUrl.kind != SubscriptionExpiryKind.unknown) return fromUrl;

    final uri = Uri.tryParse(playlistUrl);
    final credentials = uri == null ? null : xtreamCredentialsFromUrl(uri);
    if (credentials == null) {
      // Nothing else to ask. Say so, rather than leaving the badge
      // unexplained: an M3U with no expiry parameter and no panel behind it is
      // a correct "unknown", and that is worth being able to tell apart from a
      // lookup that failed.
      DiagnosticsLog.instance.add(
        'm3u',
        'expiry unknown: playlist url carries no expiry parameter and no '
            'xtream credentials',
      );
      return fromUrl;
    }
    final probe = XtreamSource(
      sourceId: sourceId,
      host: credentials.host,
      username: credentials.username,
      password: credentials.password,
      debugApi: debugXtreamApi,
    );
    try {
      final parsed = await probe.subscriptionExpiry();
      if (parsed.kind == SubscriptionExpiryKind.unknown) {
        DiagnosticsLog.instance.add(
          'm3u',
          'expiry unknown: xtream player_api returned no usable exp_date',
        );
      }
      return parsed;
    } catch (e) {
      // Best-effort — the badge shows "Expiry unknown". The type alone is
      // enough to separate "panel refused/unreachable" from "panel answered
      // with nothing"; the message can embed the URL, so it stays out.
      DiagnosticsLog.instance.add(
        'm3u',
        'expiry unknown: xtream player_api lookup failed (${e.runtimeType})',
      );
      return fromUrl;
    } finally {
      await probe.dispose();
    }
  }

  @override
  Future<void> dispose() async => _http.close(force: true);

  // ── parsing ────────────────────────────────────────────────────────────

  // Small playlists parse fast enough inline; isolate spawn overhead would
  // dominate. Mirrors XtreamSource's `_isolateJsonThreshold`.
  static const _isolateM3uThreshold = 256 * 1024;

  @override
  void invalidate() {
    // Drop everything _ensureParsed memoizes so a forced reload re-downloads
    // and re-parses the playlist — otherwise a stale channel list, VOD
    // catalogue, header EPG url, and catch-up capability would survive
    // "Reload source".
    _channels = null;
    _categories = null;
    _media = null;
    _mediaCategories = null;
    _headerEpgUrl = null;
    _catchupCapability = CatchupCapability.unsupported;
  }

  Future<void> _ensureParsed() async {
    if (_channels != null) return;
    // The test seam returns bytes directly; production downloads the URL.
    final debugLoader = debugPlaylistLoader;
    final bytes = debugLoader != null
        ? await debugLoader()
        : await _download(Uri.parse(playlistUrl), kPlaylistWorkload);
    // Decode + parse on a background isolate: a large playlist (tens of MB,
    // tens of thousands of channels) would otherwise stall the UI thread for
    // hundreds of ms while building Channel objects.
    final parsed = bytes.length < _isolateM3uThreshold
        ? _parseM3uBytes(bytes)
        : await compute(_parseM3uBytes, bytes);
    _channels = parsed.channels;
    _categories = parsed.categories;
    _media = parsed.media;
    _mediaCategories = parsed.mediaCategories;
    _headerEpgUrl = parsed.headerEpgUrl;
    final parsedCapability = parsed.catchupCapability;
    _catchupCapability = parsedCapability.supported
        ? CatchupCapability(
            mode: parsedCapability.mode,
            timezone: catchupTimezone ?? parsedCapability.timezone,
            fixedOffsetMinutes: catchupOffsetMinutes,
            maxArchiveWindow: catchupMaxDays == null
                ? parsedCapability.maxArchiveWindow
                : Duration(days: catchupMaxDays!),
            startFormat: parsedCapability.startFormat,
            endFormat: parsedCapability.endFormat,
            template: parsedCapability.template,
          )
        : parsedCapability;
    DiagnosticsLog.instance.add(
      'parse:m3u',
      'rejected_rows=${parsed.rejectedRows}',
    );
  }

  Future<Uint8List> _download(Uri uri, HttpWorkloadPolicy policy) async {
    final operation = HttpOperation(
      policy,
      onReadMetrics: (m) => DiagnosticsLog.instance.add(
        'http:${policy.name}',
        'compressed_bytes=${m.compressedBytes} decoded_bytes=${m.decodedBytes}',
      ),
    );
    final req = await operation.wait(_http.getUrl(uri));
    if (userAgent != null) {
      req.headers.set(HttpHeaders.userAgentHeader, userAgent!);
    }
    final resp = await operation.wait(req.close());
    if (resp.statusCode != 200) {
      // Drain before throwing: an unread body never returns its socket to the
      // pool, so a guide URL that 404s leaks one per EPG refresh.
      await resp.drain<void>();
      // redactUrl strips credentials some providers embed in the playlist URL.
      throw StateError('HTTP ${resp.statusCode} fetching ${redactUrl(uri)}');
    }
    return operation.readBytes(resp);
  }
}

/// Result of parsing a playlist, sent back from the parse isolate.
class M3uParsed {
  final List<Channel> channels;
  final List<Category> categories;

  /// File-backed rows (see [isM3uFileLocator]) surfaced as the movies
  /// catalogue, and their groups in playlist order.
  final List<MediaItem> media;
  final List<MediaCategory> mediaCategories;

  final String? headerEpgUrl;
  final CatchupCapability catchupCapability;
  final int rejectedRows;
  const M3uParsed(
    this.channels,
    this.categories,
    this.headerEpgUrl, [
    this.catchupCapability = CatchupCapability.unsupported,
    this.rejectedRows = 0,
    this.media = const [],
    this.mediaCategories = const [],
  ]);
}

/// Isolate entrypoint: decodes [bytes] and parses the playlist. Kept top-level
/// and pure so it can run under [compute] (no access to instance state).
M3uParsed _parseM3uBytes(Uint8List bytes) =>
    parseM3uPlaylist(utf8.decode(bytes, allowMalformed: true));

/// Rows of the media catalogue per [mediaItemsPage]/[mediaItems] call. The
/// whole playlist is parsed once, so the page size only decides how many items
/// a "Next page" step reveals, never how many downloads happen.
const kM3uMediaPageSize = 100;

/// URL-path extensions that are unambiguously a *stream* — everything else in
/// [_m3uStreamFileExtensions] wins over [_m3uMediaFileExtensions], because a
/// `.ts`/`.m3u8` row is a live (or timeshift) transport stream, not a file.
const _m3uStreamFileExtensions = {'m3u8', 'm3u', 'ts', 'mpd', 'ism', 'isml'};

/// Direct file extensions a playlist can hand us instead of a stream — a real
/// `.mp4`, `.mkv`, … that plays as VOD. See [isM3uFileLocator].
const _m3uMediaFileExtensions = {
  'mp4', 'm4v', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'mpg', 'mpeg',
  'm2v', '3gp', 'ogv', 'm2ts', 'm2t', 'mts',
  'mp3', 'm4a', 'aac', 'oga', 'ogg', 'opus', 'wav', 'flac', 'mka',
};

/// Whether an M3U URL line points at a **file** rather than a stream.
///
/// The decision is the **extension of the URL only** — never the `#EXTINF`
/// duration, which may be absent (`#EXTINF:-1` or omitted entirely) on a row
/// that is still a file, so it cannot carry the classification. A streaming
/// extension wins over a file one, since `.ts`/`.m3u8` are a live transport
/// even when the playlist nominally prefixes a positive duration; anything
/// else without a known file extension stays a channel.
@visibleForTesting
bool isM3uFileLocator(String locator) {
  final uri = Uri.tryParse(locator);
  final path = uri?.path ?? locator;
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  final ext = path.substring(dot + 1).toLowerCase();
  if (_m3uStreamFileExtensions.contains(ext)) return false;
  return _m3uMediaFileExtensions.contains(ext);
}

/// Best-effort run length from an `#EXTINF:<seconds>` prefix — **not** a
/// classifier (see [isM3uFileLocator]) but, when present, the VOD card's
/// runtime before the file is ever played. `-1`, absent, or non-positive all
/// mean "unknown" and yield null.
@visibleForTesting
int? extinfDurationSeconds(String line) {
  final m = RegExp(r'^#EXTINF:\s*(-?\d+(?:\.\d+)?)').firstMatch(line);
  if (m == null) return null;
  final value = double.tryParse(m.group(1)!);
  if (value == null || !value.isFinite || value <= 0) return null;
  return value.round();
}

/// Parses an extended M3U playlist. Public only for tests — production code
/// goes through [M3uSource], which runs this on a background isolate.
@visibleForTesting
M3uParsed parseM3uPlaylist(String content) {
  final channels = <Channel>[];
  final categoryTitles = <String>{};
  String? headerEpgUrl;
  CatchupCapability capability = CatchupCapability.unsupported;

  String? name, group, logo, tvgId, tvgChno;
  String? headerCatchupSource;
  var headerCatchupDays = 0;
  String? catchupSource;
  var catchupDays = 0;
  int? durationSeconds;
  var rejectedRows = 0;

  // VOD rows: a URL that points at a file (see [isM3uFileLocator]) becomes a
  // movie here, with its own group list — the live tab's category pane must
  // not show a group that only ever held files.
  final media = <MediaItem>[];
  final vodCategoryTitles = <String>{};

  for (final raw in const LineSplitter().convert(content)) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXTM3U')) {
      headerEpgUrl = _attr(line, 'url-tvg') ?? _attr(line, 'x-tvg-url');
      final catchup = _attr(line, 'catchup')?.toLowerCase();
      final days = int.tryParse(_attr(line, 'catchup-days') ?? '');
      headerCatchupSource = _attr(line, 'catchup-source');
      headerCatchupDays = days ?? 0;
      if (headerCatchupSource != null && catchup != 'none') {
        capability = CatchupCapability(
          mode: CatchupUrlMode.m3uTemplate,
          maxArchiveWindow: days == null ? null : Duration(days: days),
          template: headerCatchupSource,
        );
      }
      continue;
    }
    if (line.startsWith('#EXTINF')) {
      durationSeconds = extinfDurationSeconds(line);
      tvgId = _attr(line, 'tvg-id');
      tvgChno = _attr(line, 'tvg-chno');
      logo = _attr(line, 'tvg-logo');
      group = _attr(line, 'group-title');
      name = _name(line);
      final entryMode = _attr(line, 'catchup')?.toLowerCase();
      catchupSource = entryMode == 'none'
          ? null
          : (_attr(line, 'catchup-source') ?? headerCatchupSource);
      catchupDays =
          int.tryParse(_attr(line, 'catchup-days') ?? '') ?? headerCatchupDays;
      if (catchupSource != null) {
        final window = catchupDays > 0 ? Duration(days: catchupDays) : null;
        if (!capability.supported ||
            (window != null &&
                (capability.maxArchiveWindow == null ||
                    window > capability.maxArchiveWindow!))) {
          capability = CatchupCapability(
            mode: CatchupUrlMode.m3uTemplate,
            maxArchiveWindow: window,
            template: catchupSource,
          );
        }
      }
      continue;
    }
    if (line.startsWith('#')) continue; // other directives (#EXTVLCOPT etc.)

    // A URL line completes the pending entry. A URL pointing at a *file*
    // ([isM3uFileLocator]) plays as VOD and goes to the movies catalogue; a
    // stream URL stays a channel.
    if (name != null) {
      final g = (group == null || group.isEmpty) ? 'Uncategorized' : group;
      if (isM3uFileLocator(line)) {
        vodCategoryTitles.add(g);
        media.add(
          MediaItem(
            id: stableM3uMediaId(line),
            title: name,
            kind: ContentKind.movie,
            categoryId: g,
            poster: (logo != null && logo.isNotEmpty) ? logo : null,
            durationSeconds: durationSeconds,
            extra: {
              'url': line,
              if (tvgId != null && tvgId.isNotEmpty) 'tvgId': tvgId,
            },
          ),
        );
      } else {
        categoryTitles.add(g);
        channels.add(
          Channel(
            // The stream URL is the only per-entry unique key. tvg-id must NOT
            // be the id: playlists commonly reuse one tvg-id across quality
            // variants (HD/FHD/4K of the same channel), and the SQLite cache's
            // (source_id, id) primary key would silently drop all but one.
            // tvg-id stays in extra for the XMLTV EPG mapping.
            id: stableM3uChannelId(line),
            name: name,
            // tvg-chno is the playlist's own channel number; fall back to the
            // position when a provider omits it (most do), matching how the
            // network sources number from their own fields.
            number: int.tryParse(tvgChno ?? '') ?? channels.length + 1,
            logo: (logo != null && logo.isNotEmpty) ? logo : null,
            categoryId: g,
            archiveDays: catchupSource == null
                ? 0
                : (catchupDays > 0 ? catchupDays : kDefaultArchiveDays),
            extra: {
              'url': line,
              if (tvgId != null && tvgId.isNotEmpty) 'tvgId': tvgId,
              ...?catchupSource == null
                  ? null
                  : <String, dynamic>{'catchupSource': catchupSource},
            },
          ),
        );
      }
      name = group = logo = tvgId = catchupSource = null;
      catchupDays = 0;
      durationSeconds = null;
    }
  }
  if (name != null) rejectedRows++;

  final categories = (categoryTitles.toList()..sort())
      .map((t) => Category(id: t, title: t))
      .toList();
  final mediaCategories = vodCategoryTitles
      .map(
        (t) => MediaCategory(
          id: t,
          title: t,
          kind: ContentKind.movie,
        ),
      )
      .toList();
  return M3uParsed(
    channels,
    categories,
    headerEpgUrl,
    capability,
    rejectedRows,
    media,
    mediaCategories,
  );
}

String? _attr(String line, String key) =>
    RegExp('$key="([^"]*)"').firstMatch(line)?.group(1);

String _name(String extinf) {
  final lastQuote = extinf.lastIndexOf('"');
  final comma = extinf.indexOf(',', lastQuote == -1 ? 0 : lastQuote);
  return comma == -1 ? '' : extinf.substring(comma + 1).trim();
}

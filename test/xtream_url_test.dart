import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  // `AVPlayer` cannot play a naked continuous MPEG-TS stream, so the container
  // this source asks the panel for is what decides whether iOS live playback
  // lands on AVPlayer (real HDR, PiP, AirPlay) or on the permanently-SDR libmpv
  // fallback. See docs/ios.md "The `streamExtension` lever".
  group('resolveXtreamStreamExtension', () {
    test('defaults to ts off iOS and to m3u8 on iOS', () {
      expect(resolveXtreamStreamExtension(null, isIOS: false), 'ts');
      expect(resolveXtreamStreamExtension(null, isIOS: true), 'm3u8');
    });

    test('an explicit override wins on both platforms', () {
      // The escape hatch matters because a panel that does not serve the chosen
      // container answers 404 — and Dart's engineFailed fallback reopens the
      // *same* URL on mpv, so a wrong default is a dead channel, not a degraded
      // one.
      expect(resolveXtreamStreamExtension('ts', isIOS: true), 'ts');
      expect(resolveXtreamStreamExtension('m3u8', isIOS: false), 'm3u8');
      expect(resolveXtreamStreamExtension('  M3U8 ', isIOS: false), 'm3u8');
    });

    test('an unrecognised override falls back to the platform default', () {
      for (final bad in ['', '   ', 'mkv', '.ts', 'ts?x']) {
        expect(resolveXtreamStreamExtension(bad, isIOS: false), 'ts', reason: bad);
        expect(resolveXtreamStreamExtension(bad, isIOS: true), 'm3u8', reason: bad);
      }
    });
  });

  group('XtreamSource stream extension', () {
    // The suite runs on a desktop VM, so `Platform.isIOS` is false throughout:
    // these pin that the iOS default cannot leak into any other platform's URLs.
    test('live and timeshift URLs use ts by default off iOS', () async {
      final source = XtreamSource(
        sourceId: 'x',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
      );
      expect(source.streamExtension, 'ts');
      final live = await source.resolve(
        const Channel(id: '7', name: 'Ch', extra: {'streamId': '7'}),
      );
      expect(live.url, 'http://host.tv/live/u/p/7.ts');
      await source.dispose();
    });

    test('an explicit m3u8 reaches both the live and timeshift URLs', () async {
      final source = XtreamSource(
        sourceId: 'x',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
        streamExtension: 'm3u8',
      );
      final channel = const Channel(
        id: '7',
        name: 'Ch',
        extra: {'streamId': '7'},
      );
      final live = await source.resolve(channel);
      expect(live.url, 'http://host.tv/live/u/p/7.m3u8');

      final archive = await source.resolveArchive(
        channel,
        Programme(
          channelId: '7',
          title: 'Show',
          start: DateTime(2026, 7, 31, 20),
          stop: DateTime(2026, 7, 31, 21),
        ),
      );
      expect(archive.url, endsWith('/7.m3u8'));
      expect(archive.isLive, isFalse);
      await source.dispose();
    });

    test('the panel container_extension decides when nothing was chosen', () async {
      final source = XtreamSource(
        sourceId: 'x',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
      );
      // No per-source setting, so this is the automatic case.
      expect(source.streamExtensionOverride, isNull);
      const hls = Channel(
        id: '7',
        name: 'Ch',
        extra: {'streamId': '7', 'containerExtension': 'hls'},
      );
      expect(
        (await source.resolve(hls)).url,
        'http://host.tv/live/u/p/7.m3u8',
      );
      // ...and the archive leg follows the same channel, not a source-wide
      // default, or catch-up would ask for a container the stream is not in.
      final archive = await source.resolveArchive(
        hls,
        Programme(
          channelId: '7',
          title: 'Show',
          start: DateTime(2026, 7, 31, 20),
          stop: DateTime(2026, 7, 31, 21),
        ),
      );
      expect(archive.url, endsWith('/7.m3u8'));

      const ts = Channel(
        id: '8',
        name: 'Ch',
        extra: {'streamId': '8', 'containerExtension': 'mpegts'},
      );
      expect((await source.resolve(ts)).url, 'http://host.tv/live/u/p/8.ts');
      await source.dispose();
    });

    test('an absent or unservable container_extension keeps the old behaviour', () async {
      final source = XtreamSource(
        sourceId: 'x',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
      );
      // Absent, empty, and a container the live endpoint does not serve all
      // mean "ask what we were already asking for" — the panel naming mp4 is
      // not an instruction to request /live/….mp4.
      for (final ext in <String?>[null, '', 'mp4', 'mkv', 'weird']) {
        final live = await source.resolve(
          Channel(
            id: '7',
            name: 'Ch',
            extra: {'streamId': '7', 'containerExtension': ext},
          ),
        );
        expect(live.url, 'http://host.tv/live/u/p/7.ts', reason: '$ext');
      }
      await source.dispose();
    });

    test('an explicit choice outranks the panel', () async {
      // The escape hatch has to survive the automatic case, or a panel that
      // 404s on one container leaves no way back short of editing settings.
      final source = XtreamSource(
        sourceId: 'x',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
        streamExtension: 'ts',
      );
      expect(source.streamExtensionOverride, 'ts');
      final live = await source.resolve(
        const Channel(
          id: '7',
          name: 'Ch',
          extra: {'streamId': '7', 'containerExtension': 'hls'},
        ),
      );
      expect(live.url, 'http://host.tv/live/u/p/7.ts');
      await source.dispose();
    });

    test('an unrecognised setting is not a choice, so the panel decides', () {
      final source = XtreamSource(
        sourceId: 'x',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
        streamExtension: 'mp4',
      );
      // It still reads as the platform default, exactly as before, but it is
      // not recorded as a user preference — otherwise a stale settings blob
      // would silently pin every channel.
      expect(source.streamExtension, 'ts');
      expect(source.streamExtensionOverride, isNull);
      source.dispose();
    });

    test('mapLiveChannels keeps the panel container_extension', () {
      final channels = mapLiveChannels([
        {'stream_id': 1, 'name': 'A', 'container_extension': 'hls'},
        {'stream_id': 2, 'name': 'B'},
        {'stream_id': 3, 'name': 'C', 'container_extension': ''},
      ]);
      expect(channels[0].extra['containerExtension'], 'hls');
      // Absent stays absent rather than becoming an empty key, so the
      // resolver's "panel named nothing" branch is the one that runs.
      expect(channels[1].extra.containsKey('containerExtension'), isFalse);
      expect(channels[2].extra.containsKey('containerExtension'), isFalse);
    });

    test('SourceConfig plumbs the per-source settings override through', () {
      final source =
          const SourceConfig(
                id: 'x',
                kind: SourceKind.xtream,
                label: 'Panel',
                fields: {
                  'host': 'http://host.tv',
                  'username': 'u',
                  'password': 'p',
                },
                settings: {'streamExtension': 'm3u8'},
              ).build()
              as XtreamSource;
      expect(source.streamExtension, 'm3u8');
      source.dispose();
    });

    test('SourceConfig without the setting keeps the platform default', () {
      final source =
          const SourceConfig(
                id: 'x',
                kind: SourceKind.xtream,
                label: 'Panel',
                fields: {
                  'host': 'http://host.tv',
                  'username': 'u',
                  'password': 'p',
                },
              ).build()
              as XtreamSource;
      expect(source.streamExtension, 'ts');
      source.dispose();
    });
  });

  group('XtreamSource direct source URL', () {
    XtreamSource source({
      bool useDirectUrl = false,
      String? streamExtension,
    }) => XtreamSource(
      sourceId: 'x',
      host: 'http://host.tv',
      username: 'u',
      password: 'p',
      streamExtension: streamExtension,
      useDirectUrl: useDirectUrl,
    );

    const channel = Channel(
      id: '7',
      name: 'Ch',
      extra: {
        'streamId': '7',
        'directSource': 'http://cdn.tv/live/7/abc.m3u8?token=t1',
        'streamUrl': 'http://other.tv/7.ts',
      },
    );

    test('is off unless the setting says so', () async {
      // The default is the one that has to hold on every existing install:
      // a direct URL is whatever the reseller baked in at catalog-fetch time,
      // which on many panels is a CDN token that expires.
      final off = source();
      expect(
        (await off.resolve(channel)).url,
        'http://host.tv/live/u/p/7.ts',
      );
      await off.dispose();
    });

    test('uses the panel URL verbatim when on', () async {
      final on = source(useDirectUrl: true);
      final live = await on.resolve(channel);
      expect(live.url, 'http://cdn.tv/live/7/abc.m3u8?token=t1');
      expect(live.isLive, isTrue);
      await on.dispose();
    });

    test('direct_source wins over stream_url', () async {
      // Named "the source to use" rather than a second view of the same one,
      // so when a panel sends both and they disagree it is the one it means.
      final on = source(useDirectUrl: true);
      expect(
        on.directUrlFor({
          'directSource': 'http://a.tv/7.ts',
          'streamUrl': 'http://b.tv/7.ts',
        }),
        'http://a.tv/7.ts',
      );
      await on.dispose();
    });

    test('falls back to stream_url when there is no direct_source', () async {
      final on = source(useDirectUrl: true);
      expect(
        on.directUrlFor({'streamUrl': 'http://b.tv/7.m3u8'}),
        'http://b.tv/7.m3u8',
      );
      expect(on.directUrlFor(const {}), isNull);
      expect(on.directUrlFor({'streamUrl': ''}), isNull);
      await on.dispose();
    });

    test('a relative or schemeless address is refused, not repaired', () async {
      // Completing it against the panel host would invent a stream the user
      // never asked for, and a wrong one is a dead channel, not a degraded
      // one — so it falls back to the composed URL instead.
      final on = source(useDirectUrl: true);
      for (final bad in const [
        '',
        '   ',
        '/live/u/p/7.ts',
        'cdn.tv/live/7/7.ts',
      ]) {
        expect(on.directUrlFor({'directSource': bad}), isNull, reason: bad);
      }
      expect(
        (await on.resolve(const Channel(
          id: '7',
          name: 'Ch',
          extra: {'streamId': '7', 'directSource': 'cdn.tv/7.ts'},
        )))
            .url,
        'http://host.tv/live/u/p/7.ts',
      );
      await on.dispose();
    });

    test('an explicit stream format keeps composing the URL', () async {
      // The format tile is a request about the *composed* URL, so a
      // deliberate `.ts`/`.m3u8` choice must not be silently ignored.
      final on = source(useDirectUrl: true, streamExtension: 'm3u8');
      expect(
        (await on.resolve(channel)).url,
        'http://host.tv/live/u/p/7.m3u8',
      );
      await on.dispose();
    });

    test('catch-up is never taken direct', () async {
      // Timeshift is a panel-built path with no direct counterpart; a
      // direct_source from the catalog is a live address and would 404 here.
      final on = source(useDirectUrl: true);
      final archive = await on.resolveArchive(
        channel,
        Programme(
          channelId: '7',
          start: DateTime.utc(2026, 1, 1, 10),
          stop: DateTime.utc(2026, 1, 1, 11),
          title: 'P',
        ),
      );
      expect(archive.url, startsWith('http://host.tv/timeshift/u/p/60/'));
      expect(archive.isLive, isFalse);
      await on.dispose();
    });

    test('mapLiveChannels keeps the panel addresses', () {
      final channels = mapLiveChannels([
        {
          'stream_id': 1,
          'name': 'A',
          'direct_source': 'http://cdn.tv/1.m3u8',
          'stream_url': 'http://other.tv/1.ts',
        },
        {'stream_id': 2, 'name': 'B', 'stream_url': ''},
      ]);
      expect(channels[0].extra['directSource'], 'http://cdn.tv/1.m3u8');
      expect(channels[0].extra['streamUrl'], 'http://other.tv/1.ts');
      expect(channels[1].extra.containsKey('streamUrl'), isFalse);
      expect(channels[1].extra.containsKey('directSource'), isFalse);
    });

    test('SourceConfig turns it on only for an explicit true', () {
      XtreamSource build(Map<String, dynamic> settings) =>
          const SourceConfig(
            id: 'x',
            kind: SourceKind.xtream,
            label: 'Panel',
            fields: {
              'host': 'http://host.tv',
              'username': 'u',
              'password': 'p',
            },
            settings: {},
          ).copyWith(settings: settings).build() as XtreamSource;

      expect(build(const {'useDirectUrl': true}).useDirectUrl, isTrue);
      // `settings` is user-editable and rides the source row into the cloud,
      // so a truthy-looking string is not consent.
      for (final value in const <dynamic>['true', 1, 'yes', 'on', null]) {
        expect(
          build({'useDirectUrl': value}).useDirectUrl,
          isFalse,
          reason: '$value',
        );
      }
      expect(build(const {}).useDirectUrl, isFalse);
    });
  });

  group('xtreamCredentialsFromUrl', () {
    test('uses an M3U expiry hint when player API omits exp_date', () async {
      final source = XtreamSource(
        sourceId: 'test',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
        playlistExpiryHint: '2026-09-01T00:00:00.000',
        debugApi: (_) async => {
          'user_info': {'exp_date': '0'},
        },
      );
      expect((await source.subscriptionExpiry()).date, DateTime(2026, 9, 1));
      await source.dispose();
    });

    test('extracts creds from get.php query params', () {
      final c = xtreamCredentialsFromUrl(
        Uri.parse(
          'http://panel.example.com:8080/get.php?username=u1&password=p1&type=m3u_plus',
        ),
      );
      expect(c, isNotNull);
      expect(c!.host, 'http://panel.example.com:8080');
      expect(c.username, 'u1');
      expect(c.password, 'p1');
    });

    test('extracts creds from userInfo form', () {
      final c = xtreamCredentialsFromUrl(
        Uri.parse('http://u2:p2@host.tv/get.php'),
      );
      expect(c, isNotNull);
      expect(c!.host, 'http://host.tv');
      expect(c.username, 'u2');
      expect(c.password, 'p2');
    });

    test('returns null without credentials', () {
      expect(
        xtreamCredentialsFromUrl(Uri.parse('http://host.tv/list.m3u')),
        isNull,
      );
    });

    test('returns null for empty host', () {
      expect(
        xtreamCredentialsFromUrl(Uri.parse('?username=u&password=p')),
        isNull,
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/mpv_options.dart';

void main() {
  group('liveMpvOptionsForUrl', () {
    test('keeps the base map — and no reconnect_at_eof — for HLS', () {
      // An HLS manifest is a finite HTTP resource: `reconnect_at_eof` makes
      // ffmpeg reconnect at its EOF forever, so the demuxer probe never
      // completes and the stream never opens. This is the regression the
      // per-URL split exists to prevent.
      for (final url in <String>[
        'http://portal.example/live/u/p/123.m3u8',
        'https://portal.example/LIVE/U/P/123.M3U8?token=x',
        'http://portal.example/get.php?type=m3u8&id=7',
      ]) {
        final options = liveMpvOptionsForUrl(url);
        expect(options['stream-lavf-o'], kLiveStreamLavfO, reason: url);
        expect(
          options['stream-lavf-o'],
          isNot(contains('reconnect_at_eof')),
          reason: url,
        );
        expect(kLiveMpvOptions['stream-lavf-o'], kLiveStreamLavfO);
      }
    });

    test('adds reconnect_at_eof for a continuous live stream', () {
      for (final url in <String>[
        'http://portal.example/live/u/p/123.ts',
        'http://portal.example:8080/u/p/123',
        'rtp://239.0.0.1:1234',
      ]) {
        final options = liveMpvOptionsForUrl(url);
        expect(options['stream-lavf-o'], kLiveStreamLavfOAtEof, reason: url);
        expect(options['stream-lavf-o'], contains('reconnect_at_eof=1'));
        // The flags the engine already relied on must survive the edit.
        expect(options['stream-lavf-o'], contains('reconnect=1'));
        expect(options['stream-lavf-o'], contains('reconnect_streamed=1'));
        expect(options['stream-lavf-o'], contains('reconnect_delay_max=5'));
      }
    });

    test('changes only stream-lavf-o, never the rest of the tuning', () {
      final hls = liveMpvOptionsForUrl('http://x/1.m3u8');
      final ts = liveMpvOptionsForUrl('http://x/1.ts');
      expect(ts.keys.toSet(), hls.keys.toSet());
      for (final key in hls.keys) {
        if (key == 'stream-lavf-o') continue;
        expect(ts[key], hls[key], reason: key);
      }
      expect(ts['demuxer-lavf-o'], kLiveMpvOptions['demuxer-lavf-o']);
    });

    test('the base map is never mutated by a non-HLS lookup', () {
      final before = Map<String, String>.from(kLiveMpvOptions);
      liveMpvOptionsForUrl('http://x/1.ts');
      expect(kLiveMpvOptions, before);
      expect(kLiveMpvOptions.containsKey('stream-lavf-o'), isTrue);
      expect(
        kLiveMpvOptions['stream-lavf-o'],
        isNot(contains('reconnect_at_eof')),
      );
    });
  });

  group('liveStreamLavfOForUrl', () {
    test('matches the value embedded in liveMpvOptionsForUrl', () {
      for (final url in <String>['http://x/1.m3u8', 'http://x/1.ts']) {
        expect(
          liveMpvOptionsForUrl(url)['stream-lavf-o'],
          liveStreamLavfOForUrl(url),
        );
      }
    });

    test('at-EOF value is the base value plus the one flag', () {
      expect(kLiveStreamLavfOAtEof, '$kLiveStreamLavfO,reconnect_at_eof=1');
      expect(
        kLiveStreamLavfOAtEof.split(',').where((e) => e == 'reconnect=1'),
        hasLength(1),
        reason: 'duplicate flags make ffmpeg parsing order-dependent',
      );
    });
  });

  group('looksLikeHlsPlaylistUrl', () {
    test('is case-insensitive and needs only the extension', () {
      expect(looksLikeHlsPlaylistUrl('http://x/a.m3u8'), isTrue);
      expect(looksLikeHlsPlaylistUrl('HTTP://X/A.M3U8'), isTrue);
      expect(looksLikeHlsPlaylistUrl('http://x/a.ts'), isFalse);
      expect(looksLikeHlsPlaylistUrl('http://x/a'), isFalse);
    });
  });
}

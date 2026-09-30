import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/sources/source.dart';

Channel _channel(String id) => Channel(id: id, name: 'C $id', number: 1);

/// Pure-logic coverage for the live zap (PgDn/PgUp) cursor behind
/// `_ChannelListScreenState._resolveZapTarget`, plus the session-wide audio
/// state (`PlaybackAudioSession`) that keeps mute/lower volume across channel
/// swaps inside the fullscreen player (docs/player.md "Live zap").
void main() {
  final channels = [_channel('a'), _channel('b'), _channel('c')];

  group('liveZapIndex', () {
    test('Next wraps forward and Previous wraps backward', () {
      expect(liveZapIndex(channels, 'a', 1), 1);
      expect(liveZapIndex(channels, 'b', 1), 2);
      expect(liveZapIndex(channels, 'c', 1), 0);
      expect(liveZapIndex(channels, 'a', -1), 2);
      expect(liveZapIndex(channels, 'c', -1), 1);
    });

    test('a session with no current id starts from the ends, never a silent '
        'no-op', () {
      expect(liveZapIndex(channels, null, 1), 0);
      expect(liveZapIndex(channels, null, -1), 2);
    });

    test('a current id absent from the list (category switched) starts from '
        'the ends', () {
      expect(liveZapIndex(channels, 'zzz', 1), 0);
      expect(liveZapIndex(channels, 'zzz', -1), 2);
    });

    test('an empty list has nothing to zap to', () {
      expect(liveZapIndex(const <Channel>[], 'a', 1), -1);
      expect(liveZapIndex(const <Channel>[], null, -1), -1);
    });

    test('a single-channel list whose only channel is the current one is a '
        'no-op', () {
      final single = [_channel('solo')];
      expect(liveZapIndex(single, 'solo', 1), -1);
      expect(liveZapIndex(single, 'solo', -1), -1);
    });

    test('a single-channel list with no current id still steps into it', () {
      final single = [_channel('solo')];
      expect(liveZapIndex(single, null, 1), 0);
      expect(liveZapIndex(single, null, -1), 0);
    });
  });
}

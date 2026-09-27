import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_screen.dart';
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

  group('PlaybackAudioSession', () {
    test('a fresh session is at 100 and unmuted', () {
      final session = PlaybackAudioSession();
      expect(session.applied, 100);
      expect(session.muted, isFalse);
    });

    test('an engine-read mute records mute; a non-zero level unmutes and is '
        'remembered — the app\'s own unmute sends 100 explicitly via '
        'setVolume(100)', () {
      final session = PlaybackAudioSession()..record(0);
      expect(session.muted, isTrue);
      expect(session.applied, 0);
      // A non-zero report is both a level and an unmute (e.g. the Android
      // Activity's final volume after the native overlay set one).
      session.record(67);
      expect(session.muted, isFalse);
      expect(session.applied, 67);
    });

    test('a lowered (non-zero) volume is remembered across channels', () {
      final session = PlaybackAudioSession()..record(42);
      expect(session.applied, 42);
      expect(session.muted, isFalse);
    });

    test('volume reports stay within the engine\'s 0..100 idiom', () {
      final session = PlaybackAudioSession()
        ..record(0)
        ..record(100);
      expect(session.applied, 100);
      expect(session.muted, isFalse);
    });
  });
}
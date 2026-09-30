import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/playback_audio_session.dart';

/// Records what reached the engine, in order — a stub rather than a real
/// [Player] so the whole file stays a pure unit test with no media backend.
class _Engine {
  final List<double> writes = [];

  double get last => writes.last;
  Future<void> write(double volume) async => writes.add(volume);
}

void main() {
  group('the session starts unmuted and loud', () {
    test('a fresh session applies 100', () {
      final session = PlaybackAudioSession();
      expect(session.applied, 100);
      expect(session.muted, isFalse);
    });
  });

  group('record — a user gesture', () {
    test('a zero is the mute gesture', () {
      final session = PlaybackAudioSession()..record(0);
      expect(session.muted, isTrue);
      expect(session.applied, 0);
    });

    test('a non-zero is both a level and an unmute', () {
      // The Android Activity's final volume, and the Linux session's level, both
      // arrive this way.
      final session = PlaybackAudioSession()..record(0)..record(67);
      expect(session.muted, isFalse);
      expect(session.applied, 67);
    });
  });

  // ── The half that was never tested, and never wired ────────────────────────
  //
  // The session used to be declared and left dead: `record` and `apply` had no
  // callers outside this file, every surface toggled mute by reading the
  // engine's own volume, and the adopted preview engine was forced to a hard
  // 100. So fullscreen opened silent (the preview is muted by design and the
  // force-up only covered the adoption branch) and a mute the user had set was
  // gone by the next channel. These are the properties that had to hold.

  group('toggleMute', () {
    test('muting writes 0 and reports muted', () async {
      final session = PlaybackAudioSession();
      final engine = _Engine();
      expect(await session.toggleMute(engine.write), isTrue);
      expect(engine.last, 0);
      expect(session.muted, isTrue);
    });

    test('unmuting restores the remembered level, not 100', () async {
      // The load-bearing one. A user who turned the sound down to 20 and then
      // muted gets 20 back; the old `state.volume > 0 ? 0 : 100` gave them a
      // blaring 100.
      final session = PlaybackAudioSession()..record(20);
      final engine = _Engine();
      await session.toggleMute(engine.write);
      expect(engine.last, 0);
      expect(await session.toggleMute(engine.write), isFalse);
      expect(engine.last, 20);
    });

    test('unmuting from a fresh session is 100', () async {
      final session = PlaybackAudioSession();
      final engine = _Engine();
      await session.toggleMute(engine.write);
      await session.toggleMute(engine.write);
      expect(engine.last, 100);
    });

    test('a mute survives a full-screen open, which is the reported bug',
        () async {
      // Entering playback must not un-mute. This is the assertion the dead
      // session failed: the adopted preview engine arrives at 0, and the fix
      // hands back what the user asked for rather than a hard 100.
      final session = PlaybackAudioSession()..record(0);
      final engine = _Engine();
      await session.applyTo(engine.write);
      expect(engine.last, 0);
    });
  });

  group('setLevel', () {
    test('a non-zero level writes it and unmutes', () async {
      // Raising the volume on a muted player is how users un-mute without
      // hunting for the button, so a level is also an unmute.
      final session = PlaybackAudioSession()..record(0);
      final engine = _Engine();
      await session.setLevel(engine.write, 30);
      expect(engine.last, 30);
      expect(session.muted, isFalse);
    });

    test('a level is remembered across a channel change', () async {
      final session = PlaybackAudioSession();
      final engine = _Engine();
      await session.setLevel(engine.write, 42);
      // The next route builds a new engine at media_kit's default 100; without
      // applying the session the user's level would snap back.
      final next = _Engine();
      await session.applyTo(next.write);
      expect(next.last, 42);
    });
  });

  group('the preview and the teardown do not poison the session', () {
    test('a deliberate engine zero outside a gesture changes nothing',
        () async {
      // The preview writes 0 directly on every start and
      // `_prepareWindowsNativeExit` writes 0 on the way out. Neither goes
      // through the session, because neither is a user choice — and if they
      // did, the next fullscreen would open silent for a user who never muted.
      final session = PlaybackAudioSession()..record(70);
      final engine = _Engine();
      await engine.write(0);
      expect(session.muted, isFalse);
      expect(session.applied, 70);
    });
  });
}


import 'package:media_kit/media_kit.dart';

/// Writes a 0–100 volume to whatever is actually making sound — a media_kit
/// [Player], or the `EmbeddedControls` seam a surface drives.
///
/// **A function, not a [Player]**, so the session does not have to reach through
/// the overlay's `EmbeddedControls` abstraction to reach the engine behind it.
/// That abstraction deliberately hides the player so widget tests can supply a
/// stub; handing it a `Player` would have put a real engine back on every test
/// that touches a mute button.
typedef VolumeWriter = Future<void> Function(double volume);

/// Device-wide playback audio state (volume + the user's muted choice), shared
/// by every player route and by every surface that draws its own overlay —
/// the Flutter overlay, the Windows GDI overlay, the Linux Lua OSD, the Android
/// Compose overlay and the iOS one.
///
/// **Global by design**: a channel change tears down the previous playback —
/// each fresh route builds a new media_kit [Player] at default volume 100, and
/// the native surfaces are opened with whatever the last one ended on. Without
/// a session, muting and then zapping a channel un-mutes it, which is the one
/// surprise a user reliably reports as a bug.
///
/// **The session is the authority for *intents*, the engine for *reality*.**
///
/// The split is what makes the two places that write volume for their own
/// reasons safe. The live preview is **muted by design** — unprompted sound on
/// a television is a worse failure than a silent picture — and it writes 0
/// straight to the engine on every start. A session that mirrored the engine
/// would read that as the user having muted, and the next fullscreen would open
/// silent for a user who never asked for silence. So:
///
/// * **recording happens only at a user gesture** — [record] is called from a
///   mute toggle or a volume change the user made, never from a `volume` stream
///   listener. That is the whole reason there is no listener attached: a
///   listener would capture the preview's deliberate zero, and the deliberate
///   zero `_prepareWindowsNativeExit` writes on the way out, along with the
///   user's own choices — and there is no way to tell the two apart afterwards.
/// * **applying happens on every open** — [applyTo] on a fresh open and on an
///   adopted preview engine, so a mute survives a zap.
///
/// Lives in its own file rather than beside `PlayerScreen` because both
/// `player_screen.dart` and `player_overlay.dart` need it, and the latter is
/// imported by the former — declaring it there would be a cycle.
class PlaybackAudioSession {
  /// The user's audible volume, 0–100. 0 is only reached through [muted].
  double volume = 100;

  /// Whether the user has muted. Kept separate from [volume] so a 0 volume is
  /// recorded as the deliberate status it is, and so nothing silently undoes a
  /// mute when a level is re-applied.
  bool muted = false;

  /// The volume to hand to a player: 0 while muted, else [volume].
  double get applied => muted ? 0 : volume;

  /// Hands [applied] to [write]. Called on every open — fresh or adopted.
  Future<void> applyTo(VolumeWriter write) => write(applied);

  /// [applyTo] for the sites that hold a real [Player].
  Future<void> apply(Player player) => applyTo(player.setVolume);

  /// Mirrors a **user's** audible choice into the session. Callers are the mute
  /// toggles and the volume sliders/keys — never a stream listener. A zero is
  /// the mute gesture; a non-zero is both a level and an unmute.
  void record(double actual) {
    if (actual <= 0) {
      muted = true;
    } else {
      volume = actual;
      muted = false;
    }
  }

  /// The gesture a mute button, the `M` key and a native overlay's mute control
  /// all mean, in one place.
  ///
  /// Flips [muted] and writes [applied] — so **unmuting restores the level the
  /// user had**, not 100. Reading the engine's own volume and writing back
  /// `0 : 100` is what this replaces: on the native surfaces mpv's volume event
  /// lags or never arrives, so a toggle driven by that stale read re-mutes
  /// instead of restoring sound, and a level the user had deliberately lowered
  /// to 20 came back as a blaring 100.
  ///
  /// Returns the new [muted] for the caller's own indicator. The engine write
  /// deliberately does not re-derive [muted], because this is the intent being
  /// recorded, not a report of what arrived.
  Future<bool> toggleMute(VolumeWriter write) async {
    muted = !muted;
    await applyTo(write);
    return muted;
  }

  /// A level the user set by dragging a slider or pressing volume up/down.
  /// Routes through [record], so a non-zero level is also an unmute — raising
  /// the volume on a muted player is how users un-mute without hunting for the
  /// button.
  Future<void> setLevel(VolumeWriter write, double level) async {
    record(level);
    await applyTo(write);
  }
}

/// The single device-wide session (see [PlaybackAudioSession]).
final playbackAudioSession = PlaybackAudioSession();

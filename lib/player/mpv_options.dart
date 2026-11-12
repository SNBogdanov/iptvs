import 'dart:io' show Platform;

import 'package:media_kit/media_kit.dart';

/// Live-stream mpv network/demuxer tuning: no on-disk cache (IPTV streams don't
/// benefit from one, and it can fail on restricted temp/cache paths), a short
/// network timeout, and transparent reconnect on transient HTTP drops. Shared by
/// the fullscreen player and the live preview player so both get the same
/// resilience.
///
/// This base map deliberately has **no** `reconnect_at_eof`, because one value
/// cannot serve both live shapes:
///
/// - An HLS live stream's manifest is a *finite* HTTP resource, and with
///   `reconnect_at_eof` ffmpeg (verified on FFmpeg 8 / mpv 0.41) treats its EOF
///   as an error and reconnects forever, so the demuxer probe never completes
///   and the stream never opens at all.
/// - A raw MPEG-TS provider that closes the response at a chunk boundary looks
///   like a clean server-side end-of-stream. That surfaces as mpv `eof-reached`
///   (media_kit `completed=true` *and* `buffering=false`), which the
///   buffering-gated stall watchdog can't see. Without the flag every such chunk
///   costs a full re-open of the demuxer/decoder; with it ffmpeg reconnects
///   inside the same demuxer and playback is seamless.
///
/// Use [liveMpvOptionsForUrl] (or [liveStreamLavfOForUrl] for surfaces that set
/// options at open time, notably Android's `MpvController`) so the flag is added
/// for non-HLS URLs only. Every reopen path re-applies the URL-derived value:
/// a zap can move between an HLS channel and a TS one on the same player.
///
/// If the flag is absent the clean-EOF drop is still handled above the engine:
/// the embedded/Windows path treats a *live* `completed` as a drop and
/// reconnects (the `stream.completed` listener in `player_screen.dart`,
/// `shouldReconnectOnCompleted`), and the Linux-native path gets the equivalent
/// `end-file` eof/error drop over IPC (`LinuxNativePlaybackSignal.dropped`).
const Map<String, String> kLiveMpvOptions = {
  'cache-on-disk': 'no',
  'demuxer-max-back-bytes': '0',
  'network-timeout': '15',
  'stream-lavf-o': kLiveStreamLavfO,
  'demuxer-lavf-analyzeduration': '3',
  'demuxer-lavf-probesize': '10000000',
  'demuxer-lavf-o':
      'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
      'protocol_whitelist=[udp,rtp,tcp,tls,data,file,http,https,crypto],'
      'analyzeduration=3000000,probesize=10000000',
};

/// The `stream-lavf-o` value shared by every live shape: ffmpeg reconnects a
/// dropped connection instead of surfacing it as a playback error.
const String kLiveStreamLavfO =
    'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5';

/// [kLiveStreamLavfO] plus `reconnect_at_eof=1`, for live streams that are not
/// HLS (raw MPEG-TS and friends), whose provider closes and reopens the
/// response. Never use this for an HLS URL — see [kLiveMpvOptions].
const String kLiveStreamLavfOAtEof = '$kLiveStreamLavfO,reconnect_at_eof=1';

/// True when [url] names an HLS playlist rather than a continuous stream.
///
/// Mirrors `looksLikeHlsManifest` in `player_screen.dart`; the extension is the
/// only signal available before ffmpeg probes the body, and probing it first
/// would itself be the stall this distinction exists to avoid.
bool looksLikeHlsPlaylistUrl(String url) => url.toLowerCase().contains('m3u8');

/// The `stream-lavf-o` value for a live [url]: reconnects at EOF only for the
/// continuous (non-HLS) shape, where an EOF is a chunk boundary rather than the
/// manifest ending.
String liveStreamLavfOForUrl(String url) =>
    looksLikeHlsPlaylistUrl(url) ? kLiveStreamLavfO : kLiveStreamLavfOAtEof;

/// [kLiveMpvOptions] with `stream-lavf-o` resolved for [url]. HLS keeps the
/// base map; a continuous live stream gets [kLiveStreamLavfOAtEof].
Map<String, String> liveMpvOptionsForUrl(String url) {
  if (looksLikeHlsPlaylistUrl(url)) return kLiveMpvOptions;
  return {...kLiveMpvOptions, 'stream-lavf-o': liveStreamLavfOForUrl(url)};
}

/// mpv log filtering: keep mpv's own messages at their configured level, and
/// drop FFmpeg's to `error`.
///
/// At init media_kit calls `mpv_request_log_messages(ctx, 'warn')`
/// (`media_kit/lib/src/player/native/player/real.dart`), a **bare** level with
/// no module — which mpv reads as "warn and above for *every* module". That
/// includes FFmpeg's own diagnostics, which mpv routes under the `ffmpeg`
/// module, so an IPTV stream's provider-side problems print straight into the
/// console of whatever terminal launched the app: `mime type is not rfc8216
/// compliant` (the panel serving `.m3u8` under a non-HLS `Content-Type`),
/// `non-existing SPS 0 referenced in buffering period` (MPEG-TS carrying
/// parameter sets out of band), `PES packet size mismatch` / `Packet corrupt`
/// (a genuinely damaged transport stream), `Missing reference picture` and
/// `Increasing reorder buffer to 2`. None of it is actionable from here, and
/// none of it stops playback — it is provider quality, not an app fault.
///
/// `all=warn` is restated so the other half of the change is explicit: mpv's
/// *own* messages keep exactly the level they had, and this property is the
/// same mechanism as media_kit's `mpv_request_log_messages` call, so setting it
/// after init overrides it rather than adding to it.
///
/// **`ffmpeg=error` and not lower is load-bearing.** media_kit consumes
/// error-level log messages internally to populate its `errorController`, which
/// is what surfaces a playback failure to the error/reconnect path — silencing
/// the `ffmpeg` module below `error`, or `msg-level` globally, would silence the
/// very messages that drive recovery. This is also one notch deliberately
/// *higher* than the Android native fallback's `ffmpeg=fatal`
/// (`player/MpvController.kt`): a real decode failure prints at error
/// (`Failed setup for format d3d11: hwaccel initialisation returned error`,
/// `no frame!`) and is the one FFmpeg line worth seeing.
///
/// The app's own playback record is unaffected and remains the exportable
/// surface — this only quiets mpv's terminal output, which is console-only.
const Map<String, String> kMpvLogFilter = {
  'msg-level': 'all=warn,ffmpeg=error',
};

/// Tone-map-to-SDR options for **embedded** (non-native-surface) playback on
/// non-Windows platforms — notably Android, where the fallback/preview path
/// renders through a Flutter texture (which can't display HDR passthrough) rather
/// than the native HDR Activity.
///
/// Note: `hwdec` is deliberately **not** here — `media_kit_video`'s
/// [VideoController] sets `hwdec` itself at creation, overriding any value set
/// via `setProperty`, so decode mode must be chosen on the
/// [VideoControllerConfiguration] ([kAndroidPreviewHwdec], and
/// `embeddedHwdec()` off-Android) instead. Nor is
/// `hdr-compute-peak` — its per-frame GPU histogram is expensive and pointless
/// here (we tone-map to a fixed SDR target anyway).
///
/// "The controller default is `auto-safe`" is true of the **Android**
/// controller and false of the desktop one, which substitutes `auto`
/// (`native_video_controller/real.dart`). That difference is invisible from this
/// package and cost a real regression: reading it as a general default is what
/// left `hwdec: null` on the Windows fullscreen surface, which bought the
/// permissive zero-copy path and its green bottom band back. Anything leaving
/// `hwdec` unset on a surface is now a bug until proven otherwise.
const Map<String, String> kEmbeddedAndroidVideoOptions = {
  'target-prim': 'bt.709',
  'target-trc': 'bt.1886',
  'target-peak': '100',
  'tone-mapping': 'bt.2390',
};

/// Decode mode for the embedded Android preview, applied on the
/// [VideoController]'s configuration (the only place `hwdec` sticks — see
/// [kEmbeddedAndroidVideoOptions]). `mediacodec-copy` forces real hardware decode
/// on the device's codec and copies frames into the GL texture path, so it works
/// with `vo=gpu`. The controller default `auto-safe` silently falls back to
/// software on some weak TV boxes → 4K HEVC plays in slow-motion at ~100% CPU.
const String kAndroidPreviewHwdec = 'mediacodec-copy';

/// Applies [options] as mpv properties on [platform], warning via [onWarn]
/// (non-fatal — a single bad property shouldn't abort playback) instead of
/// throwing.
Future<void> applyMpvOptions(
  NativePlayer platform,
  Map<String, String> options, {
  void Function(String message)? onWarn,
}) async {
  for (final entry in options.entries) {
    try {
      await platform.setProperty(entry.key, entry.value);
    } catch (error) {
      onWarn?.call('mpv option ${entry.key} failed: $error');
    }
  }
}

/// The embedded-path video options for the current platform (empty on Windows,
/// which either uses the native HDR surface or, without one, needs no extra
/// tuning here).
Map<String, String> embeddedVideoOptionsForPlatform() => Platform.isWindows
    ? const <String, String>{}
    : kEmbeddedAndroidVideoOptions;

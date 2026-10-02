import 'dart:io' show File, Platform;

/// The `hwdec` policy for every **embedded** (texture) playback surface.
///
/// media_kit's desktop controller substitutes its own default when a caller
/// passes nothing — `hwdec: configuration.hwdec ?? 'auto'`
/// (`media_kit_video/native_video_controller/real.dart`) — and `auto` is the
/// permissive mode: it may select a zero-copy hardware path whose frames then
/// reach the renderer without a copy. `auto-safe` takes only the paths mpv
/// itself considers safe and falls back cleanly when none is available.
///
/// Every *other* playback path in this app already asks for `auto-safe` — the
/// native Windows D3D11 surface, the Linux native and embedded paths, the
/// Android engines — and the embedded Windows surface was the single holdout
/// left on media_kit's `auto`. A field report came out of exactly that
/// holdout: on some channels the picture was drawn a little short of the
/// texture it was being rendered into, leaving an unwritten band along the
/// bottom edge — green, i.e. chroma-plane bytes nobody rendered. It was
/// reported against the *complete* picture (nothing cropped, checked against a
/// working channel side by side), on the windowed preview and the fullscreen
/// surface alike, and in every aspect mode including Stretch, which rules the
/// `BoxFit` framing out: media_kit sizes the texture's host box from the
/// native texture rect and letterboxes the picture *inside* that rect
/// (`FittedBox` over a `SizedBox` of the reported size), so a band that shows
/// in Stretch is inside the texture, not beside it.
///
/// Mobile is deliberately untouched: the Android embedded controller derives
/// its own default from `enableHardwareAcceleration` and the decoders the
/// device reports, and the preview's forced `kAndroidPreviewHwdec` exists
/// precisely to counteract that. iOS reaches mpv only on the fallback engine,
/// where media_kit's own default is already the right one.
///
/// `IPTVS_HWDEC`, or a `hwdec_override.txt` marker file beside the executable
/// holding one `key=value` per line, overrides mpv's video pipeline for one run
/// (`hwdec=no`, `gpu-api=opengl`, `scale=box`, …) and is the *only* supported way
/// to A/B a decode/present path without shipping a build per arm. It separates
/// "the decoder produced the bad pixels" from "the frames were fine and the
/// present path lost the last band" — two problems with the same symptom and
/// opposite fixes. Unset (every normal launch) changes nothing, which is why it
/// is not a setting: it is a diagnostic, not a preference to persist per source
/// like `bufferPreset`.
///
/// **Every** embedded [VideoController] must ask through here, and the second
/// one to be missed is the one that bit: the report above covered the windowed
/// preview *and* the fullscreen surface, the policy was wired into the preview
/// first, and the fullscreen controller was left passing `hwdec: null` behind a
/// comment that promised to "match the proven Windows policy" while not doing so
/// — `Platform.isLinux ? 'auto-safe' : null` is `null` on the platform the band
/// was reported on. Null means media_kit's native controller substitutes `auto`
/// (`auto-safe` is the *Android* controller's default), so the band returned
/// for the one surface a user watches most. Reach for [embeddedHwdec] rather
/// than a literal, and treat an unset `hwdec` on any surface as a bug.
///
/// **Windows then needed the second half of the same fix: `auto-safe` is not
/// sufficient, because it does not exclude zero-copy.** A return of the identical
/// band on an install already carrying the `auto-safe` fix was bisected with the
/// override file above, one arm per launch, on a 1080p HEVC channel: `hwdec=no`
/// (software) clean, default `auto-safe` banded — and `auto-safe` had selected
/// `d3d11va`, so the "safe" list was never the thing keeping the frames
/// zero-copy-free. `hwdec=auto-copy` negotiated `d3d11va-copy` (`video format=nv12`,
/// hardware decode intact) and the band was gone. Hence Windows asks for
/// `auto-copy`, not `auto-safe`, and the two differ by exactly the copy mpv makes
/// when a surface cannot be handed over directly.
///
/// **Linux deliberately keeps `auto-safe`,** and this is not an oversight: its
/// embedded path renders through vaapi/drm where zero-copy is the whole point and
/// a forced copy would spend real memory bandwidth on a TV box for a defect
/// never reported there. The *native* Windows HWND surface also keeps
/// `auto-safe` (`player_screen.dart`'s `_configureNativePlayer`) — mpv owns both
/// ends of that context, so its zero-copy never crosses an interop boundary, and
/// forcing a copy there would tax the surface that exists for HDR throughput.
/// The defect is specific to *media_kit*'s texture surface on Windows.
///
/// The marker file rather than the variable alone because the environment
/// variable is easy to lose: it is inherited only by a process launched *from*
/// the shell that set it, so a double-click on the exe runs the default policy
/// and the A/B silently tests nothing — the failure mode being a "verified"
/// conclusion drawn from a run that never changed anything. Reading a file the
/// user can create in Explorer has neither problem.
String? embeddedHwdec() =>
    _overrides()['hwdec'] ??
    (Platform.isWindows
        ? 'auto-copy'
        : (Platform.isLinux ? 'auto-safe' : null));

/// Extra mpv properties for this run, from the same override source.
///
/// Deliberately not a settings surface: this exists so a rendering defect can be
/// bisected from the outside (`gpu-api=opengl`, `scale=box`, `cscale=…`) without
/// a rebuild and a retest cycle per arm — the alternative is guessing at a
/// libplacebo/D3D interop bug from a description, which is how three
/// wrong answers got here. `hwdec` is read separately because media_kit's
/// `VideoController` takes it at construction and overrides any `setProperty`.
Map<String, String> embeddedMpvOverrides() {
  final all = _overrides();
  return Map<String, String>.fromEntries(
    all.entries.where((e) => e.key != 'hwdec'),
  );
}

Map<String, String> _overrides() {
  final out = <String, String>{};
  final fromEnv = Platform.environment['IPTVS_HWDEC']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) out['hwdec'] = fromEnv;
  try {
    final dir = File(Platform.resolvedExecutable).parent;
    final marker = File(
      '${dir.path}${Platform.pathSeparator}hwdec_override.txt',
    );
    if (marker.existsSync()) {
      for (final line in marker.readAsLinesSync()) {
        final text = line.trim();
        if (text.isEmpty || text.startsWith('#')) continue;
        final eq = text.indexOf('=');
        if (eq <= 0) continue;
        final key = text.substring(0, eq).trim();
        final value = text.substring(eq + 1).trim();
        if (key.isNotEmpty && value.isNotEmpty) out[key] = value;
      }
    }
  } catch (_) {
    // A diagnostic aid is never worth failing playback over: an unreadable exe
    // path (some sandboxed hosts) just means no overrides this run.
  }
  return out;
}

/// One line naming every override in force, for the exportable log.
///
/// "Did my change take effect" has already cost this investigation two wrong
/// turns — a stale build, then an env var a double-click never inherited — and
/// both read as "the fix didn't help". The log says what mpv was actually told,
/// so the next report cannot be ambiguous on that point.
String embeddedOverrideSummary() {
  final all = _overrides();
  if (all.isEmpty) return 'none';
  return all.entries.map((e) => '${e.key}=${e.value}').join(' ');
}

package com.gchofficial.iptvs.player

/**
 * Network/demuxer tuning for live streams on the mpv fallback engine — the Kotlin
 * mirror of Dart's `kLiveMpvOptions` (`lib/player/mpv_options.dart`). Keep the two
 * in sync: they configure the same libmpv against the same providers.
 *
 * [STREAM_LAVF_O] deliberately omits `reconnect_at_eof`, because one value cannot
 * serve both live shapes:
 *
 * - An HLS live stream's manifest is a *finite* HTTP resource, and with that flag
 *   ffmpeg (verified on FFmpeg 8 / mpv 0.41) treats its EOF as an error and
 *   reconnects forever, so the demuxer probe never completes and the stream never
 *   opens at all.
 * - A raw MPEG-TS provider that closes each response at a chunk boundary looks
 *   like a clean end-of-stream. Without the flag every chunk surfaces as an mpv
 *   eof/error `end-file`, which [MpvController] relays to the host watchdog
 *   ([ReconnectPolicy]) as a drop and costs a full reload.
 *
 * Use [streamLavfO] at load time: it adds the flag for non-HLS URLs only. The URL
 * is not known when the engine is constructed (`create` runs before the first
 * `load`), and a zap can cross the two shapes on the same process, so
 * [MpvController.load] sets the property per file rather than once per engine.
 */
object MpvLiveOptions {
    /**
     * Bound stalls so the host watchdog reloads the source instead of hanging
     * forever on a dead connection.
     */
    const val NETWORK_TIMEOUT = "10"

    /**
     * Let ffmpeg transparently reconnect transient HTTP drops. Deliberately omits
     * `reconnect_at_eof` — see the object comment and [streamLavfO].
     */
    const val STREAM_LAVF_O = "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5"

    /**
     * [STREAM_LAVF_O] plus `reconnect_at_eof=1`: an EOF on a continuous live
     * stream is a chunk boundary ffmpeg should reconnect through, not the end of
     * the media. Never use this for an HLS URL.
     */
    const val STREAM_LAVF_O_AT_EOF = "$STREAM_LAVF_O,reconnect_at_eof=1"

    /** True when [url] names an HLS playlist rather than a continuous stream. */
    fun isHls(url: String): Boolean = url.contains("m3u8", ignoreCase = true)

    /** The `stream-lavf-o` value for a live [url] — see the object comment. */
    fun streamLavfO(url: String): String =
        if (isHls(url)) STREAM_LAVF_O else STREAM_LAVF_O_AT_EOF
}

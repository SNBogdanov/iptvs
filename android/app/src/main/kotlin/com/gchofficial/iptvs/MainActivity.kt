package com.gchofficial.iptvs

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.ConnectivityManager
import android.net.Uri
import android.util.Log
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.media3.common.util.UnstableApi
import com.gchofficial.iptvs.player.DebugCounters
import com.gchofficial.iptvs.player.AspectMode
import com.gchofficial.iptvs.player.isTelevisionDevice
import com.gchofficial.iptvs.player.BufferPreset
import com.gchofficial.iptvs.player.SharedEngine
import com.gchofficial.iptvs.player.StreamRoute
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI
import java.security.MessageDigest

@UnstableApi
class MainActivity : FlutterActivity() {
    private lateinit var nativeHdrChannel: MethodChannel
    private lateinit var previewChannel: MethodChannel
    private lateinit var updatesChannel: MethodChannel
    private lateinit var deviceChannel: MethodChannel
    private var pendingInstallPermissionResult: MethodChannel.Result? = null

    /**
     * Answers the `iptvs/device` channel's `isTelevision`, which two Dart
     * callers use: the pairing screen's suggested device label, and — since it
     * decides the *layout* — the wide/narrow choice resolved at boot
     * (`device_class.dart`, `isWideLayout`).
     *
     * Shared with `HdrPlayerActivity`'s ten-foot player chrome via
     * [isTelevisionDevice], deliberately: the two must never disagree about
     * what kind of device this is.
     */
    private fun isTelevision(): Boolean = isTelevisionDevice(this)

    /**
     * The system HTTP proxy, for Dart's HttpClient (which ignores it natively).
     *
     * Checked in three ways because OEMs disagree: the active network's
     * LinkProperties (the modern source), the JVM proxy properties some builds
     * mirror, and finally the default ProxySelector. Null means "direct".
     */
    private fun systemProxy(): Map<String, Any>? {
        try {
            val cm = getSystemService(ConnectivityManager::class.java)
            val network = cm?.activeNetwork
            if (cm != null && network != null) {
                val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    cm.getLinkProperties(network)?.httpProxy
                } else {
                    @Suppress("DEPRECATION")
                    cm.getDefaultProxy()
                }
                val host = info?.host
                val port = info?.port ?: -1
                if (!host.isNullOrBlank() && port > 0) {
                    return mapOf(
                        "host" to host,
                        "port" to port,
                        "type" to "HTTP",
                        // The per-network bypass list (`xl=*.site,37.1.194.25`
                        // in the field). Dart must honour it or it forces the
                        // very hosts the user excluded through the proxy.
                        "exclusions" to (info?.exclusionList ?: emptyList<String>()),
                    )
                }
            }
        } catch (_: Exception) {
        }
        val propertyHost = System.getProperty("https.proxyHost")
            ?: System.getProperty("http.proxyHost")
        val propertyPort = (System.getProperty("https.proxyPort")
            ?: System.getProperty("http.proxyPort"))?.toIntOrNull()
        if (!propertyHost.isNullOrBlank() && propertyPort != null && propertyPort > 0) {
            return mapOf("host" to propertyHost, "port" to propertyPort, "type" to "HTTP")
        }
        try {
            val proxy = ProxySelector.getDefault()
                ?.select(URI("https://example.com"))
                ?.firstOrNull()
            val address = proxy?.address()
            if (proxy != null && proxy != Proxy.NO_PROXY &&
                address is InetSocketAddress
            ) {
                return mapOf(
                    "host" to address.hostString,
                    "port" to address.port,
                    "type" to if (proxy.type() == Proxy.Type.SOCKS) "SOCKS" else "HTTP",
                )
            }
        } catch (_: Exception) {
        }
        return null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = WeakReference(this)
    }

    override fun onStop() {
        super.onStop()
        // Back-exit safety net: leaving the app must never strand the shared
        // preview engine playing audio behind the launcher. Dart also stops it
        // on lifecycle-pause, but the engine is process-global and outlives the
        // Flutter UI, so the finishing Activity enforces it too. Not adopted =
        // not owned by a fullscreen HdrPlayerActivity.
        if (isFinishing && !SharedEngine.adoptedByFullscreen) {
            SharedEngine.invalidate()
        }
    }

    override fun onDestroy() {
        if (instance?.get() === this) instance = null
        pendingInstallPermissionResult?.success(false)
        pendingInstallPermissionResult = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // The live preview's video surface (a TextureView the shared ExoPlayer
        // engine renders into) — embedded in the Flutter channel list.
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "iptvs/preview_view",
            PreviewViewFactory(),
        )

        // Drives the shared preview engine (see SharedEngine). Separate channel
        // from the fullscreen player's because each channel has one Dart-side
        // method-call handler, and PlayerScreen owns the other one.
        previewChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/native_preview",
        )
        previewChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "Missing stream URL", null)
                        return@setMethodCallHandler
                    }
                    val headers = (args["headers"] as? Map<*, *> ?: emptyMap<Any, Any>())
                        .entries.mapNotNull { entry ->
                            val key = entry.key as? String
                            if (key.isNullOrBlank()) null else key to entry.value.toString()
                        }.toMap()
                    SharedEngine.onPreviewError = { message ->
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "error", "message" to message),
                        )
                    }
                    SharedEngine.onPreviewUnsupported = {
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "unsupported"),
                        )
                    }
                    SharedEngine.onPreviewLost = { unsupported ->
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "lost", "unsupported" to unsupported),
                        )
                    }
                    SharedEngine.openPreview(
                        this,
                        url,
                        headers,
                        args["muted"] as? Boolean ?: true,
                        BufferPreset.fromName(args["bufferPreset"] as? String),
                        // Settings -> Proxy: the preview only ever plays live
                        // channels, so this is the Live switch's answer. Absent
                        // means direct.
                        StreamRoute.of(
                            args["proxyHost"] as? String,
                            (args["proxyPort"] as? Number)?.toInt() ?: 0,
                            args["proxyType"] as? String,
                        ),
                        // The framing this channel opens fullscreen in (a
                        // per-item pin, else the device-wide choice). Absent
                        // keeps the preview's default letterbox.
                        AspectMode.entries.firstOrNull {
                            it.label.equals(args?.get("aspect") as? String, true)
                        },
                    )
                    result.success(true)
                }

                // A framing chosen in the fullscreen player's aspect chip, or
                // the pin it wrote back, applied to the preview that is still
                // running underneath.
                "aspect" -> {
                    val args = call.arguments as? Map<*, *>
                    SharedEngine.setPreviewAspect(
                        AspectMode.entries.firstOrNull {
                            it.label.equals(args?.get("label") as? String, true)
                        },
                    )
                    result.success(true)
                }

                "play" -> {
                    SharedEngine.playPreview()
                    result.success(true)
                }

                "pause" -> {
                    SharedEngine.pausePreview()
                    result.success(true)
                }

                "setVolume" -> {
                    val args = call.arguments as? Map<*, *>
                    val volume = (args?.get("volume") as? Number)?.toFloat()
                    if (volume != null) SharedEngine.setPreviewVolume(volume.coerceIn(0f, 1f))
                    result.success(true)
                }

                "stop" -> {
                    SharedEngine.stopPreview()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        nativeHdrChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/native_hdr_player",
        )
        nativeHdrChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "Missing stream URL", null)
                        return@setMethodCallHandler
                    }

                    // A previous player that never finished — the field case
                    // was a dismissed PiP window that the OEM left merely
                    // stopped — still owns its engine (audio) and the Dart route
                    // that claimed this channel, so the new open would play into
                    // nothing. finish() reports its result, so the stale route
                    // pops before this one is pushed.
                    HdrPlayerActivity.instance?.get()?.let { previous ->
                        if (!previous.isFinishing && !previous.isDestroyed) {
                            Log.i("iptvs.native", "retiring previous player before a new open")
                            previous.finish()
                        }
                    }

                    val headers = args["headers"] as? Map<*, *> ?: emptyMap<Any, Any>()
                    val headerPairs = headers.entries.mapNotNull { entry ->
                        val key = entry.key as? String
                        if (key.isNullOrBlank()) null else key to entry.value.toString()
                    }
                    val subtitles = args["subtitles"] as? List<*> ?: emptyList<Any>()
                    val subtitleRows = subtitles.mapNotNull { entry ->
                        val map = entry as? Map<*, *> ?: return@mapNotNull null
                        val url = map["url"] as? String
                        if (url.isNullOrBlank()) {
                            null
                        } else {
                            Triple(
                                url,
                                map["label"]?.toString() ?: "",
                                map["language"]?.toString() ?: "",
                            )
                        }
                    }
                    fun epochMs(key: String): Long = (args[key] as? Number)?.toLong() ?: -1L
                    val intent = Intent(this, HdrPlayerActivity::class.java).apply {
                        putExtra(HdrPlayerActivity.EXTRA_URL, url)
                        putExtra(HdrPlayerActivity.EXTRA_TITLE, args["title"] as? String ?: "")
                        putExtra(HdrPlayerActivity.EXTRA_IS_LIVE, args["isLive"] as? Boolean ?: false)
                        // Seamless handoff: adopt the shared preview engine already
                        // playing this stream instead of reloading it.
                        putExtra(
                            HdrPlayerActivity.EXTRA_ADOPT_SHARED,
                            args["adoptShared"] as? Boolean ?: false,
                        )
                        // Per-source buffering. Without this the Activity reads
                        // a null extra and builds every fullscreen engine on
                        // NORMAL, so the setting only ever reached the preview.
                        putExtra(
                            HdrPlayerActivity.EXTRA_BUFFER_PRESET,
                            args["bufferPreset"] as? String,
                        )
                        putExtra(HdrPlayerActivity.EXTRA_ASPECT, args["aspect"] as? String)
                        putExtra(
                            HdrPlayerActivity.EXTRA_ASPECT_PINNED,
                            args["aspectPinned"] as? Boolean ?: false,
                        )
                        putExtra(
                            HdrPlayerActivity.EXTRA_GLOBAL_ASPECT,
                            args["globalAspect"] as? String ?: "",
                        )
                        putExtra(
                            HdrPlayerActivity.EXTRA_STEP_ENABLED,
                            args["stepEnabled"] as? Boolean ?: false,
                        )
                        // Session-wide audio (see Dart PlaybackAudioSession): the
                        // Activity opens a fresh audio session, so the user's
                        // volume/mute must ride along or every channel change
                        // returns to full volume. Absent → 1f (old callers).
                        putExtra(
                            HdrPlayerActivity.EXTRA_VOLUME,
                            ((args["volume"] as? Number)?.toFloat() ?: 1f)
                                .coerceIn(0f, 1f),
                        )
                        putExtra(
                            HdrPlayerActivity.EXTRA_MUTED,
                            args["muted"] as? Boolean
                                ?: (((args["volume"] as? Number)?.toFloat()
                                    ?: 1f) <= 0f),
                        )
                        putExtra(
                            HdrPlayerActivity.EXTRA_AUDIBLE_VOLUME,
                            ((args["audibleVolume"] as? Number)?.toFloat()
                                ?: 1f).coerceIn(0.1f, 1f),
                        )
                        // VOD resume point (ms), 0 = play from the top.
                        putExtra(
                            HdrPlayerActivity.EXTRA_RESUME_MS,
                            (args["resumeMs"] as? Number)?.toLong() ?: 0L,
                        )
                        // Favorite toggle (live channels): whether to show the
                        // star, and its seed state from the Dart favorites store.
                        putExtra(
                            HdrPlayerActivity.EXTRA_CAN_FAVORITE,
                            args["canFavorite"] as? Boolean ?: false,
                        )
                        putExtra(
                            HdrPlayerActivity.EXTRA_IS_FAVORITE,
                            args["isFavorite"] as? Boolean ?: false,
                        )
                        // Whether this route has a LiveZapController behind it.
                        // Constant for the life of the route, so it rides the
                        // open Intent rather than a live channel — the Android
                        // twin of the Windows overlay's `zapEnabled` key on
                        // setControlState. Fails closed: absent means no zap
                        // affordance, never a button that does nothing.
                        putExtra(
                            HdrPlayerActivity.EXTRA_ZAP_ENABLED,
                            args["zapEnabled"] as? Boolean ?: false,
                        )
                        // Device-wide chrome preferences (Settings → "Clock in the
                        // player" / "Playback time in the player"). Constant for the
                        // life of a route and constant for the process, so they ride
                        // the open Intent rather than a live channel. Fail **open**,
                        // the opposite of zapEnabled above: an absent key means an
                        // older Dart build, and the chrome it draws today is the
                        // chrome an untouched install should keep.
                        putExtra(
                            HdrPlayerActivity.EXTRA_SHOW_CLOCK,
                            args["showClock"] as? Boolean ?: true,
                        )
                        putExtra(
                            HdrPlayerActivity.EXTRA_SHOW_TIMES,
                            args["showPlaybackTimes"] as? Boolean ?: true,
                        )
                        // Settings → "Channel name in the player". Fail open like
                        // the two above: an older Dart build keeps the title.
                        putExtra(
                            HdrPlayerActivity.EXTRA_SHOW_CHANNEL_NAME,
                            args["showChannelName"] as? Boolean ?: true,
                        )
                        // Which optional controls the chrome draws (Settings →
                        // "Player controls"), as a comma list of wire names.
                        // Absent means "everything shown" — the same fail-open
                        // rule as the two preferences above.
                        putExtra(
                            HdrPlayerActivity.EXTRA_HIDDEN_CONTROLS,
                            args["hiddenControls"] as? String ?: "",
                        )
                        // What a double tap on the picture does. Absent reads as
                        // the default (previous/next) on the Activity side.
                        putExtra(
                            HdrPlayerActivity.EXTRA_DOUBLE_TAP,
                            args["doubleTap"] as? String ?: "",
                        )
                        // How far the ±seek buttons and a seek double tap move
                        // a title (Settings → "VOD seek step"). Absent keeps the
                        // Activity's own default of 10 s.
                        (args["seekStepSeconds"] as? Number)?.toInt()?.let {
                            putExtra(HdrPlayerActivity.EXTRA_SEEK_STEP, it)
                        }
                        (args["sourceName"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_SOURCE_NAME, it)
                        }
                        // Settings -> Proxy ("Streams: Live / Movies / Series"):
                        // the stream's own route, decided by Dart for this content
                        // kind. Absent = direct, the shape every build before the
                        // setting had; the Activity fails soft to direct for a
                        // half-filled address.
                        (args["proxyHost"] as? String)?.let { host ->
                            putExtra(HdrPlayerActivity.EXTRA_PROXY_HOST, host)
                            putExtra(
                                HdrPlayerActivity.EXTRA_PROXY_PORT,
                                (args["proxyPort"] as? Number)?.toInt() ?: 0,
                            )
                            putExtra(
                                HdrPlayerActivity.EXTRA_PROXY_TYPE,
                                args["proxyType"] as? String ?: "HTTP",
                            )
                        }
                        // Which side of the picture the volume swipe lives on.
                        // Without this the Activity always read its compiled-in
                        // default, so the Settings tile had no effect at all.
                        putExtra(
                            HdrPlayerActivity.EXTRA_VOLUME_SWIPE_ON_LEFT,
                            args["volumeSwipeOnLeft"] as? Boolean ?: true,
                        )
                        // Debug-only integration-test soak: lets a test cycle the
                        // native Activity unattended. Never read outside a debug
                        // build (see HdrPlayerActivity), so gate it here too rather
                        // than carry it onto a release-build intent for no reason.
                        if (BuildConfig.DEBUG) {
                            (args["soakAutoCloseMs"] as? Number)?.toLong()?.let {
                                putExtra(HdrPlayerActivity.EXTRA_SOAK_AUTOCLOSE_MS, it)
                            }
                        }
                        // Live EPG now/next snapshot (epoch ms passed as doubles).
                        (args["epgNowTitle"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_TITLE, it)
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_START, epochMs("epgNowStartMs"))
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_STOP, epochMs("epgNowStopMs"))
                            (args["epgNowDesc"] as? String)?.let { d ->
                                putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_DESC, d)
                            }
                        }
                        (args["epgNextTitle"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_TITLE, it)
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_START, epochMs("epgNextStartMs"))
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_STOP, epochMs("epgNextStopMs"))
                        }
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_HEADER_KEYS,
                            ArrayList(headerPairs.map { it.first }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_HEADER_VALUES,
                            ArrayList(headerPairs.map { it.second }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_URLS,
                            ArrayList(subtitleRows.map { it.first }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_LABELS,
                            ArrayList(subtitleRows.map { it.second }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_LANGUAGES,
                            ArrayList(subtitleRows.map { it.third }),
                        )
                    }
                    startActivityForResult(intent, REQUEST_NATIVE_PLAYER)
                    result.success(true)
                }

                // ── Live zapping (Dart → the running player Activity) ────
                //
                // Dart owns the channel list, the cursor and the resolve (see
                // `lib/player/live_zap_controller.dart`); these two are the
                // only things it asks the native side to *do*. The channel
                // handler has to live here — a MethodChannel is registered
                // once per process — so both forward to the live Activity,
                // the mirror of `logPlaybackDiagnostic` going the other way.
                //
                // Both are no-ops with no Activity up: a zap that arrives
                // after the player closed has nothing to apply, and answering
                // `false` rather than erroring keeps a late push off Dart's
                // error path.
                "zapTo" -> {
                    val args = call.arguments as? Map<*, *>
                    val player = HdrPlayerActivity.instance?.get()
                    if (args == null || player == null) {
                        result.success(mapOf("engineRebuilt" to false))
                    } else {
                        result.success(player.applyZap(args))
                    }
                }

                "setZapModes" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        val player = HdrPlayerActivity.instance?.get()
                        if (player != null) {
                            player.applyZapModes(args)
                        } else {
                            // The Activity is still starting (`startActivity` is
                            // asynchronous, `open` answers at once). Dropping
                            // this left the overlay's random/auto-switch buttons
                            // showing "off" on entry; keep it for `onCreate`.
                            HdrPlayerActivity.seedZapModes(
                                random = args["random"] as? Boolean,
                                autoSwitch = args["autoSwitch"] as? Boolean,
                                dwellSeconds = (args["dwellSeconds"] as? Number)?.toInt(),
                                dwellOptions = (args["dwellOptions"] as? List<*>)
                                    ?.mapNotNull { (it as? Number)?.toInt() }
                                    ?.filter { it > 0 },
                            )
                        }
                    }
                    result.success(true)
                }

                // The position the engine is at right now, for Dart's resume
                // store: a VOD step swaps the stream inside the session and the
                // outgoing title never sees `nativeClosed`.
                "playerPosition" -> {
                    val player = HdrPlayerActivity.instance?.get()
                    result.success(
                        player?.currentPlaybackPosition()
                            ?: mapOf("positionMs" to 0L, "durationMs" to 0L),
                    )
                }

                "setZapBanner" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        HdrPlayerActivity.instance?.get()?.applyZapBanner(args)
                    }
                    result.success(true)
                }

                // The quick list's row window, routed exactly like the banner
                // beside it. Every push is forwarded, including the closing
                // one: `open:false` is a tear-down instruction, not an
                // absence (`HdrPlayerActivity.applyQuickList`).
                "setQuickList" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        HdrPlayerActivity.instance?.get()?.applyQuickList(args)
                    }
                    result.success(true)
                }

                // Debug-only lifecycle counters for an integration-test soak
                // (see DebugCounters); empty map in a release build.
                "debugCounters" -> result.success(DebugCounters.snapshot())

                else -> result.notImplemented()
            }
        }

        // Device form factor, read once while pairing so the device can suggest
        // its own name ("Android TV" vs "Android") to the web panel. Outbound
        // only — Dart never registers a handler here, so this is not a
        // ChannelHandlerOwner case.
        deviceChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/device",
        )
        deviceChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isTelevision" -> result.success(isTelevision())
                // A stable id for the per-device settings backup. Android ID is
                // stable per app-signing key and user, so it survives a
                // reinstall; Dart hashes it before it ever leaves the device.
                "stableDeviceId" -> result.success(
                    Settings.Secure.getString(
                        contentResolver,
                        Settings.Secure.ANDROID_ID,
                    ),
                )
                // Dart's `HttpClient` does not read Android's system proxy on
                // its own, so image/API requests bypassed a user-configured
                // proxy while native players honoured it. Dart installs an
                // `HttpOverrides` from this answer at boot.
                "proxy" -> result.success(systemProxy())
                else -> result.notImplemented()
            }
        }

        // In-app update: launches the system package installer for a
        // downloaded release APK, and the "install unknown apps" settings.
        updatesChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/updates",
        )
        updatesChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = (call.arguments as? Map<*, *>)?.get("path") as? String
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "Missing APK path", null)
                        return@setMethodCallHandler
                    }
                    val apk = File(path)
                    try {
                        verifyUpdateApk(apk)
                    } catch (e: SecurityException) {
                        result.error("invalid_update", e.message, null)
                        return@setMethodCallHandler
                    }
                    // minSdk 26 → canRequestPackageInstalls() always applies.
                    if (!packageManager.canRequestPackageInstalls()) {
                        result.success("needs_permission")
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            apk,
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_ACTIVITY_NEW_TASK,
                            )
                        }
                        startActivity(intent)
                        result.success("launched")
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }

                "requestInstallPermission" -> {
                    if (pendingInstallPermissionResult != null) {
                        result.error("settings_active", "Install settings are already open", null)
                        return@setMethodCallHandler
                    }
                    try {
                        pendingInstallPermissionResult = result
                        startActivityForResult(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                            REQUEST_INSTALL_PERMISSION,
                        )
                    } catch (e: Exception) {
                        pendingInstallPermissionResult = null
                        result.error("settings_failed", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Asks the Dart player route for a freshly resolved live locator and hands
     * the raw reply to [onReply] — `{url, headers}` on success, **null** for
     * every failure shape (no channel yet, no/superseded Dart handler, an
     * unmounted route, a platform error, `notImplemented`). The caller decides
     * the fallback; see [com.gchofficial.iptvs.player.ResolveAgainReply].
     *
     * Exists because [HdrPlayerActivity] is a separate Activity with no Flutter
     * engine of its own: this MethodChannel lives here, and both Activities run
     * on the same process main thread, which is where MethodChannel calls and
     * their replies must happen.
     *
     * The reply is never logged: a Dart-side resolve error message can embed
     * the provider URL, and therefore credentials.
     */
    fun requestFreshLiveLocator(onReply: (Any?) -> Unit) {
        if (!::nativeHdrChannel.isInitialized) {
            onReply(null)
            return
        }
        nativeHdrChannel.invokeMethod(
            "resolveAgain",
            null,
            object : MethodChannel.Result {
                override fun success(result: Any?) = onReply(result)

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                    onReply(null)

                override fun notImplemented() = onReply(null)
            },
        )
    }

    /**
     * Relays a short, credential-free note from [HdrPlayerActivity] into Dart's
     * exportable diagnostics log (`playback` scope).
     *
     * The seamless preview→fullscreen handoff either adopts the shared engine or
     * silently reloads the stream, and until now that outcome existed only in
     * logcat — unreachable for a user reporting "it reconnects when I go
     * fullscreen" from a TV. Dart already logs which handoff it *asked* for
     * (`fullscreen open decision=…`); this is the other half, what the Activity
     * actually did. Fire-and-forget: a missing channel or handler is not worth
     * reacting to.
     *
     * **Never pass anything derived from a URL, header or provider reply** —
     * this text is exported verbatim.
     */
    /**
     * Inbound half of the zap wire contract: one member of the shared command
     * vocabulary (`lib/player/zap_command.dart`), sent by
     * [HdrPlayerActivity]'s key policy.
     *
     * Fire-and-forget by design — the native side names a *command*, never a
     * channel, and holds no cursor to reconcile against a reply.
     */
    fun requestZap(command: String) {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod("nativeZap", mapOf("command" to command))
    }

    fun logPlaybackDiagnostic(note: String) {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod("nativeDiagnostic", mapOf("note" to note))
    }

    /**
     * Reports an aspect choice made in the player's own overlay.
     *
     * Dart owns the label sequence every `zapTo` payload carries, so without
     * this the next channel change re-sent the framing Dart last heard about —
     * at launch — and the picture snapped back after every zap. Fire-and-forget:
     * a missing handler just leaves `RESULT_ASPECT` as the only report, which is
     * the behaviour before this call existed.
     */
    fun reportAspect(label: String) {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod("nativeAspect", mapOf("label" to label))
    }

    /**
     * Live audio level/mute report from the native player (the mute button),
     * so Dart's session is right even if the process dies before `finish`.
     */
    fun reportVolume(volume: Float, muted: Boolean) {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod(
            "nativeVolume",
            mapOf("volume" to volume.toDouble(), "muted" to muted),
        )
    }

    /** The long-press menu pinned [label] to the channel on screen. */
    fun reportAspectPin(label: String) {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod("nativeAspectPin", mapOf("label" to label))
    }

    /** The long-press menu's "Use global": drop the channel's pin. */
    fun reportAspectGlobal() {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod("nativeAspectGlobal", null)
    }

    /**
     * Fails closed unless [apk] is a cache-owned APK for this exact application
     * and is signed by the same certificate as the installed build. Dart has
     * already verified the signed release-manifest digest; this native check
     * prevents a wrong-package or wrong-signer APK reaching Package Installer.
     */
    @Suppress("DEPRECATION")
    private fun verifyUpdateApk(apk: File) {
        val cachePath = cacheDir.canonicalFile.toPath()
        val apkPath = apk.canonicalFile.toPath()
        if (!apk.isFile || !apkPath.startsWith(cachePath)) {
            throw SecurityException("Update APK is outside the application cache")
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val candidate = packageManager.getPackageArchiveInfo(apkPath.toString(), flags)
            ?: throw SecurityException("Update APK package metadata is unreadable")
        if (candidate.packageName != packageName) {
            throw SecurityException("Update APK package identity does not match")
        }
        val installed = packageManager.getPackageInfo(packageName, flags)
        val candidateSigners = signerDigests(candidate)
        val installedSigners = signerDigests(installed)
        if (candidateSigners.isEmpty() || candidateSigners != installedSigners) {
            throw SecurityException("Update APK signing certificate does not match")
        }
    }

    @Suppress("DEPRECATION")
    private fun signerDigests(info: PackageInfo): Set<String> {
        val signatures: Array<Signature> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners ?: emptyArray()
        } else {
            info.signatures ?: emptyArray()
        }
        return signatures.mapTo(mutableSetOf()) { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString(separator = "") { byte ->
                    (byte.toInt() and 0xff).toString(16).padStart(2, '0')
                }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_INSTALL_PERMISSION) {
            pendingInstallPermissionResult?.success(packageManager.canRequestPackageInstalls())
            pendingInstallPermissionResult = null
            return
        }
        if (requestCode == REQUEST_NATIVE_PLAYER && ::nativeHdrChannel.isInitialized) {
            // Relay the final VOD position (see HdrPlayerActivity.finish) so the
            // Dart side can persist the resume point, plus the final favorite
            // state so the channel list reflects an in-player toggle on return.
            // Null args = live with no favorite change / legacy.
            val positionMs = data?.getLongExtra(HdrPlayerActivity.RESULT_POSITION_MS, -1L) ?: -1L
            val durationMs = data?.getLongExtra(HdrPlayerActivity.RESULT_DURATION_MS, -1L) ?: -1L
            val map = buildMap<String, Any> {
                if (positionMs >= 0L && durationMs > 0L) {
                    put("positionMs", positionMs)
                    put("durationMs", durationMs)
                }
                data?.takeIf { it.hasExtra(HdrPlayerActivity.RESULT_FAVORITE) }?.let { result ->
                    put("favorite", result.getBooleanExtra(HdrPlayerActivity.RESULT_FAVORITE, false))
                }
                data?.getStringExtra(HdrPlayerActivity.RESULT_ASPECT)?.let {
                    put("aspect", it)
                }
                data?.takeIf { it.hasExtra(HdrPlayerActivity.RESULT_VOLUME) }?.let {
                    put("volume", it.getFloatExtra(HdrPlayerActivity.RESULT_VOLUME, 1f))
                }
                data?.takeIf { it.hasExtra(HdrPlayerActivity.RESULT_MUTED) }?.let {
                    put("muted", it.getBooleanExtra(HdrPlayerActivity.RESULT_MUTED, false))
                }
            }
            nativeHdrChannel.invokeMethod("nativeClosed", if (map.isEmpty()) null else map)
        }
    }

    companion object {
        /**
         * Set while a MainActivity exists. Lets [HdrPlayerActivity] move the
         * *main* task behind its PiP window (once an Activity enters PiP it lives
         * in its own pinned task, so it can't move this one from there).
         */
        var instance: WeakReference<MainActivity>? = null
            private set

        private const val REQUEST_NATIVE_PLAYER = 4120
        private const val REQUEST_INSTALL_PERMISSION = 4121
    }
}

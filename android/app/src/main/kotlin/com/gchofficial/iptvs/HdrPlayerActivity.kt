package com.gchofficial.iptvs

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.util.Rational
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.util.UnstableApi
import com.gchofficial.iptvs.player.AspectMode
import com.gchofficial.iptvs.player.isTelevisionDevice
import com.gchofficial.iptvs.player.DebugCounters
import com.gchofficial.iptvs.player.DoubleTapAction
import com.gchofficial.iptvs.player.BufferPreset
import com.gchofficial.iptvs.player.ExoPlayerEngine
import com.gchofficial.iptvs.player.FrameLivenessWatch
import com.gchofficial.iptvs.player.LiveLocator
import com.gchofficial.iptvs.player.MpvEngine
import com.gchofficial.iptvs.player.PlaybackEngine
import com.gchofficial.iptvs.player.PlaybackStatsSampler
import com.gchofficial.iptvs.player.PlayerCallbacks
import com.gchofficial.iptvs.player.PlayerBackAction
import com.gchofficial.iptvs.player.PlayerBackGuard
import com.gchofficial.iptvs.player.PlayerMenu
import com.gchofficial.iptvs.player.PlayerOrientation
import com.gchofficial.iptvs.player.StreamRoute
import com.gchofficial.iptvs.player.SwipeLevel
import com.gchofficial.iptvs.player.PlayerScreen
import com.gchofficial.iptvs.player.PlayerUiState
import com.gchofficial.iptvs.player.QuickListState
import com.gchofficial.iptvs.player.ReconnectPolicy
import com.gchofficial.iptvs.player.ResolveAgainReply
import com.gchofficial.iptvs.player.ResolveGate
import com.gchofficial.iptvs.player.SharedEngine
import com.gchofficial.iptvs.player.SubtitleSpec
import com.gchofficial.iptvs.player.ZapKeyPolicy
import com.gchofficial.iptvs.player.ZapKeyAction
import com.gchofficial.iptvs.player.nextPlayerBackAction
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.lang.ref.WeakReference

/**
 * Native HDR player. Hosts a [PlaybackEngine] behind the Jetpack Compose control
 * overlay ([PlayerScreen]). Starts on [ExoPlayerEngine] (MediaCodec hardware decode
 * → true HDR); if ExoPlayer can't decode the video track (e.g. Dolby Vision
 * Profile 5 on non-DV hardware) it falls back once to [MpvEngine] (libmpv, which
 * software-reshapes DV and tone-maps). The engine swap is device-aware: on
 * DV-capable hardware ExoPlayer handles everything and the fallback never fires.
 */
@UnstableApi
class HdrPlayerActivity : ComponentActivity() {
    private lateinit var uiState: PlayerUiState
    private lateinit var url: String
    private lateinit var headers: Map<String, String>
    private lateinit var subtitles: List<SubtitleSpec>

    private val engineState = mutableStateOf<PlaybackEngine?>(null)
    private var engine: PlaybackEngine? = null
    private var progressTicker: Job? = null

    // Debug-only: lets an integration-test soak cycle this Activity without a
    // human closing it each time. Inert (never scheduled) outside BuildConfig.DEBUG.
    private var soakAutoCloseJob: Job? = null

    // True while this Activity plays through the *adopted* shared preview engine
    // (see [SharedEngine]): it never releases that engine — on exit it hands the
    // video output back to the preview instead.
    private var adoptedShared = false

    // Live reconnect watchdog: when a live stream stalls (buffering) or drops
    // (ended / error), reload it with capped backoff until playback resumes.
    private var stalledSinceMs = 0L
    private var lastReconnectMs = 0L
    private var reconnectAttempt = 0

    // The third stall shape, and the one that used to be invisible: playing
    // normally by every flag the engine exposes, with nothing reaching the
    // screen. See [FrameLivenessWatch].
    private val frameLiveness = FrameLivenessWatch()

    // Cheap recoveries spent on this session's handoff. One is the budget: if a
    // fresh decoder on the same surface still draws nothing, the surface switch
    // wasn't the problem and the reload watchdog owns it from there.
    private var handoffRebuilds = 0

    // Why the current reconnect fired, for the diagnostics line. Set at the
    // point of decision so the log distinguishes an underrun from a drop from
    // a frozen renderer, which otherwise all read as "reconnect attempt=1".
    private var stallKind = "none"

    // Wall clock for this Activity's own timeline: every diagnostic it emits is
    // stamped with ms since onCreate, so a report shows where in the handoff the
    // time went instead of only that it went.
    private var startedAtMs = 0L

    // Live re-resolve round trip (see [withFreshLiveLocator]). The gate keeps
    // the watchdog and "Go to live" to one in-flight `create_link` between them
    // and settles the reply-vs-timeout race exactly once.
    private val resolveGate = ResolveGate()
    private var resolveTimeoutJob: Job? = null

    // The buffering preset the current engine was built with. Read from the
    // launch Intent and then **kept in a field**, because an in-player zap can
    // change it: `LoadControl` is a build-time argument, so a changed preset
    // rebuilds the engine exactly as changed headers do (the rule
    // `SharedEngine.openPreview` already applies to the preview).
    private var bufferPreset: BufferPreset = BufferPreset.NORMAL

    // Live zapping (Dart owns the channel list and the cursor — see
    // `lib/player/live_zap_controller.dart`). The Activity holds only what a
    // *synchronous* key decision needs.
    //
    // `zapConsumedKeyCode` pairs a consumed ACTION_UP with the ACTION_DOWN
    // that claimed it: the state the policy reads (a half-typed number) can
    // change between the two, and a bare key-up reaching a focused Compose
    // control would activate it right after the down had already been used
    // for something else.
    private var zapConsumedKeyCode: Int? = null

    // Optimistic mirror of "a channel number is half-typed".
    //
    // The authoritative buffer is Dart's and arrives back on `setZapBanner`,
    // but that is a frame or two away, and OK or Back pressed inside that
    // window would otherwise fall through to the overlay — on a remote, a
    // fast "1 OK" is the normal way to enter a single-digit channel. Set when
    // a digit is dispatched and replaced wholesale by the next authoritative
    // push, so it can only ever be early, never stale.
    private var zapDigitsPendingOptimistic = false

    // Optimistic mirror of "the quick list is on screen", the same shape and
    // for the same synchronous reason as the digit mirror above: the
    // authoritative answer arrives on `setQuickList` a frame or two after the
    // key that asked for it, and the *next* key's meaning turns on it (Left
    // opens the list, then Left ascends its mode stack). Only the two
    // unambiguous commands move it — open and close. `zap:back` and
    // `zap:activate` deliberately do not, because whether either of those
    // closes the list is a question about a mode stack only Dart holds.
    // Replaced wholesale by the next push, so it can only ever be early.
    private var zapQuickListOpenOptimistic = false

    /**
     * Whether the viewer picked a framing in this session (the aspect chip in
     * the control row).
     *
     * A zap payload carries the `aspect` Dart held at launch, so re-applying it
     * on every channel change reverted a choice made after the player opened —
     * the reported "масштаб слетает при переключении каналов". The local choice
     * wins for the rest of the session; Dart still receives it through
     * `reportAspect` on each cycle and through RESULT_ASPECT on exit.
     */
    /** Whether the framing shown is this channel's pin (set from the menu). */
    private var aspectPinned = false

    /** The device-wide mode, applied by the menu's "Use global". */
    private var globalAspectLabel: String = AspectMode.Fill.label

    // When Dart last reported a zap resolve in flight (`setZapBanner`'s
    // `settling`). While one is, the reconnect watchdog stands down: the
    // stream it would be reconnecting is one Dart is deliberately replacing.
    // Bounded by ResolveGate.TIMEOUT_MS so a banner whose follow-up never
    // arrives cannot wedge the watchdog for the rest of the session.
    private var zapSettlingSinceMs = 0L
    private val backGuard = PlayerBackGuard()
    // Entering PiP moves MainActivity's task behind the launcher so the pinned
    // window is unobstructed.  When the restored player is then closed, the
    // player task would otherwise finish into the launcher instead of the
    // Flutter streams route.  Remember that this Activity has used PiP so its
    // finish path can restore the existing MainActivity task first.
    private var enteredPip = false

    /**
     * TV remotes and three-button navigation arrive as key events. Consume both
     * key-down and key-up at the Activity boundary so Compose focus handlers and
     * the Back dispatcher cannot process the same physical press again.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (dispatchZapKey(event)) return true
        if (event.keyCode != KeyEvent.KEYCODE_BACK) return super.dispatchKeyEvent(event)
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            handleSystemBack()
        }
        return true
    }

    /**
     * Live zapping's share of the key stream, decided by the pure
     * [ZapKeyPolicy] at this same Activity boundary Back already uses — one
     * physical press must not be read once here and again by a focused
     * Compose control.
     *
     * Returns whether the press was consumed. Only the key-down sends a
     * command; its key-up is consumed by code so nothing downstream ever sees
     * half a press.
     */
    private fun dispatchZapKey(event: KeyEvent): Boolean {
        if (!::uiState.isInitialized) return false
        if (event.action == KeyEvent.ACTION_UP) {
            if (zapConsumedKeyCode != event.keyCode) return false
            zapConsumedKeyCode = null
            return true
        }
        if (event.action != KeyEvent.ACTION_DOWN) return false
        val decision = ZapKeyPolicy.decide(
            keyCode = event.keyCode,
            isLive = uiState.isLive,
            controlsVisible = uiState.controlsVisible,
            digitsPending = uiState.digitBuffer.isNotEmpty() || zapDigitsPendingOptimistic,
            isRepeat = event.repeatCount > 0,
            quickListOpen = quickListOpen(),
        )
        if (!decision.consumed) return false
        zapConsumedKeyCode = event.keyCode
        // A digit keeps the banner up while the number is being typed; the
        // authoritative buffer still comes back from Dart on `setZapBanner`,
        // which is what the next key decision reads.
        if (decision.action == ZapKeyAction.Digit) {
            zapDigitsPendingOptimistic = true
            uiState.zapBannerVisible = true
        } else if (decision.action == ZapKeyAction.Activate ||
            decision.action == ZapKeyAction.Back
        ) {
            zapDigitsPendingOptimistic = false
        }
        if (decision.action == ZapKeyAction.OpenList) {
            zapQuickListOpenOptimistic = true
        } else if (decision.action == ZapKeyAction.CloseList) {
            zapQuickListOpenOptimistic = false
        }
        decision.command?.let { sendZap(it) }
        return true
    }

    /**
     * Whether the quick list should be treated as open *right now* — Dart's
     * last push, or the optimistic mirror while its answer is in the air.
     */
    private fun quickListOpen(): Boolean =
        (::uiState.isInitialized && uiState.quickList.open) || zapQuickListOpenOptimistic

    /** Outbound half of the zap wire contract (see `MainActivity.requestZap`). */
    private fun sendZap(command: String) {
        MainActivity.instance?.get()?.requestZap(command)
    }

    /** One press closes one layer: menu, info, controls, then Activity. */
    private fun handleSystemBack() {
        if (!backGuard.shouldHandle(SystemClock.elapsedRealtime())) return
        if (!::uiState.isInitialized) {
            finish()
            return
        }
        when (
            nextPlayerBackAction(
                menuOpen = uiState.openMenu != PlayerMenu.None,
                infoOpen = uiState.infoOpen,
                controlsVisible = uiState.controlsVisible,
                quickListOpen = quickListOpen(),
                dwellMenuOpen = uiState.dwellMenuOpen,
            )
        ) {
            // The list's rungs are Dart's mode stack, not a layer this side
            // can close. Only the *gesture* Back path reaches this: a key Back
            // was already claimed by ZapKeyPolicy and sent the same command,
            // which is why one press can never peel two rungs.
            PlayerBackAction.QuickListBack -> sendZap("zap:back")
            PlayerBackAction.CloseMenu -> {
                uiState.openMenu = PlayerMenu.None
                // One rung, two menus: the pace menu is drawn like the track
                // menus and Back closes whichever is up.
                uiState.dwellMenuOpen = false
            }
            PlayerBackAction.CloseInfo -> uiState.infoOpen = false
            PlayerBackAction.HideControls -> uiState.controlsVisible = false
            PlayerBackAction.Exit -> finish()
        }
    }

    private val playbackStats = PlaybackStatsSampler()

    /**
     * Periodic frame-rate/drop line while playing.
     *
     * Rides the existing ticker rather than adding a timer, and only while the
     * engine says it is playing: a paused or buffering player renders nothing,
     * and reporting 0fps for it would bury the case this exists to catch.
     */
    private fun samplePlaybackStats() {
        if (!uiState.isPlaying || uiState.isBuffering) {
            // Drop the baseline rather than just skipping. The rate is
            // frames-over-wall-clock, so carrying a baseline across a pause, a
            // rebuffer or a trip through onStop/onStart would divide the frames
            // by the *idle* time too: a 60s pause reports `fps=3.8 dropped=+0`
            // on resume — which is precisely the "low rate, no drops" signature
            // this exists to detect. A diagnostic that manufactures its own
            // headline symptom is worse than none.
            playbackStats.reset()
            return
        }
        val active = engine ?: return
        playbackStats.sample(
            nowMs = System.currentTimeMillis(),
            rendered = active.renderedFrameCount,
            dropped = active.droppedFrameCount,
        )?.let { logNative("playback $it") }
    }

    /**
     * Relays one short, credential-free note into Dart's **exportable**
     * diagnostics log, stamped with ms since this Activity started.
     *
     * Past `adopted=…` the whole native player used to be silent in an exported
     * log: no first frame, no stall, no reconnect, no engine swap. A user
     * reporting "high-bitrate channels stay black after going fullscreen" could
     * therefore send a complete, healthy-looking export of the exact session
     * that failed. Everything routed through here is chosen to be safe to
     * export verbatim — never a URL, header or provider reply.
     */
    private fun logNative(note: String) {
        MainActivity.instance?.get()?.logPlaybackDiagnostic(
            "native $note ms=${SystemClock.elapsedRealtime() - startedAtMs}",
        )
    }

    /**
     * The sink handed to whichever [ExoPlayerEngine] this Activity drives —
     * one it built, or the shared preview engine it adopted. Engines report
     * from the playback thread as well as the main one, so it hops.
     */
    private val diagnosticSink: (String) -> Unit = { note ->
        runOnUiThread { logNative(note) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = WeakReference(this)
        startedAtMs = SystemClock.elapsedRealtime()
        // Gesture navigation and Android's system Back dispatcher terminate at
        // this same Activity boundary as remote key events. Do not register a
        // second Compose BackHandler: some TV images deliver one press through
        // both paths.
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() = handleSystemBack()
            },
        )
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Let the video reach the physical screen edge on a notched phone rather
        // than being letterboxed away from the cutout (the DEFAULT mode letterboxes
        // in landscape, which is exactly the orientation a player is used in). The
        // Compose overlay insets itself via safeDrawingPadding, so only the video
        // extends under the cutout — no control is ever placed there.
        // `ALWAYS` from API 30, `SHORT_EDGES` on 28–29. Android 15 deprecated
        // DEFAULT/SHORT_EDGES/NEVER (Play Console flags the use): with
        // edge-to-edge enforced from targetSdk 35 the window already extends
        // into the cutout, so the three modes that describe *not* doing that no
        // longer describe anything, and `ALWAYS` is the one that survives.
        // `ALWAYS` is public API from 30 only, so the older constant stays for
        // 28–29 — where it is not deprecated and is still the correct value.
        // Behaviour is unchanged either way: the video reaches the physical edge
        // instead of being letterboxed away from the cutout in landscape, and
        // the Compose overlay still insets itself via `safeDrawingPadding`, so
        // no control is ever placed under the cutout.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                    } else {
                        @Suppress("DEPRECATION")
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                    }
            }
        }
        hideSystemUi()

        val streamUrl = intent.getStringExtra(EXTRA_URL)
        if (streamUrl.isNullOrBlank()) {
            finish()
            return
        }
        url = streamUrl
        headers = requestHeaders()
        subtitles = subtitleSpecs()
        bufferPreset = BufferPreset.fromName(intent.getStringExtra(EXTRA_BUFFER_PRESET))
        // Credential-free: the endpoint the stream will be fetched through, or
        // nothing when direct. It is the difference between "the provider is
        // unreachable" and "the proxy is", which used to be indistinguishable.
        streamRoute?.let {
            logNative("stream proxy ${it.host}:${it.port} (${it.type})")
        }

        // Seamless handoff: when the live preview is already playing this exact
        // stream, adopt its running engine — only the video output moves to this
        // Activity's surface; audio, decoder and buffer carry over untouched.
        val shared = if (intent.getBooleanExtra(EXTRA_ADOPT_SHARED, false)) {
            SharedEngine.adoptForFullscreen(
                streamUrl,
                diagnosticSink,
                // Bound with the diagnostics, i.e. *before* the claim: it is
                // the claimed surface's own first frame that moves
                // FrameLivenessWatch off the first-frame clock, and inferring
                // it from the frame counter would fire during the deferred
                // claim, while the preview texture is still the output.
                onClaimedSurfaceFirstFrame = {
                    frameLiveness.markHandoffFirstFrame(System.currentTimeMillis())
                },
            )
        } else {
            null
        }
        adoptedShared = shared != null
        // The handoff's outcome, in the *exportable* log rather than logcat: a
        // refused adoption is a full stream reload, which is exactly what a user
        // reporting a slow, "reconnecting" preview→fullscreen transition sees.
        // Both halves are credential-free booleans.
        MainActivity.instance?.get()?.logPlaybackDiagnostic(
            "native fullscreen adoptShared=" +
                "${intent.getBooleanExtra(EXTRA_ADOPT_SHARED, false)} adopted=$adoptedShared",
        )

        uiState = shared?.second
            ?: PlayerUiState(
                title = intent.getStringExtra(EXTRA_TITLE).orEmpty(),
                isLive = intent.getBooleanExtra(EXTRA_IS_LIVE, false),
                sourceName = intent.getStringExtra(EXTRA_SOURCE_NAME),
                isTv = isTelevision(),
                epgNow = epgEntry(EXTRA_EPG_NOW_TITLE, EXTRA_EPG_NOW_START, EXTRA_EPG_NOW_STOP, EXTRA_EPG_NOW_DESC),
                epgNext = epgEntry(EXTRA_EPG_NEXT_TITLE, EXTRA_EPG_NEXT_START, EXTRA_EPG_NEXT_STOP, null),
            )
        if (shared != null) {
            // The adopted state was born for the faceless preview — fill in this
            // stream's presentation fields and reset any stale overlay state.
            uiState.title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
            uiState.isLive = intent.getBooleanExtra(EXTRA_IS_LIVE, false)
            uiState.sourceName = intent.getStringExtra(EXTRA_SOURCE_NAME)
            uiState.isTv = isTelevision()
            uiState.epgNow = epgEntry(EXTRA_EPG_NOW_TITLE, EXTRA_EPG_NOW_START, EXTRA_EPG_NOW_STOP, EXTRA_EPG_NOW_DESC)
            uiState.epgNext = epgEntry(EXTRA_EPG_NEXT_TITLE, EXTRA_EPG_NEXT_START, EXTRA_EPG_NEXT_STOP, null)
            uiState.controlsVisible = true
            uiState.openMenu = PlayerMenu.None
            uiState.infoOpen = false
            uiState.dwellMenuOpen = false
            uiState.inPip = false
        }
        // Android TV's PiP framework restricts entry to communication/smartHome/health/ticker
        // use cases via a required manifest category — general media playback isn't an
        // approved category there, so FEATURE_PICTURE_IN_PICTURE is intentionally left
        // unused/absent for our purposes on most TVs. That's a platform limitation, not a bug:
        // the button below simply won't show on devices that report the feature missing.
        uiState.supportsPip = supportsPip()
        // Device-wide chrome preferences, set once here so they apply to both the
        // fresh PlayerUiState and an adopted preview state. Absent extras keep the
        // field's default (true) — i.e. an older Dart build that doesn't send them
        // draws exactly the chrome it draws today, rather than losing a badge.
        uiState.showClock = intent.getBooleanExtra(EXTRA_SHOW_CLOCK, true)
        uiState.showPlaybackTimes = intent.getBooleanExtra(EXTRA_SHOW_TIMES, true)
        uiState.showChannelName =
            intent.getBooleanExtra(EXTRA_SHOW_CHANNEL_NAME, true)
        // Optional controls (Settings → "Player controls"). Fail open: an empty
        // or absent list shows everything, which is what every install drew
        // before the setting existed.
        val hiddenControls = intent.getStringExtra(EXTRA_HIDDEN_CONTROLS)
            ?.split(',')
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?.toSet()
            .orEmpty()
        uiState.showsPreviousNext = "previous_next" !in hiddenControls
        uiState.showsSeek10 = "seek10" !in hiddenControls
        uiState.showsMute = "mute" !in hiddenControls
        uiState.showsVolume = "volume" !in hiddenControls
        uiState.showsQuickList = "quick_list" !in hiddenControls
        uiState.showsFavorite = "favorite" !in hiddenControls
        uiState.showsSubtitles = "subtitles" !in hiddenControls
        uiState.showsAspect = "aspect" !in hiddenControls
        uiState.showsPip = "pip" !in hiddenControls
        uiState.showsInfo = "info" !in hiddenControls
        uiState.doubleTapAction = DoubleTapAction.fromWire(
            intent.getStringExtra(EXTRA_DOUBLE_TAP),
        )
        uiState.seekStepSeconds = intent.getIntExtra(EXTRA_SEEK_STEP, 10)
            .coerceIn(1, 600)
        // Favorite toggle (live only): seeded from the Dart store, read back on
        // exit (see finish) so the channel list reflects it on return.
        // Opens on the mode Dart is already in (the user's stored choice, or a
        // platform default), rather than this class's own initial value — the
        // two overlays would otherwise disagree across the handoff.
        AspectMode.entries
            .firstOrNull { it.label == intent.getStringExtra(EXTRA_ASPECT) }
            ?.let { uiState.aspect = it }
        // Whether that mode is this channel's own pin or the device-wide choice,
        // and what the global mode is (the menu's "Use global" applies it).
        aspectPinned = intent.getBooleanExtra(EXTRA_ASPECT_PINNED, false)
        uiState.aspectPinned = aspectPinned
        globalAspectLabel =
            intent.getStringExtra(EXTRA_GLOBAL_ASPECT)?.takeIf { it.isNotBlank() }
                ?: AspectMode.Fill.label
        uiState.canFavorite = intent.getBooleanExtra(EXTRA_CAN_FAVORITE, false)
        uiState.isFavorite = intent.getBooleanExtra(EXTRA_IS_FAVORITE, false)
        // Whether a LiveZapController exists behind this route. Set here (not
        // only in the fresh-state branch above) because an adopted preview
        // state was born faceless and carries the *previous* session's value.
        // Fails closed: an older Dart build that doesn't send the key simply
        // offers no quick-list button, exactly as before.
        uiState.canZap = intent.getBooleanExtra(EXTRA_ZAP_ENABLED, false)
        uiState.stepEnabled = intent.getBooleanExtra(EXTRA_STEP_ENABLED, false)
        // The live zap modes Dart pushes for the overflow menu's checkmarks.
        // The push can land in the window between `open` returning and this
        // method building `uiState` (MainActivity's channel answers at once,
        // while `startActivity` is asynchronous), and dropping it there left
        // "Random zapping" unchecked at launch until the user toggled it — so
        // the values are kept in the companion and re-applied here.
        pendingRandomZapping?.let { uiState.randomZapping = it }
        pendingAutoSwitch?.let { uiState.autoSwitchEnabled = it }
        // The pace and its ladder, for the auto-switch long-press menu. Same
        // pre-`onCreate` race as the two modes above: Dart seeds them on `open`.
        pendingDwellSeconds?.let { uiState.dwellSeconds = it }
        pendingDwellOptions?.let { uiState.dwellOptions = it }
        // Which side of the picture owns the volume swipe; the other owns
        // brightness (Settings → "Volume and brightness swipes", sent on `open`).
        uiState.volumeSwipeOnLeft =
            intent.getBooleanExtra(EXTRA_VOLUME_SWIPE_ON_LEFT, true)
        uiState.brightness = currentScreenBrightness()
        // Orientation is a **player-only device preference** (native prefs, not
        // Dart's settings store): it survives a channel change and applies to
        // the next player open. Default off = the manifest's `fullSensor`.
        uiState.orientationLocked =
            orientationPrefs().getBoolean(PlayerOrientation.KEY_LOCKED, false)
        // A phone has an accelerometer; a TV does not, and a rotation button
        // there would be a control that can never change anything.
        uiState.supportsOrientationLock =
            packageManager.hasSystemFeature(PackageManager.FEATURE_SENSOR_ACCELEROMETER)
        applyOrientationLock(uiState.orientationLocked)
        // Preserve the user's audible level across a muted session, so the
        // close result can report it with RESULT_MUTED and unmuting restores
        // that level rather than full volume.
        uiState.audibleVolume = initialAudibleVolume
        // Seed the **live** state as well, not just the engine: a rebuilt engine
        // (`startWithExoPlayer` after a cross-source zap or a fallback) reads
        // `currentVolume()` from here, and a preview-adopted state starts at the
        // preview's deliberate zero.
        uiState.volume = initialVolume
        uiState.muted = initialMuted
        if (initialMuted) {
          // A mute restored from the previous session counts as the **button's**:
          // the user silenced the player deliberately, and the volume swipe must
          // not override that any more than it overrides a press made a second
          // ago. Without this the gesture was live on the very session that
          // opened muted, and its first pixel of travel unmuted the player —
          // which made the restored mute look broken.
          uiState.mutedByButton = true
        }
        logNative(
            "audio seed volume=$initialVolume muted=$initialMuted " +
                "audible=$initialAudibleVolume",
        )

        if (shared != null) {
            val sharedEngine = shared.first
            sharedEngine.onUnsupportedVideo = { runOnUiThread { fallbackToMpv() } }
            sharedEngine.onRecoverableError = { runOnUiThread { reconnectLive(force = true) } }
            sharedEngine.onVideoSizeChanged = null
            setEngine(sharedEngine)
            // Start at the session's volume/mute (see EXTRA_VOLUME), not a blind
            // 1f: a default session is 1f (restoring the old "fullscreen always
            // plays unmuted" behavior), while a muted/lowered session survives
            // the handoff instead of coming back loud.
            sharedEngine.setVolume(initialVolume)
            sharedEngine.play()
            // The surface claim happened inside adoptForFullscreen above, and
            // the frames the preview drew before it are the proof
            // FrameLivenessWatch otherwise has to wait to observe — which, when
            // the handoff freezes the renderer before its first frame, never
            // arrives. Arming here is what turns that permanent silent freeze
            // into a stall the watchdog can act on. armed=false means the
            // engine reported no frames at all, so the inert rule still stands.
            val armed = frameLiveness.armHandoff(
                System.currentTimeMillis(),
                sharedEngine.renderedFrameCount,
            )
            logNative("handoff frame watch armed=$armed")
        } else {
            startWithExoPlayer()
            // VOD resume: jump to the saved position once the engine loads.
            // ExoPlayer remembers a seek issued right after load/prepare.
            val resumeMs = intent.getLongExtra(EXTRA_RESUME_MS, 0L)
            if (resumeMs > 0L && !uiState.isLive) engine?.seekTo(resumeMs)
        }

        if (BuildConfig.DEBUG) {
            val soakAutoCloseMs = intent.getLongExtra(EXTRA_SOAK_AUTOCLOSE_MS, -1L)
            if (soakAutoCloseMs > 0L) {
                soakAutoCloseJob = lifecycleScope.launch {
                    delay(soakAutoCloseMs)
                    finish()
                }
            }
        }

        // The video view is hosted *by Compose* (`AndroidView` in [PlayerScreen]),
        // not attached here in `onCreate`. That was measured, not assumed: hoisting
        // it into a FrameLayout under the ComposeView changed nothing, because
        // `AndroidView` adds the SurfaceView during the first **composition**,
        // which happens inside the window's first traversal — the same traversal
        // that would lay out a pre-attached view. There is no second traversal to
        // save, and the ~150 ms between composition and `surfaceCreated` is
        // surface allocation, not scheduling. See docs/player.md.
        setContent {
            engineState.value?.let { active ->
                PlayerScreen(
                    state = uiState,
                    videoView = active.view,
                    callbacks = playerCallbacks(),
                )
            }
        }
    }

    /** Session-wide start volume (0..1); absent (old callers) = 1f. */
    private val initialVolume: Float
        get() = intent.getFloatExtra(EXTRA_VOLUME, 1f).coerceIn(0f, 1f)

    /** The audible level to restore after unmute; never 0. */
    private val initialAudibleVolume: Float
        get() = intent
            .getFloatExtra(
                EXTRA_AUDIBLE_VOLUME,
                if (initialVolume > 0f) initialVolume else 1f,
            )
            .coerceIn(0.1f, 1f)

    private val initialMuted: Boolean
        get() = intent.getBooleanExtra(EXTRA_MUTED, initialVolume <= 0f)

    /**
     * The level a freshly built engine must start at: the **live** session
     * state, not the launch Intent.
     *
     * A rebuild (a cross-source zap changing the data source or the buffer
     * preset, an engine fallback) used to seed itself from [initialVolume] and
     * so silently undid a mute or a level change made since the player opened —
     * "mute periodically falls off" with no user action to explain it.
     */
    private fun currentVolume(): Float = if (uiState.muted) 0f else uiState.volume

    private fun startWithExoPlayer() {
        // Read the session's intent **before** constructing the engine: its
        // `init` writes `state.volume = player.volume` (a fresh ExoPlayer is at
        // 1f) and `state.muted = false`, so reading `currentVolume()` afterwards
        // would seed the engine with the value it just clobbered — the exact
        // "mute is off when I reopen" the audio log caught (`audio seed
        // muted=true` followed by `exo seed muted=false`).
        val seedVolume = currentVolume()
        val exo = ExoPlayerEngine(
            context = this,
            state = uiState,
            headers = headers,
            // The field, not the Intent: a zap can change both the headers
            // (a cross-source zap) and the preset, and the rebuilt engine has
            // to be built with the *current* ones.
            bufferPreset = this.bufferPreset,
            // Settings -> Proxy: the stream of *this* content kind, when the user
            // asked for it. streamProxy is null for a direct connection.
            streamProxy = streamRoute?.javaProxy,
        )
        exo.onUnsupportedVideo = { runOnUiThread { fallbackToMpv() } }
        exo.onRecoverableError = { runOnUiThread { reconnectLive(force = true) } }
        exo.onDiagnostic = diagnosticSink
        setEngine(exo)
        exo.load(url, subtitles)
        // Fresh engines open at their own default 1f — apply the **live**
        // session volume (the launch value on a cold open, the mute/level
        // chosen since on a zap rebuild).
        exo.setVolume(seedVolume)
        logNative("exo seed volume=$seedVolume muted=${uiState.muted}")
    }

    /** One-way fallback: ExoPlayer couldn't decode the video → switch to libmpv. */
    private fun fallbackToMpv() {
        if (engine is MpvEngine || isFinishing) return
        Log.i(TAG, "falling back to libmpv (video unsupported by ExoPlayer)")
        // An engine swap mid-session is a full stream reload on a channel the
        // user was already watching — very much part of "it stopped working
        // when I went fullscreen", and previously logcat-only.
        logNative("engine fallback from=exo to=mpv adopted=$adoptedShared")
        frameLiveness.reset()
        if (adoptedShared) {
            // The adopted engine can't decode this stream, so the shared preview
            // engine is dead too: release it through the holder, which tells the
            // Dart side to reset its preview state (it falls back to media_kit).
            adoptedShared = false
            SharedEngine.invalidateFromFullscreen(unsupported = true)
        } else {
            engine?.release()
        }
        // Reset stale stream info before the new engine repopulates it.
        uiState.videoUnsupported = false
        startWithMpv()
    }

    /** Builds and loads an [MpvEngine] with the session's current locator. */
    private fun startWithMpv() {
        // Same ordering rule as [startWithExoPlayer]: read the intent before the
        // engine exists, because creating it resets the shared state to mpv's
        // defaults (unmuted, volume 100).
        val seedVolume = currentVolume()
        val seedMuted = uiState.muted
        val mpv = MpvEngine(
            context = this,
            state = uiState,
            headers = headers,
            post = { action -> if (!isFinishing) runOnUiThread(action) },
            bufferPreset = this.bufferPreset,
            isLive = uiState.isLive,
            httpProxy = streamRoute?.mpvUrl,
        )
        setEngine(mpv)
        // mpv starts at its own default (unmuted, volume 100) and its first
        // property events would overwrite the session state with that — the
        // ExoPlayer→mpv fallback used to un-mute a muted session, which is what
        // "mute falls off when I switch source" was: the other source's streams
        // are the ones that fall back. Seed both the level and the flag.
        mpv.setVolume(seedVolume)
        mpv.setMuted(seedMuted)
        logNative("mpv seed volume=$seedVolume muted=$seedMuted")
        mpv.load(url, subtitles)
    }

    private fun setEngine(next: PlaybackEngine) {
        engine = next
        engineState.value = next
    }

    /** Watchdog: reconnect a live stream that has stalled (buffering) or dropped (ended). */
    private fun pollLiveReconnect() {
        if (!uiState.isLive) return
        // A re-resolve in flight *is* the reconnect, still in progress. Without
        // this the round trip would read as healthy and reset the backoff: the
        // engine sits in its terminal state (no further transition callback) and
        // `reconnectLive` already cleared `ended`, so both flags are false until
        // the reload actually starts.
        if (resolveGate.inFlight) return
        val now = System.currentTimeMillis()
        // A zap resolve in flight is not a stall: Dart is replacing this
        // stream on purpose (see [zapSettlingNow]).
        if (zapSettlingNow(now)) return
        // "Playing normally" by the engine's own account. When that is true and
        // no frame has reached the screen for NO_FRAME_STALL_MS, the account is
        // wrong — see [FrameLivenessWatch] for the failure it catches.
        val claimsHealthy =
            uiState.isPlaying && !uiState.isBuffering && !uiState.ended
        val frameStalled = frameLiveness.sample(
            nowMs = now,
            playingNormally = claimsHealthy,
            renderedFrames = engine?.renderedFrameCount ?: -1,
            // Proof of life the rendered count alone doesn't carry: a decoder
            // dropping frames is behind, not wedged, and no recovery this
            // watchdog can order makes a decoder faster.
            droppedFrames = engine?.droppedFrameCount ?: -1,
        )
        val stalled = uiState.isBuffering || uiState.ended || frameStalled
        if (!stalled) {
            // Healthy playback: clear the stall clock and any reconnecting state.
            stalledSinceMs = 0L
            reconnectAttempt = 0
            stallKind = "none"
            if (uiState.reconnecting) uiState.reconnecting = false
            return
        }
        // A renderer frozen this soon after the fullscreen surface claim gets
        // the local fix first — reloading the stream to repair a decoder is
        // both slower and more expensive than repairing the decoder.
        if (frameStalled && tryHandoffDecoderRebuild(now)) return
        if (stalledSinceMs == 0L) stalledSinceMs = now
        // A frozen renderer needs no further grace period: the watch has
        // already waited out its own window while everything read healthy, so
        // requiring the stall threshold on top would double it.
        val threshold = when {
            frameStalled -> 0L
            uiState.ended -> ReconnectPolicy.ENDED_RECONNECT_MS
            else -> ReconnectPolicy.STALL_RECONNECT_MS
        }
        stallKind = when {
            frameStalled -> "noframes"
            uiState.ended -> "ended"
            else -> "buffering"
        }
        if (now - stalledSinceMs >= threshold) reconnectLive(force = false)
    }

    /**
     * First rung of the recovery ladder for the preview→fullscreen handoff:
     * rebuild the video decoder in place instead of reloading the stream.
     *
     * The reports this answers are all the same session shape — an adopted
     * handoff, a claimed surface, and then either no picture at all or a
     * picture that stops within a second — and the exported logs behind them
     * all end the same way: the reload that eventually fired *fixed* it, on the
     * same URL (`refreshed=false`), on the same surface, after which the same
     * channel played for minutes without a drop. A stream and a device that
     * demonstrably work, through a decoder that stopped when its output surface
     * was switched under it. Nothing about that needs the network re-touched:
     * a reload spends a provider round trip and the whole buffer to build the
     * one thing that was actually broken, while carrying the risk that a
     * single-connection account refuses the new connection.
     *
     * Bounded to one attempt inside the handoff window ([FrameLivenessWatch]);
     * everything past that is the reload watchdog's, unchanged. Re-arms the
     * watch so a rebuild that *doesn't* restore the picture escalates on the
     * short handoff clock rather than the full six-second one.
     */
    private fun tryHandoffDecoderRebuild(nowMs: Long): Boolean {
        if (!frameLiveness.inHandoffWindow(nowMs)) return false
        if (handoffRebuilds >= MAX_HANDOFF_REBUILDS) return false
        val active = engine ?: return false
        // Counters first: after the rebuild they describe the new decoder, and
        // it is the frozen one's tallies that say *which* failure this was —
        // frames decoded and thrown away to catch up, or a decoder that had
        // stopped emitting entirely.
        val counters = active.videoFrameCounters
        // Which of the two handoff failures this was: a picture that never
        // arrived on the claimed surface, or one that arrived and stopped. They
        // are indistinguishable in the tallies (a single rendered frame is lost
        // in a preview's running total) and they are the two shapes the reports
        // keep alternating between, so the watch's own answer is worth a word.
        val phase = if (frameLiveness.drewSinceArm()) "afterFirstFrame" else "noFirstFrame"
        // How far into the handoff budget this fired. Without it a rebuild line
        // cannot be told apart from a rebuild that fired inside normal
        // first-frame latency — which is how two thresholds stayed wrong
        // through several exported logs.
        val sinceArm = frameLiveness.sinceArmMs(nowMs)
        if (!active.rebuildVideoDecoder()) return false
        handoffRebuilds++
        logNative(
            "handoff decoder rebuild attempt=$handoffRebuilds phase=$phase " +
                "sinceArmMs=$sinceArm" + (counters?.let { " $it" } ?: ""),
        )
        stalledSinceMs = 0L
        stallKind = "none"
        frameLiveness.armHandoff(nowMs, active.renderedFrameCount)
        return true
    }

    /**
     * Reload the live source to reconnect, with capped backoff between attempts.
     * [force] (a hard error) skips the stall threshold but still rate-limits.
     *
     * The reload goes through a **fresh locator** ([withFreshLiveLocator]):
     * Stalker `create_link` URLs carry single-use `play_token`s, so after a
     * portal-side kill the URL this Activity was launched with is permanently
     * dead and retrying it can never reconnect.
     */
    private fun reconnectLive(force: Boolean) {
        if (!uiState.isLive || isFinishing) return
        // Single-flight: a re-resolve already in flight (this watchdog or the
        // user's "Go to live") owns the next reload. Bail *before* the attempt
        // bookkeeping so a suppressed attempt can't inflate the backoff; the
        // 500ms progress ticker re-enters once the in-flight request settles.
        if (resolveGate.inFlight) return
        val now = System.currentTimeMillis()
        if (zapSettlingNow(now)) return
        val sinceLast = now - lastReconnectMs
        val minGap = ReconnectPolicy.minGapMs(reconnectAttempt, force)
        if (lastReconnectMs != 0L && sinceLast < minGap) return
        reconnectAttempt++
        lastReconnectMs = now
        stalledSinceMs = now
        uiState.reconnecting = true
        uiState.ended = false
        Log.i(TAG, "live reconnect attempt=$reconnectAttempt force=$force")
        // Rate-limited above, so this is once per real attempt rather than once
        // per 500 ms tick. `kind` is what makes it worth exporting: an underrun,
        // a drop and a frozen renderer want completely different answers, and
        // all three used to arrive as the same silent black screen.
        logNative(
            "live reconnect attempt=$reconnectAttempt force=$force " +
                "kind=${if (force) "error" else stallKind}" +
                // Frame tallies at the moment of the decision: they are what
                // separate a decoder throwing frames away to catch up from one
                // that has stopped emitting, which read identically from every
                // health flag the engine exposes.
                (engine?.videoFrameCounters?.let { " $it" } ?: ""),
        )
        frameLiveness.reset()
        withFreshLiveLocator {
            // The round trip is asynchronous, so restart the stall clock when
            // the reload actually begins rather than when it was requested.
            stalledSinceMs = System.currentTimeMillis()
            engine?.load(url, subtitles)
        }
    }

    /**
     * Re-resolves the live locator through Dart, then runs [onFresh] with [url]
     * / [headers] updated in place. Returns false — doing nothing — when a
     * request is already in flight: provider accounts are single-connection, so
     * two overlapping `create_link` calls would fight over the one slot.
     *
     * Settlement is a race between the MethodChannel reply and a
     * [ResolveGate.TIMEOUT_MS] backstop, arbitrated by the gate's monotonic
     * token so exactly one of them applies an outcome and the loser is dropped.
     * The timeout is deliberately long: falling back early just reloads the
     * spent locator we already know is dead, which is strictly worse than
     * waiting. Any answer we can't use falls back to the current locator
     * ([ResolveAgainReply]), so this always ends in a reload attempt.
     */
    private fun withFreshLiveLocator(onFresh: () -> Unit): Boolean {
        val token = resolveGate.begin() ?: return false
        resolveTimeoutJob = lifecycleScope.launch {
            delay(ResolveGate.TIMEOUT_MS)
            resolveTimeoutJob = null
            settleFreshLiveLocator(token, reply = null, timedOut = true, onFresh = onFresh)
        }
        val host = MainActivity.instance?.get()
        if (host == null) {
            // No Flutter host to ask (it was destroyed under us) — settle now on
            // the current locator instead of waiting out the whole timeout.
            settleFreshLiveLocator(token, reply = null, timedOut = false, onFresh = onFresh)
        } else {
            host.requestFreshLiveLocator { reply ->
                settleFreshLiveLocator(token, reply, timedOut = false, onFresh = onFresh)
            }
        }
        return true
    }

    private fun settleFreshLiveLocator(
        token: Long,
        reply: Any?,
        timedOut: Boolean,
        onFresh: () -> Unit,
    ) {
        // Lost the race (or belongs to an already-settled request): discard.
        if (!resolveGate.settle(token)) return
        resolveTimeoutJob?.cancel()
        resolveTimeoutJob = null
        // A reply can still land after teardown (the channel callback outlives
        // this Activity); nothing to reload then.
        if (isFinishing || isDestroyed) return
        val next = ResolveAgainReply.parse(reply, LiveLocator(url, headers))
        val refreshed = next.url != url
        url = next.url
        // Headers are baked into an engine's data-source factory at construction
        // (see SharedEngine.openPreview / MpvEngine), so this only takes effect
        // for a later engine build — an mpv fallback. Re-resolving the same
        // channel on the same source can't change them in practice; the
        // never-blank rule in ResolveAgainReply is what keeps a MAG User-Agent
        // from being dropped if a reply ever omits them.
        headers = next.headers
        // Never log the locator itself — provider URLs embed credentials. The
        // two booleans are safe and are what separate "the portal gave us a new
        // link and it still didn't play" from "we retried a locator we already
        // knew was dead because the round trip timed out".
        Log.i(TAG, "live re-resolve settled refreshed=$refreshed timedOut=$timedOut")
        logNative("live re-resolve refreshed=$refreshed timedOut=$timedOut")
        onFresh()
    }

    // ── Live zapping: applying what Dart decided ─────────────────────────────

    /**
     * Presentation-only push from Dart's zap controller, once per cursor move.
     *
     * Carries the **cursor's** channel, which during the settle window is
     * ahead of what is playing — that is the whole point of a banner. The
     * guide fields move with it for the same reason: while the user is
     * browsing, the strip should describe the channel they are browsing to.
     * [applyZap] puts both back in step when the move settles.
     */
    /** Live zap modes for the overflow menu's checkmarks; no banner involved. */
    fun applyZapModes(args: Map<*, *>) {
        // Recorded even before `uiState` exists: the launch-time seed can land
        // ahead of `onCreate` (see the companion's `pending*` fields).
        (args["random"] as? Boolean)?.let { pendingRandomZapping = it }
        (args["autoSwitch"] as? Boolean)?.let { pendingAutoSwitch = it }
        (args["dwellSeconds"] as? Number)?.toInt()?.let { pendingDwellSeconds = it }
        (args["dwellOptions"] as? List<*>)?.let { raw ->
            val options = raw.mapNotNull { (it as? Number)?.toInt() }.filter { it > 0 }
            if (options.isNotEmpty()) pendingDwellOptions = options
        }
        if (!::uiState.isInitialized || isFinishing || isDestroyed) return
        uiState.randomZapping = pendingRandomZapping ?: false
        uiState.autoSwitchEnabled = pendingAutoSwitch ?: false
        pendingDwellSeconds?.let { uiState.dwellSeconds = it }
        pendingDwellOptions?.let { uiState.dwellOptions = it }
    }

    /**
     * Position/duration the engine is at right now, for Dart's resume store.
     *
     * The Activity reports its final position on `nativeClosed`, which is all a
     * route exit needs — but a VOD Previous/Next step swaps the stream inside
     * the session, so the outgoing title never reaches that report and its
     * resume point was lost ("the position is not remembered when I press
     * Next"). Dart asks for it before the swap instead.
     *
     * `uiState.positionMs` is the same value the scrubber draws, kept current
     * by the progress ticker.
     */
    fun currentPlaybackPosition(): Map<String, Any> {
        if (!::uiState.isInitialized || isFinishing || isDestroyed) {
            return mapOf("positionMs" to 0L, "durationMs" to 0L)
        }
        return mapOf(
            "positionMs" to uiState.positionMs.coerceAtLeast(0L),
            "durationMs" to uiState.durationMs.coerceAtLeast(0L),
        )
    }

    fun applyZapBanner(args: Map<*, *>) {
        if (!::uiState.isInitialized || isFinishing || isDestroyed) return
        uiState.channelNumber = (args["channelNumber"] as? Number)?.toInt()
        uiState.channelName = (args["channelName"] as? String)?.takeIf { it.isNotBlank() }
        uiState.digitBuffer = (args["digits"] as? String).orEmpty()
        zapDigitsPendingOptimistic = uiState.digitBuffer.isNotEmpty()
        uiState.zapMessage = (args["message"] as? String)?.takeIf { it.isNotBlank() }
        uiState.zapPosition = (args["position"] as? Number)?.toInt() ?: 0
        uiState.zapTotal = (args["total"] as? Number)?.toInt() ?: 0
        uiState.epgNow = epgFromMap(args, "epgNowTitle", "epgNowStartMs", "epgNowStopMs", "epgNowDesc")
        uiState.epgNext = epgFromMap(args, "epgNextTitle", "epgNextStartMs", "epgNextStopMs", null)
        val settling = args["settling"] as? Boolean ?: false
        uiState.zapSettling = settling
        zapSettlingSinceMs = if (settling) System.currentTimeMillis() else 0L
        // The push carries the timestamp only a *new* zap changes; a refresh
        // (auto-switch countdown, aspect, reconnect) repeats the old one. So a
        // **newer** stamp re-opens the banner and anything else must not: the
        // auto-switch tick fires every second, and re-opening on it made the
        // channel name disappear on the 3 s timer and pop straight back.
        val stamp = (args["atMs"] as? Number)?.toLong()?.takeIf { it > 0L }
        if (stamp == null) {
            uiState.zapBannerAtMs = System.currentTimeMillis()
            uiState.zapBannerVisible = true
        } else if (stamp > uiState.zapBannerAtMs) {
            uiState.zapBannerAtMs = stamp
            uiState.zapBannerVisible = true
        }
    }

    /**
     * The quick list, pushed by Dart on every controller notification.
     *
     * Presentation only, like [applyZapBanner]: Dart owns the rows, the
     * cursor and the mode stack, and this is the parsed window
     * ([QuickListState.fromPayload], which never throws). A push with
     * `open:false` is a **tear-down instruction**, not an absence, so it is
     * applied exactly like any other.
     *
     * Opening it takes the screen from the chrome. That is not cosmetic: the
     * list claims the D-pad at the Activity boundary whatever the chrome is
     * doing ([ZapKeyPolicy]), so leaving the control row up would leave a
     * focused Compose button on screen that no arrow key can walk away from —
     * the same stranding "Go to live" once caused. Hiding the controls also
     * closes any open menu and the info panel through the overlay's existing
     * `controlsVisible` effect.
     */
    fun applyQuickList(args: Map<*, *>) {
        if (!::uiState.isInitialized || isFinishing || isDestroyed) return
        val next = QuickListState.fromPayload(args)
        val wasOpen = uiState.quickList.open
        uiState.quickList = next
        zapQuickListOpenOptimistic = next.open
        if (next.open && !wasOpen) {
            uiState.controlsVisible = false
        }
    }

    /**
     * Applies a settled zap: this Activity keeps playing, on the same surface,
     * with a new locator.
     *
     * Nothing here decides *which* channel — Dart already did, and already
     * resolved it. What the Activity owns is everything that would otherwise
     * be wrong the moment the stream underneath changes: an in-flight
     * re-resolve for the channel being left, an engine whose build-time
     * arguments no longer match, the shared engine's adoption key, and every
     * watchdog counter (the stop below is *ours*, not a drop).
     *
     * Never logs the locator or its headers — they carry account credentials.
     */
    fun applyZap(args: Map<*, *>): Map<String, Any> {
        val refused = mapOf<String, Any>("engineRebuilt" to false)
        if (!::uiState.isInitialized || isFinishing || isDestroyed) return refused
        // A zap is a new stream: it never inherits a raised catch-up speed.
        stopCatchUp()
        val nextUrl = (args["url"] as? String)?.takeIf { it.isNotBlank() } ?: return refused
        val nextHeaders = headerMapFrom(args["headers"])
        val nextPreset = BufferPreset.fromName(args["bufferPreset"] as? String)

        // A re-resolve in flight describes the channel we are leaving, and its
        // continuation ends in `engine.load(url)` — letting it settle after
        // this would reload the previous channel on top of the new one, with
        // every health flag reading normal.
        resolveGate.abandon()
        resolveTimeoutJob?.cancel()
        resolveTimeoutJob = null

        // Both are build-time arguments (the HTTP data-source factory and
        // `LoadControl`), so neither can be changed on a running engine — the
        // same reason `SharedEngine.openPreview` rebuilds on either.
        val rebuild = nextHeaders != headers || nextPreset != bufferPreset
        url = nextUrl
        headers = nextHeaders
        bufferPreset = nextPreset
        // A zapped channel brings no external subtitle sidecars of its own
        // (the contract carries none), and keeping the launch channel's would
        // attach the wrong files to it.
        subtitles = emptyList()

        uiState.title = (args["title"] as? String).orEmpty()
        (args["isLive"] as? Boolean)?.let { uiState.isLive = it }
        uiState.sourceName = args["sourceName"] as? String
        uiState.channelName = (args["channelName"] as? String)?.takeIf { it.isNotBlank() }
            ?: uiState.title.takeIf { it.isNotBlank() }
        uiState.channelNumber = (args["channelNumber"] as? Number)?.toInt()
        uiState.epgNow = epgFromMap(args, "epgNowTitle", "epgNowStartMs", "epgNowStopMs", "epgNowDesc")
        uiState.epgNext = epgFromMap(args, "epgNextTitle", "epgNextStartMs", "epgNextStopMs", null)
        uiState.canFavorite = args["canFavorite"] as? Boolean ?: false
        uiState.isFavorite = args["isFavorite"] as? Boolean ?: false
        // The payload's framing belongs to the **channel**, not to the launch:
        // it is its own pin or the device-wide mode, rebuilt by Dart from the
        // zap catalog on every settle. It used to be skipped once the viewer
        // had cycled the aspect in this session (`aspectChosenLocally`), which
        // meant unpinning on one channel and zapping back to a pinned one
        // rendered the pinned channel in the previous channel's mode — with the
        // chip showing no pin either, because the same gate skipped
        // `aspectPinned`.
        (args["aspect"] as? String)?.let { label ->
            AspectMode.entries.firstOrNull { it.label == label }?.let { uiState.aspect = it }
        }
        aspectPinned = args["aspectPinned"] as? Boolean ?: false
        uiState.aspectPinned = aspectPinned
        (args["globalAspect"] as? String)?.takeIf { it.isNotBlank() }?.let {
            globalAspectLabel = it
        }
        uiState.digitBuffer = ""
        zapDigitsPendingOptimistic = false
        uiState.zapMessage = null
        uiState.zapSettling = false
        zapSettlingSinceMs = 0L
        uiState.zapBannerAtMs = System.currentTimeMillis()
        uiState.zapBannerVisible = true

        // The watchdog starts the new channel on a clean sheet: a full stall
        // threshold, a full backoff budget, and no handoff window — the
        // surface did not change, and no earlier frames say anything about
        // this decoder, so `reset()` (never `armHandoff`) is the honest state.
        frameLiveness.reset()
        playbackStats.reset()
        handoffRebuilds = 0
        stalledSinceMs = 0L
        lastReconnectMs = 0L
        reconnectAttempt = 0
        stallKind = "none"
        uiState.ended = false
        uiState.reconnecting = false
        uiState.liveSynced = true
        uiState.videoUnsupported = false

        if (rebuild) {
            rebuildEngineForZap()
        } else {
            // `load` stops first (see ExoPlayerEngine.load), which is what
            // frees a single-connection account's only slot before the new
            // stream opens.
            engine?.load(url, subtitles)
            engine?.applyAspect(uiState.aspect)
        }
        // Keep the adoption key in step, or a later `adoptForFullscreen` keys
        // off the channel this session was launched on. A no-op after a
        // rebuild, which has already un-adopted.
        SharedEngine.noteFullscreenZap(url, headers, bufferPreset)
        logNative("zap applied rebuilt=$rebuild adopted=$adoptedShared")
        return mapOf("engineRebuilt" to rebuild)
    }

    /**
     * Replaces the engine because a zap changed something baked in at
     * construction (the headers of a cross-source zap, or the buffer preset).
     *
     * An **adopted** engine has to go through [SharedEngine.invalidateFromFullscreen]
     * rather than a bare `release()`: the preview owns that engine, and
     * releasing it behind the holder's back would leave `onDestroy`'s
     * `fullscreenDetached()` handing the preview a dead object. Same shape as
     * [fallbackToMpv], and it keeps `DebugCounters.exoEngines` /
     * `sharedEngineLive` balanced (release decrements, the fresh engine's
     * constructor increments).
     *
     * The engine *kind* is deliberately preserved: falling back to mpv is a
     * one-way, per-session decision about what this device can decode, and a
     * zap is not new evidence about that.
     */
    private fun rebuildEngineForZap() {
        val wasMpv = engine is MpvEngine
        if (adoptedShared) {
            adoptedShared = false
            SharedEngine.invalidateFromFullscreen(unsupported = false)
        } else {
            engine?.release()
        }
        if (wasMpv) startWithMpv() else startWithExoPlayer()
        engine?.applyAspect(uiState.aspect)
    }

    /** Coerces the channel codec's `Map<Object?, Object?>` header payload. */
    private fun headerMapFrom(raw: Any?): Map<String, String> {
        val map = raw as? Map<*, *> ?: return emptyMap()
        return map.entries.mapNotNull { entry ->
            val key = entry.key as? String
            val value = entry.value
            if (key.isNullOrBlank() || value == null) null else key to value.toString()
        }.toMap()
    }

    /** [epgEntry]'s counterpart for a MethodChannel payload. */
    private fun epgFromMap(
        args: Map<*, *>,
        titleKey: String,
        startKey: String,
        stopKey: String,
        descKey: String?,
    ): com.gchofficial.iptvs.player.EpgEntry? {
        val title = (args[titleKey] as? String)?.takeIf { it.isNotBlank() } ?: return null
        val start = (args[startKey] as? Number)?.toLong() ?: -1L
        val stop = (args[stopKey] as? Number)?.toLong() ?: -1L
        if (start < 0L || stop <= start) return null
        return com.gchofficial.iptvs.player.EpgEntry(
            title = title,
            startMs = start,
            stopMs = stop,
            description = descKey?.let { args[it] as? String }?.takeIf { it.isNotBlank() },
        )
    }

    /**
     * True while Dart has a zap resolve in flight.
     *
     * The watchdog stands down for the duration: the stream it would be
     * reconnecting is one Dart is deliberately replacing, and a reconnect
     * would spend a second `create_link` on a single-connection account
     * against the channel being left. Bounded by the same timeout the resolve
     * round trip uses, so a `settling` that never gets its follow-up expires
     * instead of wedging the watchdog.
     */
    private fun zapSettlingNow(nowMs: Long): Boolean {
        val since = zapSettlingSinceMs
        if (since == 0L) return false
        if (nowMs - since >= ResolveGate.TIMEOUT_MS) {
            zapSettlingSinceMs = 0L
            if (::uiState.isInitialized) uiState.zapSettling = false
            return false
        }
        return true
    }

    private fun playerCallbacks() = PlayerCallbacks(
        onPlayPause = {
            // Pausing a live stream drops you behind the live edge.
            if (uiState.isLive && uiState.isPlaying) uiState.liveSynced = false
            engine?.playPause()
        },
        onSeekTo = { engine?.seekTo(it) },
        onSeekBy = { if (!uiState.isLive) engine?.seekBy(it) },
        onSetVolume = { value ->
            if (value > 0f) uiState.audibleVolume = value
            engine?.setVolume(value)
        },
        onToggleMute = {
            // The mute **button** owns silence; the swipe owns the level. Which
            // one produced it is remembered here, because the engine reports a
            // zero volume as "muted" either way — and a swipe must never mute
            // (nor get stuck behind a mute it did not cause).
            val willMute = !uiState.muted && uiState.volume > 0f
            // An explicit level, not `engine.toggleMute()`: each engine keeps
            // its own `volumeBeforeMute`, so after a rebuild unmuting restored
            // its built-in floor (10 %) instead of the user's audible level.
            val level = if (willMute) 0f else uiState.audibleVolume
            engine?.setVolume(level)
            uiState.mutedByButton = willMute
            logNative("mute button muted=$willMute level=$level audible=${uiState.audibleVolume}")
            // Tell Dart now, not only on close: a backgrounded player can be
            // killed, and a mute it never heard about came back as sound on the
            // next open. The **audible** level rides along even while muted
            // (same contract as RESULT_VOLUME), so unmuting later restores the
            // user's level rather than the session's zero.
            MainActivity.instance?.get()?.reportVolume(uiState.audibleVolume, willMute)
        },
        onSetBrightness = { value -> setWindowBrightness(value) },
        onSelectAudio = { engine?.selectAudio(it) },
        onSelectSubtitle = { engine?.selectSubtitle(it) },
        onSetSpeed = { engine?.setSpeed(it) },
        onCycleAspect = {
            uiState.aspect = AspectMode.entries[(uiState.aspect.ordinal + 1) % AspectMode.entries.size]
            engine?.applyAspect(uiState.aspect)
            // Tell Dart. It owns the label sequence that every zap payload
            // carries (`kAspectModes`), and it only ever learned this choice
            // from RESULT_ASPECT at exit — so the *next* zap re-sent the stale
            // label and the picture snapped back to the old framing on every
            // channel change.
            MainActivity.instance?.get()?.reportAspect(uiState.aspect.label)
        },
        onPinAspect = { label -> pinAspect(label) },
        // Live streams are typically non-seekable, so "go to live" reloads the
        // source — reconnecting drops the buffer and resumes at the live edge.
        // Re-resolves first, through the same single-flight gate the reconnect
        // watchdog uses: the locator may already be spent, and two concurrent
        // `create_link` calls would exceed a single-connection account.
        onGoLive = {
            if (uiState.isLive) {
                stopCatchUp()
                val started = withFreshLiveLocator { engine?.load(url, subtitles) }
                if (started) uiState.liveSynced = true
            }
        },
        // Held "Go to live": **catch up at speed instead of reloading.**
        //
        // The chip only exists while the session is behind the edge (paused, or
        // the buffer fell back), and the engine is paused there — a raised speed
        // on a paused player would move nothing, so this resumes first. Releasing
        // restores 1×; at the edge the speed simply stops buying anything, and
        // the next tap still jumps by reload.
        onCatchUpStart = {
            if (uiState.isLive) {
                if (!uiState.isPlaying) engine?.playPause()
                engine?.setSpeed(CATCH_UP_SPEED)
                uiState.catchingUp = true
                logNative("catch-up start speed=$CATCH_UP_SPEED")
            }
        },
        onCatchUpStop = {
            if (uiState.catchingUp) {
                stopCatchUp()
                logNative("catch-up stop")
            }
        },
        // Toggled locally **and** reported straight away.
        //
        // The close-time `RESULT_FAVORITE` stays — it is the only report
        // guaranteed to survive a kill — but it can only describe one channel,
        // and zapping means the star may be pressed on a channel this session
        // has since left. Dart applies both to whichever channel is current
        // when it hears them, and an absolute set is idempotent, so the two
        // cannot disagree.
        onToggleFavorite = {
            val next = !uiState.isFavorite
            uiState.isFavorite = next
            sendZap(if (next) "favorite:1" else "favorite:0")
        },
        onBack = { finish() },
        onEnterPip = { enterPip() },
        onToggleOrientation = { toggleOrientationLock() },
        onZapCommand = { sendZap(it) },
    )

    override fun onStart() {
        super.onStart()
        progressTicker = lifecycleScope.launch {
            while (isActive) {
                engine?.syncProgress()
                pollLiveReconnect()
                samplePlaybackStats()
                // Faster while a frozen renderer is still attributable to the
                // fullscreen surface claim: that window is judged on
                // HANDOFF_POST_FRAME_STALL_MS, which the base cadence cannot
                // resolve (a single tick gap would decide it). Bounded by
                // HANDOFF_WINDOW_MS, so it costs five seconds per handoff and
                // nothing for the rest of the session.
                delay(
                    if (frameLiveness.inHandoffWindow(System.currentTimeMillis())) {
                        ReconnectPolicy.HANDOFF_POLL_MS
                    } else {
                        ReconnectPolicy.PROGRESS_TICK_MS
                    },
                )
            }
        }.also { job ->
            DebugCounters.incProgressTicker()
            // Fires exactly once whether the job is cancelled (onStop) or
            // completes on its own, so the counter can't double-decrement.
            job.invokeOnCompletion { DebugCounters.decProgressTicker() }
        }
    }

    override fun onStop() {
        super.onStop()
        progressTicker?.cancel()
        progressTicker = null
        // Keep playing while in PiP (onStop can fire around the PiP window on
        // some devices); only pause when actually backgrounded. An adopted engine
        // on its way back to the preview keeps playing too — pausing here would
        // put an audio gap in an otherwise seamless return.
        if (!uiState.inPip && !(isFinishing && adoptedShared)) engine?.pause()
    }

    /** Home / recents while playing → enter picture-in-picture instead of
     *  backgrounding. No-op on devices without PiP (e.g. some Android TVs). */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        enterPip()
    }

    /**
     * Player-only device preferences. Deliberately **not** Dart's settings store:
     * the orientation lock belongs to this Activity's window — leaving the
     * player ends its effect, and the choice is re-applied the next time one
     * opens. Nothing else in the app reads it.
     */
    private fun orientationPrefs() =
        getSharedPreferences(PlayerOrientation.PREFS_NAME, MODE_PRIVATE)

    /**
     * Applies the orientation mode to **this** Activity's window only, which is
     * what keeps the lock to "while watching": the channel list, Settings and
     * every other screen are separate Activities and follow the device.
     *
     * The mapping itself is [PlayerOrientation.requestedFor] — locked is
     * `SENSOR_LANDSCAPE`, not `LANDSCAPE`, so both landscape sides stay
     * available and the sensor picks the one that is up.
     */
    private fun applyOrientationLock(locked: Boolean) {
        requestedOrientation = PlayerOrientation.requestedFor(locked)
    }

    /** The chrome's orientation button: auto ⇄ landscape locked (sensor up). */
    private fun toggleOrientationLock() {
        val locked = !uiState.orientationLocked
        uiState.orientationLocked = locked
        // Written before the request, so a process death between the two still
        // remembers the choice the user just made.
        orientationPrefs()
            .edit()
            .putBoolean(PlayerOrientation.KEY_LOCKED, locked)
            .apply()
        applyOrientationLock(locked)
    }

    /**
     * Writes the brightness a swipe asked for **onto this window only**.
     *
     * `WindowManager.LayoutParams.screenBrightness` is a per-window override: the
     * system brightness (and every other app) keeps the value the user set, and
     * the override dies with this Activity — which is exactly what a player
     * gesture should do. Never stored: a brightness that outlived the session
     * would be a device setting changed from a picture.
     */
    private fun setWindowBrightness(value: Float) {
        val level = value.coerceIn(SwipeLevel.BRIGHTNESS_MIN, SwipeLevel.MAX)
        uiState.brightness = level
        window.attributes = window.attributes.apply { screenBrightness = level }
    }

    /**
     * What the panel starts from: the window's own override if this session
     * already set one, else the system's current brightness, else a mid level.
     *
     * Reading `Settings.System.SCREEN_BRIGHTNESS` needs no permission on any
     * supported API and is the only way to start a swipe from where the screen
     * actually is — starting at a fixed 50 % would dim or flash the picture on
     * the first pixel of travel.
     */
    private fun currentScreenBrightness(): Float {
        val override = window.attributes.screenBrightness
        if (override >= 0f) {
            return override.coerceIn(SwipeLevel.BRIGHTNESS_MIN, SwipeLevel.MAX)
        }
        val system = try {
            Settings.System.getInt(
                contentResolver,
                Settings.System.SCREEN_BRIGHTNESS,
            )
        } catch (_: Exception) {
            128
        }
        return (system / 255f).coerceIn(SwipeLevel.BRIGHTNESS_MIN, SwipeLevel.MAX)
    }

    /**
     * Drops any catch-up speed, so a zap, a "Go to live" tap or a new stream
     * never inherits the doubled rate. Idempotent.
     */
    private fun stopCatchUp() {
        if (!uiState.catchingUp && uiState.speed == 1f) return
        uiState.catchingUp = false
        engine?.setSpeed(1f)
    }

    /**
     * The long-press aspect menu: pin [label] to **this** channel, or apply the
     * device-wide mode when null ("Use global").
     */
    private fun pinAspect(label: String?) {
        val mode = if (label == null) {
            AspectMode.entries.firstOrNull { it.label == globalAspectLabel }
                ?: AspectMode.Fill
        } else {
            AspectMode.entries.firstOrNull { it.label == label } ?: return
        }
        aspectPinned = label != null
        uiState.aspectPinned = aspectPinned
        uiState.aspect = mode
        engine?.applyAspect(mode)
        val main = MainActivity.instance?.get()
        if (aspectPinned) {
            main?.reportAspectPin(mode.label)
        } else {
            main?.reportAspectGlobal()
        }
    }

    /**
     * The stream's proxy route for this session, or null when it fetches
     * direct (Settings -> Proxy, per content kind; Dart decided before launch).
     */
    private val streamRoute: StreamRoute? by lazy {
        StreamRoute.of(
            intent.getStringExtra(EXTRA_PROXY_HOST),
            intent.getIntExtra(EXTRA_PROXY_PORT, 0),
            intent.getStringExtra(EXTRA_PROXY_TYPE),
        )
    }

    /** Enters PiP if currently eligible; also invoked from a manual overlay button so entry
     *  doesn't depend solely on the OS calling [onUserLeaveHint] (inconsistent across OEMs). */    private fun enterPip() {
        if (uiState.inPip || isFinishing || !uiState.isPlaying) return
        if (!supportsPip()) return
        try {
            enterPictureInPictureMode(pipParams())
        } catch (e: Exception) {
            Log.e(TAG, "enterPictureInPictureMode failed", e)
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) enteredPip = true
        uiState.inPip = isInPictureInPictureMode
        if (isInPictureInPictureMode) {
            // Collapse all chrome so the PiP window is video-only.
            uiState.controlsVisible = false
            uiState.openMenu = PlayerMenu.None
            uiState.infoOpen = false
            // Behind the PiP window sits MainActivity's task showing the black
            // Flutter handoff route — recede *that* task so the launcher shows
            // instead. It must be moved via MainActivity: entering PiP reparents
            // this Activity into its own pinned task, so moveTaskToBack(false)
            // from here would send the PiP window itself to the back (black
            // screen all around — the original 0.1.13 bug).
            MainActivity.instance?.get()?.moveTaskToBack(true)
        }
    }

    private fun supportsPip(): Boolean =
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun pipParams(): PictureInPictureParams {
        val w = uiState.videoWidth
        val h = uiState.videoHeight
        // Android rejects extreme ratios; clamp to its allowed band, default 16:9.
        val ratio = if (w > 0 && h > 0) {
            Rational(w, h).coerceRatio()
        } else {
            Rational(16, 9)
        }
        return PictureInPictureParams.Builder()
            .setAspectRatio(ratio)
            // The system provides expand/close; these are the transport actions
            // iOS/Windows show in their mini bars. Android displays as many as
            // `getMaxNumPictureInPictureActions` allows, in this order.
            .setActions(
                listOf(
                    pipAction(
                        PIP_ACTION_PLAY_PAUSE,
                        if (uiState.isPlaying) android.R.drawable.ic_media_pause
                        else android.R.drawable.ic_media_play,
                        if (uiState.isPlaying) "Pause" else "Play",
                        1,
                    ),
                    pipAction(
                        PIP_ACTION_PREVIOUS,
                        android.R.drawable.ic_media_previous,
                        "Previous",
                        2,
                    ),
                    pipAction(
                        PIP_ACTION_NEXT,
                        android.R.drawable.ic_media_next,
                        "Next",
                        3,
                    ),
                    pipAction(
                        PIP_ACTION_MUTE,
                        if (uiState.muted || uiState.volume <= 0f) {
                            android.R.drawable.ic_lock_silent_mode_off
                        } else {
                            android.R.drawable.ic_lock_silent_mode
                        },
                        if (uiState.muted || uiState.volume <= 0f) "Unmute" else "Mute",
                        4,
                    ),
                ),
            )
            .build()
    }

    /** One PiP menu action, delivered to [PipActionReceiver]. */
    private fun pipAction(
        command: String,
        iconRes: Int,
        title: String,
        requestCode: Int,
    ): RemoteAction {
        val intent = Intent(this, PipActionReceiver::class.java)
            .setAction(ACTION_PIP)
            .putExtra(EXTRA_PIP_COMMAND, command)
        val pending = PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return RemoteAction(
            Icon.createWithResource(this, iconRes),
            title,
            title,
            pending,
        )
    }

    /** Runs a PiP menu action while the Activity is alive. */
    private fun onPipAction(command: String) {
        if (!::uiState.isInitialized) return
        when (command) {
            PIP_ACTION_PLAY_PAUSE -> {
                engine?.playPause()
                refreshPipActions()
            }
            PIP_ACTION_PREVIOUS -> sendZap("zap:down")
            PIP_ACTION_NEXT -> sendZap("zap:up")
            PIP_ACTION_MUTE -> {
                engine?.toggleMute()
                refreshPipActions()
            }
        }
    }

    /** Rebuilds the PiP menu once the engine's state change has landed. */
    private fun refreshPipActions() {
        if (!uiState.inPip) return
        window.decorView.postDelayed(
            {
                if (!isFinishing && uiState.inPip) {
                    setPictureInPictureParams(pipParams())
                }
            },
            200L,
        )
    }

    /** Clamp to Android's accepted aspect band (~0.418..2.39) to avoid a crash. */
    private fun Rational.coerceRatio(): Rational {
        val value = numerator.toDouble() / denominator.toDouble()
        return when {
            value < 0.42 -> Rational(42, 100)
            value > 2.39 -> Rational(239, 100)
            else -> this
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE -> { engine?.playPause(); return true }
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                if (!uiState.isLive) engine?.seekBy(10_000); return true
            }
            KeyEvent.KEYCODE_MEDIA_REWIND -> {
                if (!uiState.isLive) engine?.seekBy(-10_000); return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    /**
     * Every exit path funnels through finish() (including system Back via the
     * dispatcher), so report the final playback position here — the Dart side
     * persists it as the VOD resume point when [MainActivity] relays it on
     * `nativeClosed`.
     */
    override fun finish() {
        if (::uiState.isInitialized) {
            val result = Intent()
            var hasResult = false
            if (!uiState.isLive) {
                result.putExtra(RESULT_POSITION_MS, uiState.positionMs)
                result.putExtra(RESULT_DURATION_MS, uiState.durationMs)
                hasResult = true
            }
            // Report the final favorite state (live or VOD) so Dart can persist
            // it — this is the only channel back to the store from this Activity.
            if (uiState.canFavorite) {
                result.putExtra(RESULT_FAVORITE, uiState.isFavorite)
                hasResult = true
            }
            // The aspect the user left the player in, so the choice outlives
            // this Activity — Dart persists it per source. Reported for VOD
            // too, unlike the favorite: framing is a property of the source,
            // and a mode chosen while watching a film is just as deliberate as
            // one chosen on a channel.
            result.putExtra(RESULT_ASPECT, uiState.aspect.label)
            hasResult = true
            // The final audio state: a mute/level chosen inside this Activity
            // is the input to the next open anywhere (see EXTRA_VOLUME). 0
            // while muted — the Dart session reads `record(0)` as mute.
            // The audible level, even while muted: Dart keeps level and mute
            // flag apart so unmuting later restores this level, not 100%.
            result.putExtra(
                RESULT_VOLUME,
                if (uiState.muted || uiState.volume <= 0f) uiState.audibleVolume
                else uiState.volume,
            )
            result.putExtra(RESULT_MUTED, uiState.muted)
            logNative(
                "audio result volume=${if (uiState.muted || uiState.volume <= 0f) uiState.audibleVolume else uiState.volume} " +
                    "muted=${uiState.muted} stateVolume=${uiState.volume}",
            )
            hasResult = true
            if (hasResult) setResult(RESULT_OK, result)
        }
        // Hand the adopted engine back *now*, not in onDestroy. The result
        // above reaches Dart as soon as MainActivity resumes, while onDestroy
        // of a finishing Activity waits for the next one to go idle — on a
        // busy TV box, seconds. A zapped session's return leg (stop,
        // re-resolve, open the ended channel) ran entirely inside that gap and
        // found the engine still adopted; and an un-zapped return sat on the
        // preview's frozen last frame until it closed.
        handBackSharedEngine()
        if (enteredPip) restoreMainTaskAfterPip()
        super.finish()
    }

    /**
     * Returns an adopted engine to the preview. Idempotent: [finish] calls it
     * first, and [onDestroy] covers any exit that never went through finish.
     * [engine] is dropped with it, so nothing in this Activity's remaining
     * lifetime (onStop's pause, a straggling ticker) can touch an engine the
     * preview now owns.
     */
    private fun handBackSharedEngine() {
        if (!adoptedShared) return
        adoptedShared = false
        engine = null
        SharedEngine.fullscreenDetached()
    }

    /**
     * PiP places this Activity in a pinned task and the Flutter task is moved
     * behind the launcher on entry.  Reorder the already-running MainActivity
     * task before finishing so nativeClosed is delivered into the visible
     * Flutter route rather than leaving the user at the home screen.
     */
    private fun restoreMainTaskAfterPip() {
        if (MainActivity.instance?.get() == null) return
        try {
            startActivity(
                Intent(this, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                ),
            )
        } catch (e: Exception) {
            Log.w(TAG, "could not restore Flutter task after PiP", e)
        }
    }

    override fun onDestroy() {
        if (instance?.get() === this) instance = null
        soakAutoCloseJob?.cancel()
        soakAutoCloseJob = null
        // lifecycleScope cancels this anyway; dropping the reference here also
        // releases the captured reload callback immediately.
        resolveTimeoutJob?.cancel()
        resolveTimeoutJob = null
        if (adoptedShared) {
            // Not ours to release: hand the video output back to the preview
            // surface; the engine keeps playing across the return.
            handBackSharedEngine()
        } else {
            engine?.release()
        }
        engine = null
        super.onDestroy()
    }

    private fun requestHeaders(): Map<String, String> {
        val keys = intent.getStringArrayListExtra(EXTRA_HEADER_KEYS).orEmpty()
        val values = intent.getStringArrayListExtra(EXTRA_HEADER_VALUES).orEmpty()
        return keys.mapIndexedNotNull { index, key ->
            val value = values.getOrNull(index)
            if (key.isBlank() || value.isNullOrBlank()) null else key to value
        }.toMap()
    }

    private fun subtitleSpecs(): List<SubtitleSpec> {
        val urls = intent.getStringArrayListExtra(EXTRA_SUBTITLE_URLS).orEmpty()
        val labels = intent.getStringArrayListExtra(EXTRA_SUBTITLE_LABELS).orEmpty()
        val languages = intent.getStringArrayListExtra(EXTRA_SUBTITLE_LANGUAGES).orEmpty()
        return urls.mapIndexedNotNull { index, subUrl ->
            if (subUrl.isBlank()) {
                null
            } else {
                SubtitleSpec(
                    url = subUrl,
                    label = labels.getOrNull(index).orEmpty(),
                    language = languages.getOrNull(index).orEmpty(),
                )
            }
        }
    }

    /**
     * Ten-foot player chrome. Shares [isTelevisionDevice] with `MainActivity`'s
     * `iptvs/device` answer so the player and the browsing layout can't
     * disagree — they did once, and the result was a set-top box with a
     * two-pane channel list and handset-sized player controls.
     */
    private fun isTelevision(): Boolean = isTelevisionDevice(this)

    /** Builds an [com.gchofficial.iptvs.player.EpgEntry] from intent extras, or null if absent/invalid. */
    private fun epgEntry(
        titleKey: String,
        startKey: String,
        stopKey: String,
        descKey: String?,
    ): com.gchofficial.iptvs.player.EpgEntry? {
        val title = intent.getStringExtra(titleKey)?.takeIf { it.isNotBlank() } ?: return null
        val start = intent.getLongExtra(startKey, -1L)
        val stop = intent.getLongExtra(stopKey, -1L)
        if (start < 0L || stop <= start) return null
        return com.gchofficial.iptvs.player.EpgEntry(
            title = title,
            startMs = start,
            stopMs = stop,
            description = descKey?.let { intent.getStringExtra(it) }?.takeIf { it.isNotBlank() },
        )
    }

    /**
     * Immersive fullscreen, via the supported inset API.
     *
     * The old `systemUiVisibility` flag set has been deprecated since API 30, and
     * from targetSdk 35 its `LAYOUT_*` half is meaningless anyway: edge-to-edge is
     * enforced and `setDecorFitsSystemWindows` is disabled, so the window already
     * extends behind the bars. [WindowInsetsControllerCompat] is the replacement;
     * `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE` reproduces `IMMERSIVE_STICKY` — a
     * swipe reveals the bars transiently and they hide themselves again.
     *
     * [WindowCompat.setDecorFitsSystemWindows] is kept for API 26–34, where it is
     * still what makes the window lay out edge-to-edge (it is the no-op on 35+,
     * not the other way round).
     */
    private fun hideSystemUi() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    companion object {
        /**
         * The live player Activity, while one exists.
         *
         * [MainActivity] routes the inbound zap methods (`zapTo`,
         * `setZapBanner`, `setQuickList`) here: they are Dart→native pushes
         * for a *running*
         * player, and a MethodChannel can only be registered once per process
         * — so the channel handler stays in `MainActivity` and forwards, the
         * same shape `logPlaybackDiagnostic` already uses in the other
         * direction.
         */
        var instance: WeakReference<HdrPlayerActivity>? = null
            private set

        /**
         * The last zap modes Dart pushed, kept for the gap between `open`
         * returning and [onCreate] building `uiState`.
         *
         * Dart seeds the overflow menu's checkmarks right after `open`, which is
         * a plain MethodChannel answer while `startActivity` is asynchronous —
         * so the seed can arrive before there is any `uiState` to write to. It
         * used to be dropped there, and "Random zapping" showed no checkmark
         * until the user toggled it once.
         */
        @Volatile
        private var pendingRandomZapping: Boolean? = null

        @Volatile
        private var pendingAutoSwitch: Boolean? = null

        /** The auto-switch pace and its ladder, for the same pre-`onCreate` window. */
        @Volatile
        private var pendingDwellSeconds: Int? = null

        @Volatile
        private var pendingDwellOptions: List<Int>? = null

        /**
         * Stores the modes for an Activity that does not exist yet.
         *
         * `MainActivity` used to drop a `setZapModes` push outright when
         * [instance] was null — which is *always* the case for the seed Dart
         * sends right after `open`, because `startActivity` is asynchronous.
         * The overlay then drew random/auto-switch as **off** until the user
         * toggled one, even though the zap controller had started with the
         * device preference on. The push now lands here instead, and
         * `onCreate` applies it.
         */
        fun seedZapModes(
            random: Boolean?,
            autoSwitch: Boolean?,
            dwellSeconds: Int? = null,
            dwellOptions: List<Int>? = null,
        ) {
            random?.let { pendingRandomZapping = it }
            autoSwitch?.let { pendingAutoSwitch = it }
            dwellSeconds?.let { pendingDwellSeconds = it }
            if (!dwellOptions.isNullOrEmpty()) pendingDwellOptions = dwellOptions
        }

        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_IS_LIVE = "is_live"
        const val EXTRA_SOURCE_NAME = "source_name"
        const val EXTRA_EPG_NOW_TITLE = "epg_now_title"
        const val EXTRA_EPG_NOW_START = "epg_now_start"
        const val EXTRA_EPG_NOW_STOP = "epg_now_stop"
        const val EXTRA_EPG_NOW_DESC = "epg_now_desc"
        const val EXTRA_EPG_NEXT_TITLE = "epg_next_title"
        const val EXTRA_EPG_NEXT_START = "epg_next_start"
        const val EXTRA_EPG_NEXT_STOP = "epg_next_stop"
        const val EXTRA_HEADER_KEYS = "header_keys"
        const val EXTRA_HEADER_VALUES = "header_values"
        const val EXTRA_SUBTITLE_URLS = "subtitle_urls"
        const val EXTRA_SUBTITLE_LABELS = "subtitle_labels"
        const val EXTRA_SUBTITLE_LANGUAGES = "subtitle_languages"

        /** Adopt the shared preview engine instead of loading fresh (see [SharedEngine]). */
        const val EXTRA_ADOPT_SHARED = "adopt_shared"
        const val EXTRA_BUFFER_PRESET = "buffer_preset"
        const val EXTRA_ASPECT = "aspect"

  /** Whether [EXTRA_ASPECT] is this channel's own pin, not the global mode. */
  const val EXTRA_ASPECT_PINNED = "aspectPinned"

  /** The device-wide aspect label, for the long-press menu's "Use global". */
  const val EXTRA_GLOBAL_ASPECT = "globalAspect"

        /**
         * Session-wide start volume (0..1) — the Dart [PlaybackAudioSession]
         * riding along. This Activity owns a fresh audio session, so without it
         * every channel change would come back at full volume.
         */
        const val EXTRA_VOLUME = "volume"

        /** Whether to draw the previous/next pair (live zap or VOD step). */
        const val EXTRA_STEP_ENABLED = "stepEnabled"

        /** Mute flag from Dart's session (see [RESULT_MUTED]). */
        const val EXTRA_MUTED = "muted"

        /** Level to restore after unmuting (see [PlayerUiState.audibleVolume]). */
        const val EXTRA_AUDIBLE_VOLUME = "audibleVolume"

  /**
   * Which half of the picture changes the **volume** on a vertical swipe; the
   * other half changes the brightness. Absent (an older Dart build) reads as
   * `true`, the layout every release so far had.
   */
  const val EXTRA_VOLUME_SWIPE_ON_LEFT = "volumeSwipeOnLeft"

  /**
   * The proxy a **stream** of this session's content kind is fetched through:
   * resolved by Dart from Settings -> Proxy ("Streams: Live / Movies / Series")
   * and absent when the user never asked for one (the default, and what every
   * build before that setting did). Empty host or zero port means direct.
   * [EXTRA_PROXY_TYPE] is the platform's own vocabulary, `HTTP` or `SOCKS`.
   */
  const val EXTRA_PROXY_HOST = "proxyHost"
  const val EXTRA_PROXY_PORT = "proxyPort"
  const val EXTRA_PROXY_TYPE = "proxyType"

        /** VOD resume: start playback at this position (ms), 0 = from the top. */
        const val EXTRA_RESUME_MS = "resume_ms"

        /**
         * Debug-only: auto-`finish()` this many ms after open, so an
         * integration-test soak can cycle the Activity unattended. Read only
         * when [BuildConfig.DEBUG]; absent/non-positive means never scheduled.
         */
        const val EXTRA_SOAK_AUTOCLOSE_MS = "soak_autoclose_ms"

        /** Favorite toggle (live channels): whether to show the star + its seed state. */
        const val EXTRA_CAN_FAVORITE = "can_favorite"
        const val EXTRA_IS_FAVORITE = "is_favorite"
        const val EXTRA_ZAP_ENABLED = "zap_enabled"

        /**
         * Device-wide chrome preferences from Settings, sent on the `open` Intent
         * because this Activity has no inbound control-state channel (see
         * `PlayerScreen._drivesNativeControlState`, which deliberately excludes
         * Android). Defaults to true on read, matching `PlayerUiState`'s own
         * defaults, so an older Dart build keeps the chrome it draws today.
         */
        const val EXTRA_SHOW_CLOCK = "show_clock"
        const val EXTRA_SHOW_TIMES = "show_times"

        /**
         * Whether the chrome draws the channel/title name (Settings → "Channel
         * name in the player"). Absent reads as true.
         */
        const val EXTRA_SHOW_CHANNEL_NAME = "show_channel_name"

        /**
         * Comma list of optional controls the chrome must **not** draw (see
         * `PlayerControl.storageName` in `lib/player/player_controls_prefs.dart`).
         *
         * Absent or empty means everything is shown; unknown names are ignored,
         * so a newer Dart build can hide only the controls this build knows.
         */
        const val EXTRA_HIDDEN_CONTROLS = "hidden_controls"

        /**
         * What a double tap on the picture does — `DoubleTapAction.wire`.
         *
         * Absent reads as previous/next, the default.
         */
        const val EXTRA_DOUBLE_TAP = "double_tap"

        /**
         * How far the ±seek buttons and a seek double tap move a title, in
         * seconds (Settings → "VOD seek step"). Absent keeps 10 s, which is what
         * the overlay hard-coded before the preference existed.
         */
        const val EXTRA_SEEK_STEP = "seek_step_seconds"

        /** Result extras: final position/duration + favorite, for the Dart stores. */
        const val RESULT_POSITION_MS = "position_ms"
        const val RESULT_DURATION_MS = "duration_ms"
        const val RESULT_FAVORITE = "favorite"
        const val RESULT_ASPECT = "aspect"

        /**
         * Final audio state (0..1): a mute/level chosen inside this Activity is
         * the input to the *next* open anywhere (see [EXTRA_VOLUME]).
         */
        const val RESULT_VOLUME = "volume"

        /**
         * The user's mute flag, separate from [RESULT_VOLUME]'s audible level:
         * Dart's session keeps them apart so unmuting restores the level.
         */
        const val RESULT_MUTED = "muted"

        /** PiP menu actions (see [pipAction]) and their receiver contract. */
        const val ACTION_PIP = "com.gchofficial.iptvs.PIP_ACTION"
        const val EXTRA_PIP_COMMAND = "pip_command"
        const val PIP_ACTION_PLAY_PAUSE = "playPause"
        const val PIP_ACTION_PREVIOUS = "previous"
        const val PIP_ACTION_NEXT = "next"
        const val PIP_ACTION_MUTE = "mute"

        /** Runs a PiP action on the live player, if there is one. */
        fun handlePipAction(command: String?) {
            if (command == null) return
            instance?.get()?.onPipAction(command)
        }

        /**
         * Local decoder rebuilds allowed per handoff. One: a second would be a
         * loop with a stall threshold, and the failure it treats is a
         * one-time event (a surface switch) that a rebuild either survives or
         * doesn't. See [tryHandoffDecoderRebuild].
         */
        private const val MAX_HANDOFF_REBUILDS = 1
        private const val TAG = "iptvs.hdr"

        /**
         * Speed a held "Go to live" plays at: double, because a viewer catching
         * up wants the wait halved, and anything faster makes the picture
         * unwatchable as a preview of where they are heading.
         */
        const val CATCH_UP_SPEED = 2f
    }
}

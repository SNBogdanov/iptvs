package com.gchofficial.iptvs.player

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
// Shadows `kotlin.collections.List` inside this file — an explicit import wins
// over a default one. Harmless today (nothing here names the collection type)
// and kept because it is the icon's real name, but anything added below that
// wants a `List<T>` must spell it `kotlin.collections.List`.
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.BrightnessHigh
import androidx.compose.material.icons.filled.ClosedCaption
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Forward30
import androidx.compose.material.icons.filled.Forward5
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Replay30
import androidx.compose.material.icons.filled.Replay5
import androidx.compose.material.icons.filled.ScreenRotation
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.StayCurrentLandscape
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.onSizeChanged
import android.view.View
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import android.os.SystemClock
import kotlin.math.roundToInt

/** Player actions the overlay invokes; implemented by the Activity over ExoPlayer. */
class PlayerCallbacks(
    val onPlayPause: () -> Unit,
    val onSeekTo: (Long) -> Unit,
    val onSeekBy: (Long) -> Unit,
    val onSetVolume: (Float) -> Unit,
    val onToggleMute: () -> Unit,
    /**
     * A brightness swipe's level (0..1) — Android only, and session-scoped: the
     * Activity writes it to its own window, so the rest of the system keeps the
     * brightness the user set.
     */
    val onSetBrightness: (Float) -> Unit,
    val onSelectAudio: (String) -> Unit,
    val onSelectSubtitle: (String) -> Unit,
    val onSetSpeed: (Float) -> Unit,
    val onCycleAspect: () -> Unit,
    /** Long-press aspect menu: pin [label] to this channel, or null for global. */
    val onPinAspect: (String?) -> Unit,
    val onGoLive: () -> Unit,
    /**
     * "Go to live" held down: resume if paused and play at double speed until
     * the finger lifts ([onCatchUpStop]), instead of reloading at the edge.
     */
    val onCatchUpStart: () -> Unit,
    val onCatchUpStop: () -> Unit,
    val onToggleFavorite: () -> Unit,
    val onBack: () -> Unit,
    val onEnterPip: () -> Unit,
    /** Toggles "landscape locked" vs "follow the device" for this Activity. */
    val onToggleOrientation: () -> Unit,
    /**
     * One member of the shared zap vocabulary (`lib/player/zap_command.dart`)
     * sent to Dart. The overlay's only use for it is the quick list's
     * *pointer* path: every key that drives the list is claimed at the
     * Activity boundary by [ZapKeyPolicy] and never reaches Compose.
     */
    val onZapCommand: (String) -> Unit,
)

private const val HIDE_DELAY_VOD = 3500L
private const val HIDE_DELAY_LIVE = 4500L

/**
 * Remembers which control in the player chrome held the D-pad focus **last**.
 *
 * The chrome is composed through `AnimatedVisibility`, so hiding it removes its
 * children from composition — and every `FocusRequester` inside them with it.
 * Re-showing therefore had nothing to restore and parked focus on play/pause,
 * i.e. pressing OK to bring the bar back always landed on the first button
 * instead of the one the user had been on. The requester objects themselves
 * outlive the controls (they are `remember`ed per call site and re-attached
 * when the child recomposes), so remembering the object is enough; a control
 * that is gone for good fails to take focus and the caller falls back to
 * play/pause.
 *
 * A process-wide object rather than a `CompositionLocal`: only one player
 * route is ever composed, the chrome lives under a conditional whose scopes
 * nest deeply, and `PlayerScreen` clears this on dispose.
 */
object PlayerFocusMemory {
    var last: FocusRequester? = null
}

/**
 * Root of the native player UI: the ExoPlayer surface with a Compose control
 * overlay on top. Mirrors the Windows native overlay (top bar + badges, bottom
 * bar with contextual right cluster, list-menus, info panel) and is D-pad
 * navigable for Android TV.
 */
@Composable
fun PlayerScreen(
    state: PlayerUiState,
    videoView: View,
    callbacks: PlayerCallbacks,
) {
    val rootFocus = remember { FocusRequester() }
    val playFocus = remember { FocusRequester() }
    // The bolt (auto-switch) button: the pace menu is opened by a long press on
    // it, and closing that menu must hand focus back to it.
    val zapFocus = remember { FocusRequester() }
    // The focus memory is process-wide (see [PlayerFocusMemory]); clear it when
    // this player goes away so the next session starts on play/pause.
    DisposableEffect(Unit) {
        onDispose { PlayerFocusMemory.last = null }
    }
    // Bumped on any interaction to (re)arm the auto-hide timer.
    var interaction by remember { mutableIntStateOf(0) }
    // Wall-clock tick driving the clock badge and the live EPG progress (slow —
    // both move on the order of a minute, so 10s granularity is plenty).
    var nowMillis by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            nowMillis = System.currentTimeMillis()
            kotlinx.coroutines.delay(10_000)
        }
    }

    fun poke() {
        interaction++
        state.controlsVisible = true
    }

    // Auto-hide: hide after the timeout unless pinned (a menu / info panel open)
    // or playback is paused.
    LaunchedEffect(interaction, state.pinned, state.isPlaying, state.controlsVisible) {
        if (state.controlsVisible && !state.pinned && state.isPlaying) {
            kotlinx.coroutines.delay(if (state.isLive) HIDE_DELAY_LIVE else HIDE_DELAY_VOD)
            state.controlsVisible = false
        }
    }

    // The zap banner fades on its own timer, deliberately **not** on
    // `controlsVisible`: it is the only acknowledgement a keypress gets while
    // the chrome is hidden, which is exactly when zapping is used. Keyed on
    // the push timestamp, so each press restarts the countdown instead of
    // stacking timers.
    LaunchedEffect(state.zapBannerAtMs) {
        if (state.zapBannerAtMs == 0L) return@LaunchedEffect
        kotlinx.coroutines.delay(ZAP_BANNER_VISIBLE_MS)
        state.zapBannerVisible = false
    }

    // The swipe level panel hides on the same rule: its own countdown, keyed on
    // the last change, so a continuous gesture keeps it up and it leaves shortly
    // after the finger does. Shorter than the banner's: the level is not
    // information to read, only feedback to confirm.
    LaunchedEffect(state.levelPanelAtMs) {
        if (state.levelPanelAtMs == 0L) return@LaunchedEffect
        kotlinx.coroutines.delay(LEVEL_PANEL_VISIBLE_MS)
        state.levelPanelKind = null
    }

    // Move focus to the controls when shown; park it on the root when hidden so a
    // D-pad press can reveal them again.
    //
    // Shown again → the control that had focus when the bar hid, not the first
    // one: the bar is the same bar, and re-entering it always at play/pause made
    // every "hide, then bring it back" trip re-walk the row. A control that is no
    // longer in the ring (Go to live once live, the step pair on another route,
    // a menu that closed) fails `requestFocus` and the play button takes it.
    //
    // The *show* half runs inside [ControlsOverlay] instead of here: the bar is
    // wrapped in an `AnimatedVisibility`, so on the frame the flag flips its
    // children are composed but not yet placed, and a `requestFocus` made now
    // fails silently — the bar then appeared with **no control focused at all**
    // and the next OK landed on the first one. The overlay waits one frame in
    // its own `LaunchedEffect`, by which point the buttons are placed.
    LaunchedEffect(state.controlsVisible) {
        if (!state.controlsVisible) {
            state.openMenu = PlayerMenu.None
            state.infoOpen = false
            state.dwellMenuOpen = false
            runCatching { rootFocus.requestFocus() }
        }
    }

    // The pace menu is a long press on the bolt; closing it — by choosing a
    // period or by Back — hands focus back to that button instead of dropping it
    // on nothing (the next OK then landed on the first control).
    var dwellMenuWasOpen by remember { mutableStateOf(false) }
    LaunchedEffect(state.dwellMenuOpen) {
        if (dwellMenuWasOpen && !state.dwellMenuOpen) {
            androidx.compose.runtime.withFrameNanos { }
            runCatching { zapFocus.requestFocus() }
        }
        dwellMenuWasOpen = state.dwellMenuOpen
    }

    // The system reserves the strip along the very top for the notification
    // shade even while the status bar is hidden (immersive), and the window
    // still delivers those moves here: a shade pull used to open the shade and
    // change the brightness at the same time. A gesture that *starts* in this
    // strip is left completely untouched. 40 dp rather than the status-bar
    // inset, because in immersive mode the inset reads as 0 while the shade
    // gesture area is still there.
    val topShadeEdgePx = with(LocalDensity.current) { 40.dp.toPx() }

    Box(
        Modifier
            .fillMaxSize()
            // Pure black behind the picture: the app's own `Ink` is a dark
            // blue-grey, and in a letterboxed frame that reads as "the player
            // has a grey background" rather than as a cinema screen.
            .background(Color.Black)
            .focusRequester(rootFocus)
            .focusable()
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                // With the quick list up, a key that the zap policy declined
                // must not throw the chrome over it: the list has the screen,
                // and reveal-on-any-key would put the control row on top of
                // the thing the user is reading.
                if (state.quickList.open) return@onPreviewKeyEvent false
                val wasHidden = !state.controlsVisible
                poke()
                wasHidden // consume the first key only to reveal controls
            },
    ) {
        // key() so swapping engines (ExoPlayer -> mpv fallback) rebuilds the host
        // with the new engine's view.
        //
        // Hosting the video here rather than attaching it to the Activity's
        // content in `onCreate` costs nothing: `AndroidView` adds the SurfaceView
        // during the first composition, inside the window's first traversal, so
        // a pre-attached view would be laid out in that same traversal. Measured
        // both ways on a TV emulator — see docs/player.md.
        key(videoView) {
            AndroidView(factory = { videoView }, modifier = Modifier.fillMaxSize())
        }

        // Tap layer (below the controls) toggles visibility on touch devices.
        // Skipped in PiP: the tiny window shows video only, no control chrome.
        // Skipped with the quick list up for the same reason the root key
        // handler is: the list owns the screen until it is dismissed.
        // A tap must not hide the chrome while a menu or the info panel is up.
        // The pointer-up of the very long press that OPENED the pace menu
        // otherwise landed on this layer and hid the chrome — and hiding the
        // chrome closes every menu, so the list of periods flashed and vanished
        // in the same instant. Panels are dismissed by Back or by choosing a row.
        if (!state.inPip && !state.quickList.open && !state.pinned) {
            Box(
                Modifier
                    .fillMaxSize()
                    // **Two level gestures, one per side.** The side the finger
                    // *starts* on decides what the whole gesture changes —
                    // volume on one half, brightness on the other (which half is
                    // which is the Settings tile's choice, `volumeSwipeOnLeft`).
                    // Up is more; a full height is the whole range
                    // (`SwipeLevel`), so the same travel means the same change
                    // on a phone and on a TV panel. Attached ahead of the tap
                    // layer and under the same conditions: a tap never travels
                    // past the drag slop, and a drag consumes its movement, so
                    // the two cannot both fire.
                    //
                    // Volume is a **level** control, never a mute: its range
                    // stops at one percent, so swiping to the bottom cannot
                    // silence the player, and only a mute the *button* made
                    // keeps the volume half out (`mutedByButton`) — the engine
                    // reports a zero volume as muted too, and a swipe must not
                    // be trapped by its own floor. Brightness floors at five
                    // percent for the other reason: a black screen cannot be
                    // swiped back by someone who cannot see the picture.
                    .pointerInput(state.mutedByButton, state.volumeSwipeOnLeft) {
                        var target = SwipeTarget.Volume
                        var level = 0f
                        // **A custom drag, not `detectVerticalDragGestures`.** That
                        // detector claims a gesture as soon as the vertical
                        // movement passes the slop, so a horizontal swipe with a
                        // few pixels of drift was read as "raise the volume" —
                        // and consumed, so nothing else could have it. Here the
                        // axis is decided once, from the ratio of both movements
                        // (`SwipeAxisRule`), and a mostly-horizontal drag is left
                        // untouched from the moment it passes the slop.
                        awaitEachGesture {
                            val down = awaitFirstDown(requireUnconsumed = false)
                            // A pull from the status-bar strip is the system's
                            // notification shade. The player must not read it as
                            // a level change, or the shade opens *and* the
                            // brightness moves under it.
                            if (down.position.y < topShadeEdgePx) {
                                return@awaitEachGesture
                            }
                            target = SwipeSides.targetFor(
                                down.position.x,
                                size.width.toFloat(),
                                state.volumeSwipeOnLeft,
                            )
                            var dx = 0f
                            var dy = 0f
                            var claimed = false
                            while (true) {
                                val event = awaitPointerEvent()
                                val change = event.changes.firstOrNull { it.id == down.id }
                                    ?: break
                                if (!change.pressed) break
                                dx += change.positionChange().x
                                dy += change.positionChange().y
                                if (!claimed) {
                                    when (
                                        SwipeAxisRule.decide(
                                            dx,
                                            dy,
                                            viewConfiguration.touchSlop,
                                        )
                                    ) {
                                        SwipeAxis.Horizontal -> break
                                        SwipeAxis.Undecided -> continue
                                        SwipeAxis.Vertical -> {
                                            if (target == SwipeTarget.Volume &&
                                                state.mutedByButton
                                            ) {
                                                break
                                            }
                                            claimed = true
                                            level = when (target) {
                                                SwipeTarget.Volume -> state.volume
                                                SwipeTarget.Brightness -> state.brightness
                                            }
                                        }
                                    }
                                }
                                change.consume()
                                val kind = when (target) {
                                    SwipeTarget.Volume -> LevelPanelKind.Volume
                                    SwipeTarget.Brightness -> LevelPanelKind.Brightness
                                }
                                level = SwipeLevel.apply(
                                    level,
                                    dy,
                                    size.height.toFloat(),
                                    if (target == SwipeTarget.Brightness) {
                                        SwipeLevel.BRIGHTNESS_MIN
                                    } else {
                                        SwipeLevel.VOLUME_MIN
                                    },
                                )
                                when (target) {
                                    SwipeTarget.Volume -> callbacks.onSetVolume(level)
                                    SwipeTarget.Brightness ->
                                        callbacks.onSetBrightness(level)
                                }
                                // A timestamp, not a flag: a second swipe while
                                // the panel is fading restarts its countdown.
                                state.levelPanelKind = kind
                                state.levelPanelValue = level
                                state.levelPanelAtMs = SystemClock.elapsedRealtime()
                                // The accumulated delta has been applied; the
                                // next frame's movement is what comes next.
                                dy = 0f
                            }
                        }
                    }
                    .pointerInput(state.doubleTapAction, state.isLive, state.stepEnabled) {
                        val half = size.width / 2f
                        detectTapGestures(
                            onTap = {
                                if (state.controlsVisible) {
                                    state.controlsVisible = false
                                } else {
                                    poke()
                                }
                            },
                            // Left half goes back/previous, right half
                            // forward/next — the gesture every touch player
                            // offers, and the reason `onTap` now waits out the
                            // double-tap window before toggling the chrome.
                            onDoubleTap = { offset ->
                                val forward = offset.x >= half
                                val step = state.seekStepSeconds.coerceAtLeast(1) * 1_000L
                                // Live always steps the channel: the setting
                                // exists for titles, where "seek" and "next
                                // entry" are genuinely different intents, and
                                // seeking a live stream is not a thing. Leaving
                                // the choice in force there made a double tap
                                // do nothing at all once "Seek" was picked.
                                val action = if (state.isLive) {
                                    DoubleTapAction.PreviousNext
                                } else {
                                    state.doubleTapAction
                                }
                                when (action) {
                                    // The configured VOD step, not a hard 10 s:
                                    // the ±buttons beside the scrubber move by
                                    // the same amount.
                                    DoubleTapAction.Seek -> if (!state.isLive) {
                                        callbacks.onSeekBy(if (forward) step else -step)
                                    }
                                    DoubleTapAction.PreviousNext -> if (state.stepEnabled) {
                                        callbacks.onZapCommand(if (forward) "zap:up" else "zap:down")
                                    }
                                }
                            },
                        )
                    },
            )
        }

        if (state.videoUnsupported) {
            UnsupportedVideoNotice(
                reason = state.videoUnsupportedReason,
                modifier = Modifier.align(Alignment.Center),
            )
        }

        // The swipe's own level indicator, drawn over the picture and
        // independent of the chrome: a viewer adjusts the sound or the picture
        // with the bars down, and the panel is the only feedback the gesture
        // would otherwise have. One panel for both gestures, on the side that
        // owns the level being changed.
        AnimatedVisibility(
            visible = state.levelPanelKind != null && !state.inPip,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            LevelPanel(state)
        }

        if (state.reconnecting) {
            ReconnectingNotice(modifier = Modifier.align(Alignment.Center))
        }

        // Below the bars on purpose: the two are mutually exclusive by the
        // `!controlsVisible` gate, but their fades overlap, and the bar (which
        // carries the same information plus the controls) should win.
        AnimatedVisibility(
            visible = state.showZapBanner && !state.controlsVisible,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            ZapBanner(state, nowMillis)
        }

        AnimatedVisibility(
            visible = state.controlsVisible && !state.inPip,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            ControlsOverlay(state, callbacks, playFocus, zapFocus, nowMillis) { poke() }
        }

        // What the corners keep while the chrome is down: the wall clock and,
        // on VOD, how far into the title the viewer is. The shared Flutter
        // overlay has always had this HUD, and without it two Settings
        // preferences were invisible on Android the moment the bars faded — a
        // phone showed neither a clock (its status bar is gone in immersive
        // mode) nor a position, which read as "the current time and the
        // playback time are missing".
        AnimatedVisibility(
            visible = !state.controlsVisible && !state.inPip && !state.quickList.open,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            PersistentHud(state, nowMillis)
        }

        // Above the bars: the quick list is what the user is looking at while
        // it is open, and the Activity hides the chrome as it arrives anyway.
        AnimatedVisibility(
            visible = state.showQuickList,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            QuickListPanel(
                state,
                onActivateRow = { row ->
                    // A tap names a row; the cursor is still Dart's to move, so
                    // this is "put the cursor here, then OK" rather than a second
                    // way to activate - one path, one set of rules.
                    val delta = row.index - state.quickList.selectedIndex
                    if (delta != 0) callbacks.onZapCommand("zap:move:$delta")
                    callbacks.onZapCommand("zap:activate")
                },
                // Phones and tablets: an explicit close, because the panel has
                // no Back key and the OS gesture means summoning the system bar
                // over a fullscreen picture first.
                onClose = if (state.isTv) {
                    null
                } else {
                    { callbacks.onZapCommand("zap:close") }
                },
                // Pointer dismissal is platform-blind: a tap on the picture
                // outside the panel closes it, which is the one gesture a
                // touch user will try first.
                onDismiss = { callbacks.onZapCommand("zap:close") },
            )
        }

        // Menus + info panel sit above the bars; they imply controls are visible.
        // Inset as one group (same reasoning as ControlsOverlay) — their
        // BottomEnd/TopEnd alignment would otherwise put them in the cutout on a
        // notched phone, which the Activity's layoutInDisplayCutoutMode
        // (ALWAYS on API 30+, SHORT_EDGES on 28-29) lets the window extend into.
        if (state.controlsVisible && !state.inPip) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                PlayerMenusLayer(state, callbacks) { poke() }
                if (state.infoOpen) {
                    InfoPanel(
                        state = state,
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            // The 84dp clears the top bar; on TV that bar grows by
                            // the overscan inset, so the panel has to follow it
                            // down or it opens *inside* the bar.
                            .padding(
                                top = 84.dp + PlayerDimens.edgeExtraVertical(state.isTv),
                                end = PlayerDimens.edgePadding(state.isTv),
                            ),
                    )
                }
            }
        }
    }
}

@Composable
private fun ControlsOverlay(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    playFocus: FocusRequester,
    zapFocus: FocusRequester,
    nowMillis: Long,
    onInteract: () -> Unit,
) {
    // First composition == the bar just became visible. Wait one frame so the
    // buttons are placed, then hand focus to the control the viewer had before
    // (a requester from the *previous* bar instance is gone with it, so
    // `requestFocus` fails and play/pause takes the ring). Requesting it in
    // `PlayerScreen`'s effect instead ran on the same frame the `AnimatedVisibility`
    // entered, when nothing was placed yet: the bar came up with no focused
    // control, and the next OK landed on the first one.
    LaunchedEffect(Unit) {
        androidx.compose.runtime.withFrameNanos { }
        val remembered = PlayerFocusMemory.last
        val restored =
            remembered != null && runCatching { remembered.requestFocus() }.isSuccess
        if (!restored) runCatching { playFocus.requestFocus() }
    }
    // The scrim stays full-bleed (it has to reach the screen edge to be readable
    // over the video), while the controls themselves are inset: the display
    // cutout is always excluded, and the system bars are excluded whenever a
    // swipe transiently reveals them over our immersive window.
    Box(
        Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    0f to PlayerColors.ScrimTop,
                    0.25f to androidx.compose.ui.graphics.Color.Transparent,
                    0.7f to androidx.compose.ui.graphics.Color.Transparent,
                    1f to PlayerColors.ScrimBottom,
                ),
            ),
    ) {
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            TopBar(state, callbacks, nowMillis, onInteract)
            Spacer(Modifier.weight(1f))
            BottomBar(state, callbacks, playFocus, zapFocus, nowMillis, onInteract)
        }
    }
}

/**
 * The information the corners keep while the chrome is down.
 *
 * Top-right is the wall clock when Settings has it on; bottom-right is the VOD
 * `position / duration` readout. Both are plain badges in the same style the
 * bars use, positioned at the same insets, so nothing jumps when the bars fade
 * in or out. Nothing here is a control: the tap layer below still handles every
 * press, exactly like the shared Flutter overlay's `_persistentHud()`.
 *
 * Sits at the same edge geometry as [TopBar]/[BottomBar] — including the TV
 * overscan insets — so the pills line up with the badges they replace.
 */
/**
 * The swipe's level indicator: a slim vertical bar on the side that owns the
 * level being changed — volume's side by default on the left, brightness on the
 * right, or swapped by the Settings tile ([PlayerUiState.volumeSwipeOnLeft]).
 *
 * Drawn over the picture and independently of the chrome, because the gesture is
 * used with the bars down — a viewer adjusts the sound or the picture while
 * watching. The fill grows from the bottom (the direction the finger has to
 * move), the percentage sits above it and the glyph below, so the panel reads the
 * same way upright and in landscape. Nothing here is interactive: it is feedback
 * for a gesture, never a control, and the on-screen volume control stays the
 * slider in the bar.
 */
@Composable
private fun LevelPanel(state: PlayerUiState) {
    val kind = state.levelPanelKind ?: return
    val level = state.levelPanelValue.coerceIn(SwipeLevel.BRIGHTNESS_MIN, SwipeLevel.MAX)
    // Volume sits on the side it owns; brightness takes the other one, so the
    // panel is always under the finger that moved it.
    val volumeSideLeft = state.volumeSwipeOnLeft
    val onLeft = if (kind == LevelPanelKind.Volume) volumeSideLeft else !volumeSideLeft
    val edge = PlayerDimens.edgePadding(state.isTv)
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .align(if (onLeft) Alignment.CenterStart else Alignment.CenterEnd)
                .padding(
                    start = if (onLeft) edge else 0.dp,
                    end = if (onLeft) 0.dp else edge,
                )
                .width(56.dp)
                .height(196.dp)
                .clip(RoundedCornerShape(PlayerDimens.MenuCorner))
                .background(PlayerColors.Panel)
                .padding(horizontal = 8.dp, vertical = 12.dp),
        ) {
            Text(
                text = "${(level * 100).roundToInt()}%",
                color = PlayerColors.TextHi,
                fontFamily = InterFontFamily,
                fontWeight = FontWeight.SemiBold,
                fontSize = 12.sp,
            )
            Spacer(Modifier.height(10.dp))
            Box(
                Modifier
                    .weight(1f)
                    .width(6.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(PlayerColors.PanelHi),
            ) {
                Box(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .fillMaxHeight(level)
                        .background(PlayerColors.Accent),
                )
            }
            Spacer(Modifier.height(10.dp))
            Icon(
                imageVector = when (kind) {
                    // The volume glyph is always the speaker: the panel is a
                    // level readout, and the gesture it reports can never be the
                    // mute.
                    LevelPanelKind.Volume -> Icons.Filled.VolumeUp
                    LevelPanelKind.Brightness -> Icons.Filled.BrightnessHigh
                },
                contentDescription = null,
                tint = PlayerColors.TextHi,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun PersistentHud(state: PlayerUiState, nowMillis: Long) {
    // Mirrors the shared Flutter overlay's `_persistentHud`: clock top-right,
    // VOD readout bottom-right, and the channel/title name top-left — the
    // Settings preferences gate each one, and a session with all three off
    // draws nothing at all.
    val showName = state.showChannelName && state.title.isNotBlank()
    if (!state.showClock &&
        (state.isLive || !state.showPlaybackTimes) &&
        !showName
    ) {
        return
    }
    val edge = PlayerDimens.edgePadding(state.isTv)
    val outerVertical = PlayerDimens.edgeExtraVertical(state.isTv)
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        if (showName) {
            // Grouped like the Flutter overlay: the number (when the provider
            // gave one) then the name, so a bare number is never read as a time.
            val number = state.channelNumber
            val label = if (number != null) {
                "$number · ${state.channelName ?: state.title}"
            } else {
                state.title
            }
            Box(
                Modifier
                    .align(Alignment.TopStart)
                    .padding(start = edge, top = 18.dp + outerVertical),
            ) {
                Badge(label)
            }
        }
        if (state.showClock) {
            Box(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = 18.dp + outerVertical, end = edge),
            ) {
                Badge(if (state.isTv) formatClock(nowMillis) else clockHm(nowMillis))
            }
        }
        // VOD only, and only once the engine knows the duration: a `0:00 / 0:00`
        // pill on a stream that is still resolving would claim a position that
        // does not exist yet.
        if (!state.isLive && state.showPlaybackTimes && state.durationMs > 0) {
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(bottom = 18.dp + outerVertical, end = edge),
            ) {
                Badge("${formatTime(state.positionMs)} / ${formatTime(state.durationMs)}")
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TopBar(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    nowMillis: Long,
    onInteract: () -> Unit,
) {
    // Same breakpoint as the bottom bar: below ~560dp (phone portrait) the badge
    // cluster would squeeze the title to nothing, so it wraps onto its own row.
    // On a TV the edge inset widens and the *outer* (top) vertical inset grows:
    // `safeDrawingPadding()` reports zero insets there, so nothing else keeps the
    // chrome off the physical panel edge. See `PlayerDimens.TvEdgePadding`.
    val edge = PlayerDimens.edgePadding(state.isTv)
    val outerVertical = PlayerDimens.edgeExtraVertical(state.isTv)
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val compact = maxWidth < 560.dp
        if (compact) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(
                        start = edge,
                        end = edge,
                        top = 12.dp + outerVertical,
                        bottom = 12.dp,
                    ),
            ) {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconControlButton(
                        icon = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        onClick = { onInteract(); callbacks.onBack() },
                    )
                    Spacer(Modifier.width(14.dp))
                    // Settings → "Channel name in the player". Off keeps the
                    // back button and the badges; only the name goes.
                    if (state.showChannelName) {
                        Text(
                            text = state.title,
                            color = PlayerColors.TextHi,
                            fontFamily = InterFontFamily,
                            fontWeight = FontWeight.Bold,
                            fontSize = 18.sp,
                            maxLines = 1,
                            modifier = Modifier.weight(1f),
                        )
                    } else {
                        Spacer(Modifier.weight(1f))
                    }
                }
                Spacer(Modifier.height(6.dp))
                // FlowRow so the badges wrap again on very narrow screens instead
                // of overflowing off-screen.
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    TopBadges(state, nowMillis)
                }
            }
        } else {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(
                        start = edge,
                        end = edge,
                        top = 16.dp + outerVertical,
                        bottom = 16.dp,
                    ),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconControlButton(
                    icon = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    onClick = { onInteract(); callbacks.onBack() },
                )
                Spacer(Modifier.width(14.dp))
                if (state.showChannelName) {
                    Text(
                        text = state.title,
                        color = PlayerColors.TextHi,
                        fontFamily = InterFontFamily,
                        fontWeight = FontWeight.Bold,
                        fontSize = 18.sp,
                        maxLines = 1,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    Spacer(Modifier.weight(1f))
                }
                Spacer(Modifier.width(8.dp))
                // Right-cluster badges: source, LIVE/resolution/HDR, fps, and (TV
                // only) a date+time clock. The title takes the remaining width and
                // ellipsizes.
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    TopBadges(state, nowMillis)
                }
            }
        }
    }
}

@Composable
private fun TopBadges(state: PlayerUiState, nowMillis: Long) {
    state.sourceBadge()?.let { Badge(it) }
    if (state.isLive) LiveBadge(synced = state.liveSynced)
    state.resolutionBadge()?.let { Badge(it) }
    state.hdrBadge()?.let { Badge(it, accent = true) }
    state.fpsBadge()?.let { Badge(it) }
    if (state.showClock) {
        // Dated on a TV (ten-foot, glanceable, matches the Dart overlay's
        // `dated: !touch`), bare `HH:mm` on a phone where space is tight.
        Badge(if (state.isTv) formatClock(nowMillis) else clockHm(nowMillis))
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun BottomBar(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    playFocus: FocusRequester,
    zapFocus: FocusRequester,
    nowMillis: Long,
    onInteract: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            // TV overscan: wider sides, and the extra goes on the *bottom* only —
            // that's the physical edge here. See `PlayerDimens.TvEdgePadding`.
            .padding(
                start = PlayerDimens.edgePadding(state.isTv),
                end = PlayerDimens.edgePadding(state.isTv),
                top = 18.dp,
                bottom = 18.dp + PlayerDimens.edgeExtraVertical(state.isTv),
            ),
    ) {
        if (!state.isLive) {
            Scrubber(state, callbacks, onInteract)
            Spacer(Modifier.height(10.dp))
        } else {
            // Live has no scrubber; surface the channel identity + the EPG
            // now/next + programme progress in its place when available.
            //
            // The identity run is drawn only when it says something the top
            // bar's title does not — a channel number, a half-typed number, a
            // transient note — so a session that never zaps looks exactly as
            // it did before.
            if (state.showsChannelIdentity) {
                ChannelIdentityRow(state)
                Spacer(Modifier.height(10.dp))
            }
            state.epgNow?.let { now ->
                LiveEpgStrip(now, state.epgNext, nowMillis)
                Spacer(Modifier.height(12.dp))
            }
        }
        // Below ~560dp (phone portrait) the controls do not fit on one line.
        // VOD is the worst case: Prev/Next *and* ±10s are all present, so the
        // transport row alone is already ~250dp of a 360dp phone and a
        // fixed-width volume slider pushed the mute button and the track off
        // the right edge (the report was "mute and the volume bar don't fit in
        // portrait").
        //
        // **Rows are packed, not fixed.** Mute belongs with the transport, so
        // it rides that row; the volume slider and the contextual cluster then
        // share a `FlowRow`, which wraps only when they genuinely do not fit.
        // The result is two rows in the common case (volume hidden, or a live
        // cluster small enough to sit beside the slider) and three only when a
        // VOD cluster and the slider together exceed the width — instead of the
        // unconditional three the mute-in-its-own-row version produced.
        BoxWithConstraints {
            val compact = maxWidth < 560.dp
            if (compact) {
                Column(Modifier.fillMaxWidth()) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        // Uniform gaps come from the parent, so TransportControls
                        // omits its own spacers (`spread = true`).
                        TransportControls(state, callbacks, playFocus, onInteract, spread = true)
                    }
                    Spacer(Modifier.height(10.dp))
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        if (state.showsVolume) {
                            // A fixed lane, not `weight`: inside a FlowRow a
                            // weighted child has no row to distribute against,
                            // and 120dp is the same width landscape uses.
                            VolumeSlider(
                                state,
                                callbacks,
                                onInteract,
                                Modifier.width(120.dp),
                            )
                        }
                        // The parent supplies the gaps, so skip the cluster's own
                        // inter-button spacers (`spread = true`).
                        RightCluster(state, callbacks, playFocus, zapFocus, onInteract, spread = true)
                    }
                }
            } else {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TransportControls(state, callbacks, playFocus, onInteract)
                    if (state.showsVolume) {
                        Spacer(Modifier.width(8.dp))
                        VolumeSlider(state, callbacks, onInteract, Modifier.width(120.dp))
                    }
                    Spacer(Modifier.weight(1f))
                    RightCluster(state, callbacks, playFocus, zapFocus, onInteract)
                }
            }
        }
    }
}

/** Play/pause, Prev/Next (when stepping is available), ±10s (VOD) and mute.
 *  The volume *slider* is [VolumeSlider], drawn after this row in landscape and
 *  in the wrapping cluster row in portrait. */
@Composable
private fun TransportControls(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    playFocus: FocusRequester,
    onInteract: () -> Unit,
    spread: Boolean = false,
) {
    // When `spread`, the parent Row supplies uniform gaps (`spacedBy`), so we omit
    // the manual spacers; otherwise (landscape) we space the controls ourselves.
    IconControlButton(
        icon = if (state.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
        contentDescription = "Play/Pause",
        focusRequester = playFocus,
        onClick = { onInteract(); callbacks.onPlayPause() },
    )
    if (state.stepEnabled && state.showsPreviousNext) {
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(Icons.Filled.SkipPrevious, "Previous") {
            onInteract(); callbacks.onZapCommand("zap:down")
        }
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(Icons.Filled.SkipNext, "Next") {
            onInteract(); callbacks.onZapCommand("zap:up")
        }
    }
    if (!state.isLive && state.showsSeek10) {
        // The configured VOD step, shared with the seek double tap: the buttons
        // and the gesture must move by the same amount or one of them is lying.
        val stepSeconds = state.seekStepSeconds.coerceAtLeast(1)
        val stepMs = stepSeconds * 1_000L
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(seekIconFor(forward = false, seconds = stepSeconds), "Back ${stepSeconds}s") {
            onInteract(); callbacks.onSeekBy(-stepMs)
        }
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(seekIconFor(forward = true, seconds = stepSeconds), "Forward ${stepSeconds}s") {
            onInteract(); callbacks.onSeekBy(stepMs)
        }
    }
    // Mute rides the transport, not the volume slider's row: on a phone it was
    // the one control left on a row of its own once the slider was hidden, which
    // read as a wasted strip of picture for a single button.
    if (state.showsMute) {
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(
            icon = if (state.muted || state.volume == 0f) Icons.Filled.VolumeOff else Icons.Filled.VolumeUp,
            contentDescription = "Mute",
        ) { onInteract(); callbacks.onToggleMute() }
    }
}

/**
 * The seek glyph for [seconds], the same rule the shared Flutter overlay uses:
 * Material only ships numbered icons for 5, 10 and 30, so 15/60 fall back to the
 * plain 10 glyph rather than printing a number that disagrees with the step.
 * The content description always carries the real number.
 */
private fun seekIconFor(forward: Boolean, seconds: Int): ImageVector = when (seconds) {
    5 -> if (forward) Icons.Filled.Forward5 else Icons.Filled.Replay5
    30 -> if (forward) Icons.Filled.Forward30 else Icons.Filled.Replay30
    else -> if (forward) Icons.Filled.Forward10 else Icons.Filled.Replay10
}

/**
 * The volume track alone; mute lives in [TransportControls].
 *
 * `width` is where the caller decides the lane: a fixed 120 dp in both layouts,
 * so the control keeps the same footprint on a phone and on a TV. The slider is
 * its own row only when it does not fit beside the contextual cluster — see the
 * compact branch of `BottomBar`.
 */
@Composable
private fun VolumeSlider(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    onInteract: () -> Unit,
    width: Modifier,
) {
    SlimSlider(
        value = if (state.muted) 0f else state.volume,
        onValueChange = { onInteract(); callbacks.onSetVolume(it) },
        modifier = width,
        // In the transport row it reads as one of the controls, and needs a
        // focus state a remote user can actually see — see [SlimSlider].
        chip = true,
    )
}

/** Contextual right cluster: speed (VOD), audio, subtitles, aspect, info. */
@Composable
private fun RightCluster(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    playFocus: FocusRequester,
    zapFocus: FocusRequester,
    onInteract: () -> Unit,
    spread: Boolean = false,
) {
    // When `spread`, the parent Row supplies the gaps (portrait, `spacedBy`), so we
    // omit the manual spacers; otherwise (landscape) we space the buttons ourselves.
    //
    // The quick-list opener, **immediately left of "Go to live"** — the slot
    // every surface that draws its own chrome gives it (the Windows GDI
    // `BottomLayout::quick_list`, the shared Flutter cluster, the Linux Lua
    // OSD). A remote reaches the list with Left or GUIDE; a finger and a mouse
    // have no equivalent, which is the whole reason this button exists.
    //
    // Gated on `showQuickListButton` (live **and** a zap controller behind the
    // route), never on `isLive` alone: with no controller Dart declines
    // `zap:list` and the button would be inert. It sends the command through
    // the same `onZapCommand` path the overlay's pointer-driven quick-list rows
    // use — this surface is an input source, never a second copy of the list.
    //
    // It sends `zap:list` and never `zap:close`, unlike the Windows button:
    // `applyQuickList` stands the chrome down on the closed→open edge, so this
    // control is off screen for as long as the list is up and can never be
    // pressed a second time. Back is what closes it here.
    if (state.showQuickListButton && state.showsQuickList) {
        IconControlButton(
            icon = Icons.AutoMirrored.Filled.List,
            contentDescription = "Channel list",
            // A tap opens the channel list; a **long press** opens the same
            // list one rung higher — its categories, cursor on the current one.
            // A finger has no Left key to step back to the categories, so
            // without this the mode was unreachable on a phone.
            onLongClick = {
                onInteract()
                callbacks.onZapCommand("zap:categories")
            },
        ) { onInteract(); callbacks.onZapCommand("zap:list") }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    // Live-only "jump to live edge", shown only once behind (paused) — separate
    // from play/pause, which keeps resuming from where you paused. The label is
    // the action, not the state: this used to read "LIVE", duplicating the LIVE
    // *status* badge in the top bar (which greys at the very moment this button
    // appears) with a word that says nothing about what pressing it does. Every
    // overlay already declared "Go to live" as the accessible name; the visible
    // label now agrees with it. Same wording on Windows, iOS, Linux and the
    // shared Flutter overlay.
    //
    // **It is the one control that removes itself while you are standing on
    // it**, and on a D-pad that used to strand the remote: pressing OK reloads
    // to the live edge, `liveSynced` flips true, the button leaves composition,
    // and Compose's focus went with it — no control in the overlay held focus
    // any more, so no arrow key did anything until Back tore the whole thing
    // down. Focus therefore moves to play/pause on the press, and again from
    // `onDispose` if the button disappears while focused for any *other* reason
    // (the reconnect watchdog reaching the live edge on its own). Both go
    // through `runCatching` because the requester's node is gone when the whole
    // bar is leaving composition — the chrome-hidden case, where
    // `PlayerScreen`'s own effect parks focus on the root instead.
    if (state.isLive && !state.liveSynced) {
        var goLiveFocused by remember { mutableStateOf(false) }
        DisposableEffect(Unit) {
            onDispose {
                if (goLiveFocused) runCatching { playFocus.requestFocus() }
            }
        }
        TextControlButton(
            // The label is the mode while holding: the chip already says what a
            // tap does, and a raised speed that says nothing reads as a broken
            // player. Otherwise it is the action, as everywhere else.
            label = if (state.catchingUp) "Catching up ×2" else "Go to live",
            contentDescription = if (state.catchingUp) {
                "Catching up to live at double speed"
            } else {
                "Go to live"
            },
            onFocusChanged = { goLiveFocused = it },
            // Tap jumps to the edge (reload); hold plays at double speed until
            // the finger lifts, which is how a viewer behind the live edge
            // catches up without losing the buffer.
            onHoldStart = {
                onInteract()
                callbacks.onCatchUpStart()
            },
            onHoldEnd = { callbacks.onCatchUpStop() },
        ) {
            onInteract()
            callbacks.onGoLive()
            runCatching { playFocus.requestFocus() }
        }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    if (state.canFavorite && state.showsFavorite) {
        IconControlButton(
            icon = if (state.isFavorite) Icons.Filled.Star else Icons.Filled.StarBorder,
            contentDescription = if (state.isFavorite) "Remove from favorites" else "Add to favorites",
        ) { onInteract(); callbacks.onToggleFavorite() }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    if (state.showSpeedButton) {
        TextControlButton(state.speedLabel(), "Playback speed") {
            onInteract(); state.openMenu =
                if (state.openMenu == PlayerMenu.Speed) PlayerMenu.None else PlayerMenu.Speed
        }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    if (state.showAudioButton) {
        IconControlButton(Icons.Filled.Audiotrack, "Audio track") {
            onInteract(); state.openMenu =
                if (state.openMenu == PlayerMenu.Audio) PlayerMenu.None else PlayerMenu.Audio
        }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    if (state.showSubtitleButton && state.showsSubtitles) {
        IconControlButton(Icons.Filled.ClosedCaption, "Subtitles") {
            onInteract(); state.openMenu =
                if (state.openMenu == PlayerMenu.Subtitles) PlayerMenu.None else PlayerMenu.Subtitles
        }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    if (state.showsAspect) {
        // Short press cycles; a hold opens the same dark list-menu as the
        // track/speed menus (`PlayerMenusLayer`), not a Material DropdownMenu —
        // that one rendered on the default white surface, which is the one
        // white panel in the whole player.
        TextControlButton(
            label = state.aspect.label,
            contentDescription = "Aspect ratio, hold to pin this channel",
            active = state.aspectPinned,
            onHoldStart = {
                onInteract()
                state.openMenu = PlayerMenu.Aspect
            },
            onClick = { onInteract(); callbacks.onCycleAspect() },
        )
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    // Orientation: follow the device, or pin landscape with the **sensor**
    // choosing which side is up (so turning the phone over keeps the picture
    // upright). The icon is the mode, not the action: a rotating phone for
    // auto, a landscape phone for the lock. Absent on a TV, where the button
    // could not change anything.
    if (state.supportsOrientationLock) {
        IconControlButton(
            icon = if (state.orientationLocked) {
                Icons.Filled.StayCurrentLandscape
            } else {
                Icons.Filled.ScreenRotation
            },
            contentDescription = if (state.orientationLocked) {
                "Orientation: landscape locked"
            } else {
                "Orientation: follow device"
            },
            active = state.orientationLocked,
        ) { onInteract(); callbacks.onToggleOrientation() }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    if (state.supportsPip && state.showsPip) {
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(Icons.Filled.PictureInPictureAlt, "Picture in picture") {
            onInteract(); callbacks.onEnterPip()
        }
    }
    if (state.showsInfo) {
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(Icons.Filled.Info, "Stream info") {
            onInteract(); state.infoOpen = !state.infoOpen
        }
    }
    if (state.isLive) {
        // The two live toggles are **buttons**, not an overflow menu: one press
        // reaches either, a D-pad sees both without opening anything, and the
        // state is visible on the control itself (accent tint) instead of
        // behind a checkmark in a dropped-down list. Both are owned by Dart's
        // LiveZapController; the banner reports the direction, so nothing here
        // keeps a state copy that could disagree with the session.
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(
            icon = Icons.Filled.Shuffle,
            contentDescription = "Random zapping",
            active = state.randomZapping,
        ) { onInteract(); callbacks.onZapCommand("zap:random") }
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(
            icon = Icons.Filled.Bolt,
            contentDescription = "Auto-switch channels",
            focusRequester = zapFocus,
            active = state.autoSwitchEnabled,
            // A long press is the *pace*: tap still toggles the mode, and the
            // number lives one gesture deeper rather than in an extra control.
            onLongClick = {
                onInteract()
                state.dwellMenuOpen = true
            },
        ) { onInteract(); callbacks.onZapCommand("zap:auto") }
    }
}

@Composable
private fun Scrubber(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    onInteract: () -> Unit,
) {
    val duration = state.durationMs.coerceAtLeast(1)
    Row(verticalAlignment = Alignment.CenterVertically) {
        // The labels are hidden rather than the row dropped, and the slider keeps
        // its weight — a hidden readout leaves the bar exactly where it was, so
        // toggling the preference reflows nothing and seeking still works.
        if (state.showPlaybackTimes) {
            Text(
                formatTime(state.positionMs),
                color = PlayerColors.TextHi,
                fontFamily = InterFontFamily,
                fontSize = 13.sp,
                modifier = Modifier.width(58.dp),
            )
        }
        SlimSlider(
            value = (state.positionMs.toFloat() / duration).coerceIn(0f, 1f),
            onValueChange = { fraction ->
                onInteract()
                callbacks.onSeekTo((fraction * duration).toLong())
            },
            modifier = Modifier.weight(1f),
            step = 0.02f, // ~2% per D-pad press for quicker scrubbing
        )
        if (state.showPlaybackTimes) {
            Text(
                formatTime(state.durationMs),
                color = PlayerColors.TextLo,
                fontFamily = InterFontFamily,
                fontSize = 13.sp,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
    }
}

// ---- Reusable controls ------------------------------------------------------

@Composable
fun IconControlButton(
    icon: ImageVector,
    contentDescription: String,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
    // Toggle state: an accent-tinted glyph (white while focused, so it stays
    // legible on the accent-filled focus background).
    active: Boolean = false,
    // A second, deeper action on a touch press. Deliberately *not* a second
    // control: the cluster is full, and these two buttons have a natural pair
    // of meanings (open the list / open its categories, toggle the mode /
    // choose its pace). A D-pad has no long press, so nothing is lost there.
    onLongClick: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    // A requester of its own when the caller did not hand one over (only
    // play/pause does): the focus memory needs an object that outlives the
    // control's removal, so that hiding the bar and bringing it back can land on
    // the same button — see [PlayerFocusMemory].
    val ownRequester = remember { FocusRequester() }
    val requester = focusRequester ?: ownRequester
    val base = modifier
        .size(PlayerDimens.ButtonSize)
        .clip(RoundedCornerShape(PlayerDimens.ButtonCorner))
        .background(if (focused) PlayerColors.ButtonBgFocused else PlayerColors.ButtonBg)
    val withFocus = base.focusRequester(requester)
    val press = if (onLongClick == null) {
        Modifier.clickable(onClick = onClick)
    } else {
        Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick)
    }
    Box(
        contentAlignment = Alignment.Center,
        modifier = withFocus
            .onFocusChanged {
                focused = it.isFocused
                if (it.isFocused) PlayerFocusMemory.last = requester
            }
            .then(press),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = when {
                focused -> Color.White
                active -> PlayerColors.Accent
                else -> PlayerColors.TextHi
            },
            modifier = Modifier.size(22.dp),
        )
    }
}

/**
 * [onFocusChanged] lets a caller observe focus without owning the visual state.
 * It exists for controls that can *remove themselves* while focused — "Go to
 * live" is the only one — so the caller can hand focus somewhere else before it
 * goes; see [RightCluster].
 *
 * **A chip with a hold action is still a focus stop.** Every chip goes through
 * `combinedClickable` — the same modifier [IconControlButton] uses — so the hold
 * path keeps the focus target and the OK/Enter handling that `clickable`
 * supplies. It used to be a raw `detectTapGestures` with a hand-applied
 * `focusable()`: a pointer detector is not a focus node, and the remote walked
 * straight past the aspect chip even with `focusable()` on it.
 *
 * [onHoldStart] / [onHoldEnd] add **press-and-hold** to a text chip. "Go to
 * live" is the one caller: a tap jumps to the edge by reloading, a hold plays the
 * stream faster until it catches up. The hold is `combinedClickable`'s own
 * `onLongClick`; a second, passive pointer loop only reports when the finger
 * lifts, because there is no "long press ended" callback and the speed must not
 * stay raised after the user lets go.
 */
@Composable
fun TextControlButton(
    label: String,
    contentDescription: String,
    modifier: Modifier = Modifier,
    onFocusChanged: ((Boolean) -> Unit)? = null,
    // Non-default state this control carries (a per-channel aspect pin): the
    // label turns accent and the chip gains an accent border.
    active: Boolean = false,
    onHoldStart: (() -> Unit)? = null,
    onHoldEnd: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    // Own requester, remembered here like [IconControlButton]'s: the focus
    // memory must survive this control leaving composition.
    val ownRequester = remember { FocusRequester() }
    // Handlers as *updated state*, so the pointer detectors can key on nothing:
    // they must survive the recomposition that a hold causes (the label changes
    // to "Catching up ×2"). Keying them on the lambdas — which are rebuilt every
    // recomposition — restarted the gesture mid-hold and lost the release, which
    // left the speed raised after the finger lifted.
    val tapHandler = rememberUpdatedState(onClick)
    val holdStartHandler = rememberUpdatedState(onHoldStart)
    val holdEndHandler = rememberUpdatedState(onHoldEnd)
    // **One press mechanism for every chip**, `combinedClickable` — the same
    // modifier [IconControlButton] uses. It supplies the focus target *and* the
    // OK/Enter key handling that `clickable` would, which is exactly what the
    // aspect chip lost while this path was a raw `detectTapGestures` plus a
    // hand-applied `focusable()`: a pointer detector is not a focus node, and
    // the remote walked straight past the chip even after `focusable()` was
    // bolted on. `onLongClick` is the hold.
    val press = if (onHoldStart == null) {
        Modifier.clickable(onClick = { tapHandler.value() })
    } else {
        Modifier
            .combinedClickable(
                onClick = { tapHandler.value() },
                onLongClick = { holdStartHandler.value?.invoke() },
            )
            .then(
                if (onHoldEnd == null) {
                    Modifier
                } else {
                    // Passive: never consumes, so `combinedClickable` above still
                    // owns the gesture. It only watches for the press to end —
                    // `onLongClick` has no "released" callback, and the held
                    // speed must not outlive the hold.
                    Modifier.pointerInput(Unit) {
                        awaitEachGesture {
                            awaitFirstDown(requireUnconsumed = false)
                            while (true) {
                                val event = awaitPointerEvent()
                                if (event.changes.all { !it.pressed }) break
                            }
                            holdEndHandler.value?.invoke()
                        }
                    }
                },
            )
    }
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(PlayerDimens.ButtonSize)
            .clip(RoundedCornerShape(PlayerDimens.ButtonCorner))
            .background(if (focused) PlayerColors.ButtonBgFocused else PlayerColors.ButtonBg)
            .focusRequester(ownRequester)
            // A pinned aspect is the one control carrying a non-default,
            // per-item choice: the accent border is how the viewer sees that
            // *this* channel is framed differently from the global mode.
            .then(
                if (active) {
                    Modifier.border(
                        1.dp,
                        PlayerColors.Accent,
                        RoundedCornerShape(PlayerDimens.ButtonCorner),
                    )
                } else {
                    Modifier
                },
            )
            .onFocusChanged {
                focused = it.isFocused
                if (it.isFocused) PlayerFocusMemory.last = ownRequester
                onFocusChanged?.invoke(it.isFocused)
            }
            .then(press)
            .padding(horizontal = 14.dp),
    ) {
        Text(
            text = label,
            color = if (active) PlayerColors.Accent else PlayerColors.TextHi,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 14.sp,
            maxLines = 1,
        )
    }
}

@Composable
private fun UnsupportedVideoNotice(reason: String, modifier: Modifier = Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .padding(32.dp)
            .clip(RoundedCornerShape(PlayerDimens.MenuCorner))
            .background(PlayerColors.Panel)
            .padding(horizontal = 24.dp, vertical = 20.dp),
    ) {
        Text(
            text = reason,
            color = PlayerColors.TextHi,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 15.sp,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = "Audio is still playing.",
            color = PlayerColors.TextLo,
            fontFamily = InterFontFamily,
            fontSize = 13.sp,
        )
    }
}

@Composable
private fun ReconnectingNotice(modifier: Modifier = Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(RoundedCornerShape(PlayerDimens.MenuCorner))
            .background(PlayerColors.Panel)
            .padding(horizontal = 20.dp, vertical = 14.dp),
    ) {
        CircularProgressIndicator(
            color = PlayerColors.Accent,
            strokeWidth = 2.dp,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = "Reconnecting…",
            color = PlayerColors.TextHi,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 15.sp,
        )
    }
}

@Composable
fun LiveBadge(synced: Boolean = true) {
    // Red at the live edge; grey once behind (paused/seeked). Pairs with the
    // go-to-live button, which appears only while behind.
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(if (synced) PlayerColors.Live else PlayerColors.TrackInactive)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    ) {
        Text(
            "LIVE",
            color = if (synced) {
                androidx.compose.ui.graphics.Color.White
            } else {
                PlayerColors.TextLo
            },
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.Bold,
            fontSize = 12.sp,
        )
    }
}

@Composable
fun Badge(text: String, accent: Boolean = false) {
    Box(
        Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(if (accent) PlayerColors.Accent else PlayerColors.PanelHi)
            .padding(horizontal = 9.dp, vertical = 5.dp),
    ) {
        Text(
            text = text,
            color = PlayerColors.TextHi,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.Bold,
            fontSize = 11.sp,
        )
    }
}

/**
 * A slim slider with **two postures**, because its two uses need different
 * D-pad rules:
 *
 *  * the VOD **scrubber** (`chip = false`) sits alone on its row, so Left/Right
 *    is the seek gesture outright — no mode, matching the Windows GDI overlay's
 *    scrubber row, and Up/Down leaves the row;
 *  * the **volume slider** (`chip = true`) lives inside the transport row,
 *    between buttons. Leaving the arrows as "change the volume" trapped the
 *    cursor: from the volume control there was no way to reach the button beside
 *    it. So it keeps the original posture — arrows traverse, OK enters adjust
 *    mode, then Left/Right [step] it, and OK/Back leaves.
 *
 * Touch keeps drag + tap-to-seek on both. Used for the scrubber and the volume
 * slider.
 */
@Composable
fun SlimSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
    step: Float = 0.05f,
    chip: Boolean = false,
) {
    var focused by remember { mutableStateOf(false) }
    // Only the inline (chip) slider has a mode; the scrubber's arrows always act.
    var editing by remember { mutableStateOf(false) }
    val adjusting = !chip || editing
    val ownRequester = remember { FocusRequester() }
    var widthPx by remember { mutableFloatStateOf(0f) }
    val f = value.coerceIn(0f, 1f)
    // A focused chip is filled with `ButtonBgFocused`, which *is* `Accent` — the
    // same colour as the slider's own fill, so on accent the value has to be
    // drawn in white or it vanishes into its own background.
    val onAccent = chip && (focused || editing)
    val trackColor = if (onAccent) {
        androidx.compose.ui.graphics.Color.White.copy(alpha = 0.35f)
    } else {
        PlayerColors.TrackInactive
    }
    val fillColor = if (onAccent) {
        androidx.compose.ui.graphics.Color.White
    } else {
        PlayerColors.Accent
    }

    Box(
        modifier
            // [chip] gives the volume slider the same rounded fill its neighbours
            // in the transport row have, lit the same way on focus. Without it
            // the slider was the one focus stop in the overlay whose focused
            // state was a 2dp ring on a 14dp thumb — walking onto it with a
            // D-pad read as "the focus disappeared", which is exactly how the
            // "Go to live" stranding was first described. Opt-in so the VOD
            // scrubber, which spans the bar, stays a bare track.
            .then(
                if (chip) {
                    Modifier
                        .height(PlayerDimens.ButtonSize)
                        .clip(RoundedCornerShape(PlayerDimens.ButtonCorner))
                        .background(
                            if (focused || editing) {
                                PlayerColors.ButtonBgFocused
                            } else {
                                PlayerColors.ButtonBg
                            },
                        )
                        .padding(horizontal = 12.dp)
                } else {
                    // Comfortable touch / focus target around the thin track.
                    Modifier.height(28.dp)
                },
            )
            .onFocusChanged {
                focused = it.isFocused
                if (it.isFocused) PlayerFocusMemory.last = ownRequester
                // Leaving the chip drops adjust mode, so coming back to it never
                // starts with the arrows captured again.
                if (!it.isFocused) editing = false
            }
            .focusRequester(ownRequester)
            .focusable()
            .onPreviewKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                when (e.key) {
                    // OK: the scrubber has nothing to activate (its arrows already
                    // seek), the inline chip toggles adjust mode — which is how a
                    // D-pad changes the volume without losing the row.
                    Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> {
                        if (chip) editing = !editing
                        true
                    }
                    // Left/Right **is** the seek gesture on the scrubber, and the
                    // volume step on the chip once adjust mode is on. Otherwise
                    // they are left to focus traversal, so the volume control is
                    // not a trap between its neighbours.
                    Key.DirectionLeft -> {
                        if (adjusting) {
                            onValueChange((value - step).coerceIn(0f, 1f))
                            true
                        } else {
                            false
                        }
                    }
                    Key.DirectionRight -> {
                        if (adjusting) {
                            onValueChange((value + step).coerceIn(0f, 1f))
                            true
                        } else {
                            false
                        }
                    }
                    Key.Back -> if (chip && editing) {
                        editing = false
                        true
                    } else {
                        false
                    }
                    else -> false
                }
            }
            .onSizeChanged { widthPx = it.width.toFloat() }
            .pointerInput(Unit) {
                detectTapGestures { offset ->
                    if (widthPx > 0f) onValueChange((offset.x / widthPx).coerceIn(0f, 1f))
                }
            }
            .pointerInput(Unit) {
                detectHorizontalDragGestures { change, _ ->
                    if (widthPx > 0f) onValueChange((change.position.x / widthPx).coerceIn(0f, 1f))
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        // Track + elapsed fill.
        Box(
            Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(trackColor),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(f)
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(fillColor),
            )
        }
        // Thumb positioned at the fill end via [f : 1-f] weighted spacers (centers
        // it exactly: thumb left = f * (width - thumbWidth)).
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (f > 0f) Spacer(Modifier.weight(f))
            Box(
                Modifier
                    .size(14.dp)
                    .clip(CircleShape)
                    .background(fillColor)
                    .then(
                        // On an accent chip the thumb is already white; a white
                        // ring around it would only blur its edge.
                        if (focused && !onAccent) {
                            Modifier.border(
                                2.dp,
                                androidx.compose.ui.graphics.Color.White.copy(alpha = 0.92f),
                                CircleShape,
                            )
                        } else {
                            Modifier
                        },
                    ),
            )
            if (f < 1f) Spacer(Modifier.weight(1f - f))
        }
    }
}

fun formatTime(ms: Long): String {
    if (ms <= 0) return "0:00"
    val totalSeconds = ms / 1000
    val h = totalSeconds / 3600
    val m = (totalSeconds % 3600) / 60
    val s = totalSeconds % 60
    return if (h > 0) {
        "%d:%02d:%02d".format(h, m, s)
    } else {
        "%d:%02d".format(m, s)
    }
}

/** Date + time clock for the TV top-bar badge, e.g. "Fri 26 Jun · 23:09". */
private fun formatClock(ms: Long): String =
    java.text.SimpleDateFormat("EEE d MMM · HH:mm", java.util.Locale.getDefault())
        .format(java.util.Date(ms))

/** Wall-clock HH:mm for EPG programme start/stop labels. */
private fun clockHm(ms: Long): String =
    java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault())
        .format(java.util.Date(ms))

/**
 * The zap banner: what a channel change says while the chrome is hidden.
 *
 * It sits exactly where the bottom bar's live block does and carries the same
 * two pieces — the channel identity run and the live EPG strip — rather than
 * a layout of its own, so a channel seen through the banner and the same
 * channel seen with the controls up read identically. That reuse is the whole
 * design: this is the fifth surface that has to agree about the live strip
 * (docs/player.md, "The live EPG strip"), and a bespoke one would be a fifth
 * thing to keep in step.
 */
@Composable
private fun ZapBanner(state: PlayerUiState, nowMillis: Long) {
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        Column(
            Modifier
                .align(Alignment.BottomStart)
                .fillMaxWidth()
                .padding(
                    start = PlayerDimens.edgePadding(state.isTv),
                    end = PlayerDimens.edgePadding(state.isTv),
                    bottom = 18.dp + PlayerDimens.edgeExtraVertical(state.isTv),
                )
                .clip(RoundedCornerShape(PlayerDimens.BarCorner))
                .background(PlayerColors.Panel)
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            ChannelIdentityRow(state)
            state.epgNow?.let { now ->
                Spacer(Modifier.height(10.dp))
                LiveEpgStrip(now, state.epgNext, nowMillis)
            }
        }
    }
}

/**
 * `12 · BBC One`, with the half-typed channel number leading it and any
 * transient note trailing it.
 *
 * Shared by the banner and the bottom bar so the two cannot drift. The typed
 * digits are the headline while they exist: mid-entry, the number the user is
 * building is the thing they are looking at, and the channel beside it is
 * still the one playing.
 */
@Composable
private fun ChannelIdentityRow(state: PlayerUiState) {
    val identity = state.channelIdentityLabel()
    val digits = state.digitBuffer
    val message = state.zapMessage
    if (identity == null && digits.isEmpty() && message == null) return
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (digits.isNotEmpty()) {
            Text(
                text = digits,
                color = PlayerColors.Accent,
                fontFamily = InterFontFamily,
                fontWeight = FontWeight.Bold,
                fontSize = 24.sp,
                maxLines = 1,
            )
            Spacer(Modifier.width(12.dp))
        }
        if (identity != null) {
            Text(
                text = identity,
                color = PlayerColors.TextHi,
                fontFamily = InterFontFamily,
                fontWeight = FontWeight.SemiBold,
                fontSize = 16.sp,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
        } else {
            Spacer(Modifier.weight(1f))
        }
        if (message != null) {
            Spacer(Modifier.width(8.dp))
            Text(
                text = message,
                color = PlayerColors.Live,
                fontFamily = InterFontFamily,
                fontSize = 12.sp,
                maxLines = 1,
            )
        } else if (state.zapTotal > 0 && state.zapPosition > 0) {
            Spacer(Modifier.width(8.dp))
            Text(
                text = "${state.zapPosition}/${state.zapTotal}",
                color = PlayerColors.TextLo,
                fontFamily = InterFontFamily,
                fontSize = 12.sp,
                maxLines = 1,
            )
        }
    }
}

/**
 * Live EPG strip shown where the VOD scrubber sits: the current programme title +
 * its start–stop, a thin elapsed-progress bar, and the next programme.
 */
@Composable
private fun LiveEpgStrip(now: EpgEntry, next: EpgEntry?, nowMillis: Long) {
    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = now.title,
                color = PlayerColors.TextHi,
                fontFamily = InterFontFamily,
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = "${clockHm(now.startMs)} – ${clockHm(now.stopMs)}",
                color = PlayerColors.TextLo,
                fontFamily = InterFontFamily,
                fontSize = 12.sp,
            )
        }
        Spacer(Modifier.height(6.dp))
        Box(
            Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(PlayerColors.TrackInactive),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(now.progressAt(nowMillis))
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(PlayerColors.Accent),
            )
        }
        next?.let {
            Spacer(Modifier.height(6.dp))
            Text(
                text = "Next · ${clockHm(it.startMs)} – ${clockHm(it.stopMs)} · ${it.title}",
                color = PlayerColors.TextLo,
                fontFamily = InterFontFamily,
                fontSize = 12.sp,
                maxLines = 1,
            )
        }
    }
}

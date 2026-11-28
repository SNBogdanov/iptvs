package com.gchofficial.iptvs.player

/**
 * The 0..1 level a vertical swipe asks for, and the side of the picture that
 * owns each of the two gestures.
 *
 * Both gestures are the same arithmetic on a different variable, so they share
 * one mapping: **up is more** (screen coordinates grow downwards, so the delta is
 * subtracted), a **full picture height sweeps the whole range**, and the result
 * clamps into the gesture's own floor:
 *
 * - volume's floor is one percent: on this engine a zero level *is* the muted
 *   state, so a swipe to the bottom would mute the player and end up looking
 *   exactly like the mute button — silence stays the button's job;
 * - brightness' floor is five percent: a screen at zero cannot be swiped back,
 *   because the user can no longer see the picture they are swiping on.
 *
 * Pure and Android-free so the plain-JUnit harness pins it, like
 * [PlayerOrientation] and [ZapKeyPolicy]: the gesture wiring needs a real touch
 * surface, the arithmetic does not.
 */
object SwipeLevel {
    /** Loudest/brightest end of the range. */
    const val MAX = 1f

    /** Quietest end of a *volume* swipe: one percent, never silence. */
    const val VOLUME_MIN = 0.01f

    /** Darkest end of a *brightness* swipe: dark, but still readable. */
    const val BRIGHTNESS_MIN = 0.05f

    /**
     * Where a swipe that started at [start] ends after [dragDyPx] of travel.
     *
     * [viewportHeightPx] is the gesture area's height; a non-positive value
     * returns [start] clamped instead of dividing by zero (a layout that has
     * not been measured must not produce NaN into the engine).
     */
    fun apply(
        start: Float,
        dragDyPx: Float,
        viewportHeightPx: Float,
        min: Float = VOLUME_MIN,
    ): Float {
        val floor = min.coerceIn(0f, MAX)
        val base = start.coerceIn(floor, MAX)
        if (viewportHeightPx <= 0f) return base
        // A drag *down* (positive dy) is quieter/darker.
        return (base - dragDyPx / viewportHeightPx).coerceIn(floor, MAX)
    }
}

/** What a vertical swipe on the picture changes. */
enum class SwipeTarget { Volume, Brightness }

/**
 * Which of the two levels a swipe belongs to, from where it started.
 *
 * The split is by **the side the finger starts on**, not where it travels to: a
 * gesture that begins on the left half is the left gesture for its whole life,
 * so raising the volume cannot silently turn into raising the brightness as the
 * finger crosses the middle.
 */
object SwipeSides {
    fun targetFor(x: Float, width: Float, volumeOnLeft: Boolean): SwipeTarget {
        val onLeft = width > 0f && x < width / 2f
        return if (onLeft == volumeOnLeft) SwipeTarget.Volume else SwipeTarget.Brightness
    }
}

/** What the movement so far looks like. */
enum class SwipeAxis { Undecided, Vertical, Horizontal }

/**
 * Whether a drag is a **vertical** swipe, from the movement accumulated since
 * the finger went down.
 *
 * The plain vertical-drag detector was too eager: it claims the gesture as soon
 * as the vertical movement passes the touch slop, so a horizontal swipe with a
 * few pixels of drift was read as "raise the volume" — and, worse, consumed, so
 * nothing else could act on it. A swipe has to be **clearly more vertical than
 * horizontal** ([ratio] of it) before it owns the picture; a gesture that is
 * mostly horizontal is left alone from the moment it passes the slop, so the
 * system's own edge gestures and the tap layer still see it.
 *
 * Pure, so the rule is pinned by a JUnit test rather than by trying a phone.
 */
object SwipeAxisRule {
    /** How much more vertical than horizontal a swipe must be. */
    const val RATIO = 1.5f

    fun decide(
        dx: Float,
        dy: Float,
        touchSlop: Float,
        ratio: Float = RATIO,
    ): SwipeAxis {
        val horizontal = kotlin.math.abs(dx)
        val vertical = kotlin.math.abs(dy)
        if (vertical > touchSlop && vertical > horizontal * ratio) {
            return SwipeAxis.Vertical
        }
        if (horizontal > touchSlop) return SwipeAxis.Horizontal
        return SwipeAxis.Undecided
    }
}

/**
 * Whether a finished horizontal swipe on the picture means "previous channel".
 *
 * A swipe **right to left** is the back-like gesture every touch screen shares,
 * and in the player it returns to the channel that was playing before the
 * current one — the touch equivalent of a remote's Last channel key, and the
 * only way back on a phone whose control row has no such button (it carries
 * previous/next *in order*, which is a different move).
 *
 * Only that direction is claimed. A left-to-right swipe is left alone on
 * purpose: Android's own edge-Back starts there, and two meanings on one
 * direction would make a single swipe do two things.
 *
 * [minTravel] is in pixels and comes from the overlay's [PlayerDimens.SwipeMinTravel];
 * a drag shorter than that is a flick the user did not mean as a command.
 * Pure, so the direction and the threshold are pinned by a JUnit test rather
 * than by trying a phone.
 */
object SwipeZapRule {
    fun isPreviousChannel(dx: Float, minTravel: Float): Boolean =
        minTravel > 0f && dx <= -minTravel
}

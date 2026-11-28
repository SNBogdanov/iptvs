package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * The swipe-to-level mapping, the side split and the axis rule.
 *
 * The gestures themselves need a touch surface, but everything that can be
 * wrong about them is arithmetic: the direction, the ranges, the floors, the
 * side each gesture belongs to and whether a drag is vertical at all. A sign
 * flip here is a player whose swipe down gets louder, a missing clamp is a
 * player that asks the engine for 1.4, a zero volume floor is a swipe that
 * silently mutes, a zero brightness floor is a screen the user cannot see well
 * enough to swipe back, and a missing axis check is a horizontal swipe that
 * raises the volume.
 */
class SwipeLevelTest {
    @Test
    fun `up is more and down is less`() {
        // Screen coordinates grow downwards: a negative dy is a swipe up.
        assertEquals(0.6f, SwipeLevel.apply(0.5f, -100f, 1000f), 1e-6f)
        assertEquals(0.4f, SwipeLevel.apply(0.5f, 100f, 1000f), 1e-6f)
    }

    @Test
    fun `a full height is the whole range, at any screen size, up to 1`() {
        assertEquals(1f, SwipeLevel.apply(0f, -1000f, 1000f), 1e-6f)
        assertEquals(
            SwipeLevel.VOLUME_MIN + 0.5f,
            SwipeLevel.apply(0f, -270f, 540f),
            1e-6f,
        )
        assertEquals(1f, SwipeLevel.apply(0.5f, -500f, 1000f), 1e-6f)
    }

    @Test
    fun `volume floors at one percent and brightness at five`() {
        // Silence is the mute button's job, and a black screen cannot be swiped
        // back by a user who cannot see the picture.
        assertEquals(
            SwipeLevel.VOLUME_MIN,
            SwipeLevel.apply(1f, 1000f, 1000f, SwipeLevel.VOLUME_MIN),
            1e-6f,
        )
        assertEquals(
            SwipeLevel.BRIGHTNESS_MIN,
            SwipeLevel.apply(1f, 1000f, 1000f, SwipeLevel.BRIGHTNESS_MIN),
            1e-6f,
        )
        // The default floor is the volume one.
        assertEquals(
            SwipeLevel.VOLUME_MIN,
            SwipeLevel.apply(0.05f, 500f, 1000f),
            1e-6f,
        )
    }

    @Test
    fun `an unmeasured viewport cannot produce NaN`() {
        val result = SwipeLevel.apply(0.7f, -50f, 0f)
        assertFalse(result.isNaN())
        assertEquals(0.7f, result, 1e-6f)
        assertEquals(0.7f, SwipeLevel.apply(0.7f, -50f, -10f), 1e-6f)
    }

    @Test
    fun `the side the gesture starts on decides what it changes`() {
        // Default: volume left.
        assertEquals(SwipeTarget.Volume, SwipeSides.targetFor(100f, 1000f, true))
        assertEquals(SwipeTarget.Brightness, SwipeSides.targetFor(900f, 1000f, true))
        // Swapped.
        assertEquals(
            SwipeTarget.Brightness,
            SwipeSides.targetFor(100f, 1000f, volumeOnLeft = false),
        )
        assertEquals(
            SwipeTarget.Volume,
            SwipeSides.targetFor(900f, 1000f, volumeOnLeft = false),
        )
        // The exact middle belongs to the right half.
        assertEquals(SwipeTarget.Brightness, SwipeSides.targetFor(500f, 1000f, true))
        // An unmeasured width must not send the gesture to the wrong side.
        assertEquals(SwipeTarget.Brightness, SwipeSides.targetFor(1f, 0f, true))
    }

    @Test
    fun `a mostly horizontal drag is not a level swipe`() {
        // The reported bug: a horizontal swipe with a little vertical drift was
        // read as vertical (and consumed). Movement has to be clearly more
        // vertical than horizontal before it owns the picture.
        assertEquals(
            SwipeAxis.Horizontal,
            SwipeAxisRule.decide(dx = 300f, dy = 40f, touchSlop = 8f),
        )
        assertEquals(
            SwipeAxis.Horizontal,
            SwipeAxisRule.decide(dx = 100f, dy = 100f, touchSlop = 8f),
        )
        // A pure vertical swipe, and a clearly dominant one, are ours.
        assertEquals(
            SwipeAxis.Vertical,
            SwipeAxisRule.decide(dx = 0f, dy = 10f, touchSlop = 8f),
        )
        assertEquals(
            SwipeAxis.Vertical,
            SwipeAxisRule.decide(dx = 20f, dy = 200f, touchSlop = 8f),
        )
        // Nothing has happened yet.
        assertEquals(
            SwipeAxis.Undecided,
            SwipeAxisRule.decide(dx = 3f, dy = 4f, touchSlop = 8f),
        )
        // A diagonal that only just clears the slop is horizontal: the ratio,
        // not the slop alone, is what decides.
        assertEquals(
            SwipeAxis.Horizontal,
            SwipeAxisRule.decide(dx = 10f, dy = 12f, touchSlop = 8f),
        )
    }

    @Test
    fun `only a long right-to-left swipe changes the channel`() {
        val minTravel = 150f
        // Right to left, past the threshold: the previous channel.
        org.junit.Assert.assertTrue(SwipeZapRule.isPreviousChannel(-400f, minTravel))
        org.junit.Assert.assertTrue(SwipeZapRule.isPreviousChannel(-150f, minTravel))
        // A short flick is not a command.
        org.junit.Assert.assertFalse(SwipeZapRule.isPreviousChannel(-149f, minTravel))
        // The other direction is deliberately nobody's gesture: Android's own
        // edge-Back starts there.
        org.junit.Assert.assertFalse(SwipeZapRule.isPreviousChannel(400f, minTravel))
        // An unmeasured threshold must not turn every drag into a zap.
        org.junit.Assert.assertFalse(SwipeZapRule.isPreviousChannel(-400f, 0f))
    }
}

package com.gchofficial.iptvs.player

import android.content.pm.ActivityInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * The player orientation mode's on-disk and on-screen contract.
 *
 * Two things here are easy to break in a refactor and impossible to notice
 * without a phone in hand:
 *
 *  * **Which constant.** `SENSOR_LANDSCAPE` keeps both landscape sides and lets
 *    the accelerometer choose which is up; plain `LANDSCAPE` pins the "natural"
 *    side, so turning the phone over shows the picture and the text upside down.
 *    This test fails on that swap.
 *  * **The storage keys.** They are the whole persistence story — renaming one
 *    silently forgets every user's choice on the next launch, with no error
 *    anywhere.
 */
class PlayerOrientationTest {
    @Test
    fun `locked pins landscape with the sensor choosing which side is up`() {
        assertEquals(
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE,
            PlayerOrientation.requestedFor(locked = true),
        )
        // The two fixed-side constants are the regression this guards.
        assertNotEquals(
            ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE,
            PlayerOrientation.requestedFor(locked = true),
        )
        assertNotEquals(
            ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE,
            PlayerOrientation.requestedFor(locked = true),
        )
    }

    @Test
    fun `auto follows the device in all four orientations`() {
        assertEquals(
            ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR,
            PlayerOrientation.requestedFor(locked = false),
        )
    }

    @Test
    fun `the stored preference keeps its name`() {
        // Renaming either literal forgets the user's choice across launches.
        assertEquals("iptvs_player", PlayerOrientation.PREFS_NAME)
        assertEquals("orientation_locked", PlayerOrientation.KEY_LOCKED)
    }
}

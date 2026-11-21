package com.gchofficial.iptvs.player

import android.content.pm.ActivityInfo

/**
 * The player's orientation mode.
 *
 * A **device preference that only matters while the player is on screen**: it
 * is read once when [com.gchofficial.iptvs.HdrPlayerActivity] is created and
 * applied to that Activity's own window, so the channel list, settings and
 * every other screen keep their normal orientation. Leaving the player ends the
 * effect with the Activity; the *choice* survives, in SharedPreferences, and is
 * re-applied the next time the player opens (and after a process death or an
 * Activity recreation).
 *
 * Pure mapping on purpose: the interesting decision — landscape only, with the
 * **sensor** choosing which of the two sides is up — is one constant pair, and
 * a JVM test pins it so a refactor cannot quietly turn it into the plain
 * `LANDSCAPE`, which would show the picture (and the text) upside down when the
 * phone is turned over.
 */
object PlayerOrientation {
    /** SharedPreferences file for player-owned device preferences. */
    const val PREFS_NAME = "iptvs_player"

    /**
     * Whether the player pins landscape. The literal is part of the on-disk
     * contract: renaming it would silently forget everyone's choice, so a test
     * pins it too.
     */
    const val KEY_LOCKED = "orientation_locked"

    /**
     * The orientation to request.
     *
     * Locked is `SENSOR_LANDSCAPE`, not `LANDSCAPE`: both landscape sides stay
     * available and the accelerometer picks the one that is up. Unlocked is the
     * manifest's `fullSensor` — the player follows the device in all four
     * orientations, exactly as it does before the user ever presses the button.
     */
    fun requestedFor(locked: Boolean): Int = if (locked) {
        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    } else {
        ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
    }
}

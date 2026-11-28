package com.gchofficial.iptvs.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A list menu's opening guard.
 *
 * A hold opens the pace panel on release (a remote) or the aspect panel on its
 * long-press start (touch), and the same gesture can deliver a click at the
 * release point. Both the pace rows and the new dismiss backdrop ask this rule,
 * so a sign flip here is either a menu that closes the instant it opens or a
 * deliberate tap that is swallowed.
 */
class MenuOpenGuardTest {
    @Test
    fun `the gesture that opened the menu cannot act on it`() {
        // Opened at 1000 ms: the release click lands in the same instant.
        assertTrue(menuOpeningGuard(openedAtMs = 1_000L, nowMs = 1_000L))
        assertTrue(menuOpeningGuard(openedAtMs = 1_000L, nowMs = 1_399L))
    }

    @Test
    fun `a deliberate tap after the guard is accepted`() {
        // The boundary itself is open: 400 ms after opening is a second gesture.
        assertFalse(menuOpeningGuard(openedAtMs = 1_000L, nowMs = 1_400L))
        assertFalse(menuOpeningGuard(openedAtMs = 1_000L, nowMs = 5_000L))
    }
}

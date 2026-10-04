// Unit tests for ReceptionPromotion: the plain state machine behind the `promote`/`release`
// handshake on MethodChannel sdr/background (docs/native-n2-adr.md, "N2 close-out").
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ReceptionPromotionTest {
    private var attemptStartCalls = 0
    private var cleanupCalls = 0
    private var scheduledRunnable: Runnable? = null
    private var cancelledRunnable: Runnable? = null

    private fun newPromotion(): ReceptionPromotion = ReceptionPromotion(
        attemptStart = { attemptStartCalls++ },
        scheduleTimeout = { scheduledRunnable = it },
        cancelTimeout = { cancelledRunnable = it },
        requestCleanup = { cleanupCalls++ },
    )

    @Test fun `promote success replies only after the ready signal`() {
        val promotion = newPromotion()
        val outcomes = mutableListOf<ReceptionPromotion.Outcome>()
        promotion.requestPromotion { outcomes += it }
        assertEquals(1, attemptStartCalls)
        assertTrue(outcomes.isEmpty()) // no reply before readiness
        promotion.onForegroundReady()
        assertEquals(listOf(ReceptionPromotion.Outcome.Success), outcomes)
        assertTrue(promotion.isPromoted)
        assertSame(scheduledRunnable, cancelledRunnable) // timeout cancelled on success
        assertEquals(0, cleanupCalls)
    }

    @Test fun `focus denial fails promotion and requests cleanup`() {
        val promotion = newPromotion()
        val outcomes = mutableListOf<ReceptionPromotion.Outcome>()
        promotion.requestPromotion { outcomes += it }
        promotion.onPromotionFailed("Audio focus denied")
        assertEquals(listOf(ReceptionPromotion.Outcome.Failure("Audio focus denied")), outcomes)
        assertFalse(promotion.isPromoted)
        assertEquals(1, cleanupCalls)
    }

    @Test fun `promote during an ordered teardown fails immediately without an attempt`() {
        val promotion = newPromotion()
        promotion.onTeardownStarted()
        val outcomes = mutableListOf<ReceptionPromotion.Outcome>()
        promotion.requestPromotion { outcomes += it }
        assertEquals(0, attemptStartCalls) // never even tries
        assertEquals(1, outcomes.size)
        assertTrue(outcomes.single() is ReceptionPromotion.Outcome.Failure)
    }

    @Test fun `second promote while already promoted succeeds immediately`() {
        val promotion = newPromotion()
        promotion.requestPromotion {}
        promotion.onForegroundReady()
        attemptStartCalls = 0
        val outcomes = mutableListOf<ReceptionPromotion.Outcome>()
        promotion.requestPromotion { outcomes += it }
        assertEquals(listOf(ReceptionPromotion.Outcome.Success), outcomes)
        assertEquals(0, attemptStartCalls) // no second attempt started
    }

    @Test fun `release when idle is a no-op`() {
        val promotion = newPromotion()
        promotion.requestRelease()
        assertEquals(0, cleanupCalls)
        assertFalse(promotion.isPromoted)
    }

    @Test fun `release while promoted cleans up and is idempotent`() {
        val promotion = newPromotion()
        promotion.requestPromotion {}
        promotion.onForegroundReady()
        promotion.requestRelease()
        assertEquals(1, cleanupCalls)
        assertFalse(promotion.isPromoted)
        promotion.requestRelease() // second release: already idle, no second cleanup
        assertEquals(1, cleanupCalls)
    }

    @Test fun `release during an ordered teardown does nothing (no second teardown)`() {
        val promotion = newPromotion()
        promotion.requestPromotion {}
        promotion.onForegroundReady()
        promotion.onTeardownStarted() // e.g. focus loss while promoted
        promotion.requestRelease()
        assertEquals(0, cleanupCalls) // the ordered teardown owns tearing PROMOTED down
        assertTrue(promotion.isPromoted) // state is left for the ordered teardown, not touched
    }

    @Test fun `timeout fails promotion exactly once`() {
        val promotion = newPromotion()
        val outcomes = mutableListOf<ReceptionPromotion.Outcome>()
        promotion.requestPromotion { outcomes += it }
        scheduledRunnable!!.run() // simulate the 10s safeguard firing
        assertEquals(1, outcomes.size)
        assertTrue(outcomes.single() is ReceptionPromotion.Outcome.Failure)
        assertEquals(1, cleanupCalls)
        // A late ready signal arriving after the timeout must not reply again.
        promotion.onForegroundReady()
        assertEquals(1, outcomes.size)
        assertEquals(1, cleanupCalls)
    }

    @Test fun `exactly once reply even with a duplicate late failure signal`() {
        val promotion = newPromotion()
        val outcomes = mutableListOf<ReceptionPromotion.Outcome>()
        promotion.requestPromotion { outcomes += it }
        promotion.onForegroundReady()
        assertEquals(1, outcomes.size)
        // Late/duplicate failure signal arriving after success must be ignored.
        promotion.onPromotionFailed("late focus loss")
        assertEquals(1, outcomes.size)
        assertEquals(0, cleanupCalls)
        assertTrue(promotion.isPromoted)
    }

    @Test fun `queued promote calls while promoting all receive the same outcome exactly once`() {
        val promotion = newPromotion()
        val outcomes = mutableListOf<ReceptionPromotion.Outcome>()
        promotion.requestPromotion { outcomes += it }
        promotion.requestPromotion { outcomes += it } // second call races in before readiness
        assertEquals(1, attemptStartCalls) // only one attempt started
        promotion.onForegroundReady()
        assertEquals(2, outcomes.size)
        assertTrue(outcomes.all { it == ReceptionPromotion.Outcome.Success })
    }
}

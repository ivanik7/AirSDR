// Unit tests for SdrStatsSnapshot.parse — field order/validation of the packed JNI stats array.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SdrStatsSnapshotTest {
    @Test
    fun `parse returns null for null input`() {
        assertNull(SdrStatsSnapshot.parse(null))
    }

    @Test
    fun `parse returns null for wrong length - ABI mismatch must not be papered over`() {
        assertNull(SdrStatsSnapshot.parse(longArrayOf(1, 2, 3)))
    }

    @Test
    fun `parse maps fields in the documented order`() {
        val raw = longArrayOf(
            SdrState.RUNNING.code.toLong(),
            SdrSource.HACKRF.code.toLong(),
            SdrResult.IO_ERROR.code.toLong(),
            2_400_000L,
            433_000_000L,
            100L,
            1000L,
            990L,
            10L,
            0xDEADBEEFL,
        )
        val snapshot = SdrStatsSnapshot.parse(raw)!!
        assertEquals(SdrState.RUNNING, snapshot.state)
        assertEquals(SdrSource.HACKRF, snapshot.source)
        assertEquals(SdrResult.IO_ERROR, snapshot.lastError)
        assertEquals(2_400_000L, snapshot.sampleRate)
        assertEquals(433_000_000L, snapshot.frequencyHz)
        assertEquals(100L, snapshot.gainTenthsDb)
        assertEquals(1000L, snapshot.inputSamples)
        assertEquals(990L, snapshot.processedSamples)
        assertEquals(10L, snapshot.droppedSamples)
        assertEquals(0xDEADBEEFL, snapshot.checksum)
    }

    @Test
    fun `unknown state or source codes fall back to UNKNOWN or NONE instead of crashing`() {
        val raw = longArrayOf(999L, 999L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L)
        val snapshot = SdrStatsSnapshot.parse(raw)!!
        assertEquals(SdrState.UNKNOWN, snapshot.state)
        assertEquals(SdrSource.NONE, snapshot.source)
    }
}

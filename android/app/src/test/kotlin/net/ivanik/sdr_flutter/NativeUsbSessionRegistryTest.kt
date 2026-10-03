// Unit tests for NativeUsbSessionRegistry: lazy per-device sessions and ordered teardown.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeUsbSessionRegistryTest {
    @Test
    fun `sessionFor creates one session per device and reuses it`() {
        val registry = NativeUsbSessionRegistry { FakeSdrNativeBridge() }
        val a1 = registry.sessionFor("dev1")
        val a2 = registry.sessionFor("dev1")
        val b = registry.sessionFor("dev2")
        assertSame(a1, a2)
        assertTrue(a1 !== b)
    }

    @Test
    fun `existing returns null before any session was requested`() {
        val registry = NativeUsbSessionRegistry { FakeSdrNativeBridge() }
        assertNull(registry.existing("dev1"))
        registry.sessionFor("dev1")
        assertEquals(registry.sessionFor("dev1"), registry.existing("dev1"))
    }

    @Test
    fun `closeAndRemove with no session is a no-op returning OK`() {
        val registry = NativeUsbSessionRegistry { FakeSdrNativeBridge() }
        assertEquals(SdrResult.OK, registry.closeAndRemove("dev1"))
    }

    @Test
    fun `closeAndRemove stops and closes a running session and forgets it`() {
        val bridge = FakeSdrNativeBridge()
        val registry = NativeUsbSessionRegistry { bridge }
        val session = registry.sessionFor("dev1")
        session.open(42, SdrSource.RTLSDR)
        session.start()
        val rc = registry.closeAndRemove("dev1")
        assertEquals(SdrResult.OK, rc)
        assertEquals(NativeUsbSession.Phase.CLOSED, session.phase)
        assertNull(registry.existing("dev1"))
    }

    @Test
    fun `closeAll tears down every tracked device independently`() {
        val registry = NativeUsbSessionRegistry { FakeSdrNativeBridge() }
        val s1 = registry.sessionFor("dev1").also { it.open(1, SdrSource.RTLSDR) }
        val s2 = registry.sessionFor("dev2").also { it.open(2, SdrSource.HACKRF) }
        registry.closeAll()
        assertEquals(NativeUsbSession.Phase.CLOSED, s1.phase)
        assertEquals(NativeUsbSession.Phase.CLOSED, s2.phase)
        assertNull(registry.existing("dev1"))
        assertNull(registry.existing("dev2"))
    }

    @Test
    fun `reopening a device after closeAndRemove creates a fresh session`() {
        val registry = NativeUsbSessionRegistry { FakeSdrNativeBridge() }
        val first = registry.sessionFor("dev1")
        first.open(42, SdrSource.RTLSDR)
        registry.closeAndRemove("dev1")
        val second = registry.sessionFor("dev1")
        assertTrue(first !== second)
        assertEquals(NativeUsbSession.Phase.IDLE, second.phase)
    }
}

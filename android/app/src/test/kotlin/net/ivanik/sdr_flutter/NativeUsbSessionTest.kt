// Unit tests for NativeUsbSession against FakeSdrNativeBridge (no real native library).
// Covers the open/configure/start/stop/close state machine and that close() is synchronous,
// idempotent and matches native/include/sdrcore.h ordering (stop before close before destroy).
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeUsbSessionTest {
    @Test
    fun `open from idle succeeds and moves to OPENED`() {
        val bridge = FakeSdrNativeBridge()
        val session = NativeUsbSession(bridge, "dev1")
        val rc = session.open(fd = 42, source = SdrSource.RTLSDR)
        assertEquals(SdrResult.OK, rc)
        assertEquals(NativeUsbSession.Phase.OPENED, session.phase)
    }

    @Test
    fun `double open is rejected as invalid state, does not leak a second handle`() {
        val bridge = FakeSdrNativeBridge()
        val session = NativeUsbSession(bridge, "dev1")
        session.open(42, SdrSource.RTLSDR)
        val rc = session.open(42, SdrSource.RTLSDR)
        assertEquals(SdrResult.INVALID_STATE, rc)
        assertEquals(1, bridge.calls.count { it.name == "create" })
    }

    @Test
    fun `failed native openUsb destroys the handle and leaves session idle`() {
        val bridge = FakeSdrNativeBridge().apply { openUsbResult = SdrResult.UNSUPPORTED.code }
        val session = NativeUsbSession(bridge, "dev1")
        val rc = session.open(42, SdrSource.RTLSDR)
        assertEquals(SdrResult.UNSUPPORTED, rc)
        assertEquals(NativeUsbSession.Phase.IDLE, session.phase)
        assertEquals(1, bridge.calls.count { it.name == "destroy" })
    }

    @Test
    fun `unsupported native ABI is rejected before allocating a handle`() {
        val bridge = FakeSdrNativeBridge().apply { abiVersion = 1 }
        val session = NativeUsbSession(bridge, "dev1")
        assertEquals(SdrResult.BRIDGE_UNAVAILABLE, session.open(42, SdrSource.RTLSDR))
        assertTrue(bridge.calls.isEmpty())
    }

    @Test
    fun `start requires OPENED, then moves to RUNNING`() {
        val bridge = FakeSdrNativeBridge()
        val session = NativeUsbSession(bridge, "dev1")
        assertEquals(SdrResult.INVALID_STATE, session.start()) // not opened yet
        session.open(42, SdrSource.RTLSDR)
        assertEquals(SdrResult.OK, session.start())
        assertEquals(NativeUsbSession.Phase.RUNNING, session.phase)
        assertEquals(SdrResult.INVALID_STATE, session.start()) // double start
    }

    @Test
    fun `stop requires RUNNING, then returns to OPENED`() {
        val bridge = FakeSdrNativeBridge()
        val session = NativeUsbSession(bridge, "dev1")
        session.open(42, SdrSource.RTLSDR)
        assertEquals(SdrResult.INVALID_STATE, session.stop()) // not running
        session.start()
        assertEquals(SdrResult.OK, session.stop())
        assertEquals(NativeUsbSession.Phase.OPENED, session.phase)
    }

    @Test
    fun `configure is rejected before open and after close`() {
        val bridge = FakeSdrNativeBridge()
        val session = NativeUsbSession(bridge, "dev1")
        assertEquals(SdrResult.INVALID_STATE, session.configure(100_000_000L, 2_400_000, 0))
        session.open(42, SdrSource.RTLSDR)
        assertEquals(SdrResult.OK, session.configure(100_000_000L, 2_400_000, 0))
        session.close()
        assertEquals(SdrResult.INVALID_STATE, session.configure(100_000_000L, 2_400_000, 0))
    }

    @Test
    fun `close while running stops first, then closes, then destroys - in that order`() {
        val bridge = FakeSdrNativeBridge()
        val session = NativeUsbSession(bridge, "dev1")
        session.open(42, SdrSource.RTLSDR)
        session.start()
        bridge.calls.clear()
        val rc = session.close()
        assertEquals(SdrResult.OK, rc)
        assertEquals(NativeUsbSession.Phase.CLOSED, session.phase)
        val order = bridge.calls.map { it.name }
        assertEquals(listOf("stop", "close", "destroy"), order)
    }

    @Test
    fun `close is idempotent - second call is a no-op returning OK`() {
        val bridge = FakeSdrNativeBridge()
        val session = NativeUsbSession(bridge, "dev1")
        session.open(42, SdrSource.RTLSDR)
        session.start()
        assertEquals(SdrResult.OK, session.close())
        bridge.calls.clear()
        assertEquals(SdrResult.OK, session.close())
        assertTrue(bridge.calls.isEmpty())
    }

    @Test
    fun `close from IDLE (never opened) is a no-op returning OK`() {
        val bridge = FakeSdrNativeBridge()
        val session = NativeUsbSession(bridge, "dev1")
        assertEquals(SdrResult.OK, session.close())
        assertEquals(NativeUsbSession.Phase.CLOSED, session.phase)
        assertTrue(bridge.calls.isEmpty())
    }

    @Test
    fun `stats returns null before open and after close, non-null while open or running`() {
        val bridge = FakeSdrNativeBridge()
        val session = NativeUsbSession(bridge, "dev1")
        assertEquals(null, session.stats())
        session.open(42, SdrSource.RTLSDR)
        assertTrue(session.stats() != null)
        session.close()
        assertEquals(null, session.stats())
    }
}

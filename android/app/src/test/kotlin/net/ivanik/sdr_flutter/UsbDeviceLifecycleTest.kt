// Unit tests for UsbDeviceLifecycle: single connection owner, close-exactly-once, Dart xor native
// exclusivity, native-before-Java teardown ordering on close/detach/shutdown, and reconnect.
// Executors are manual queues so tests control when the "control thread" and "main thread" run.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.ArrayDeque
import java.util.concurrent.Executor

class UsbDeviceLifecycleTest {
    private class QueueExecutor : Executor {
        val tasks = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) { tasks.add(command) }
        fun runAll(): Int { var n = 0; while (tasks.isNotEmpty()) { tasks.poll()!!.run(); n++ }; return n }
    }

    private class FakeConnection(val fd: Int) {
        var closeCount = 0
    }

    private val events = mutableListOf<String>()
    private val fake = FakeSdrNativeBridge()
    private val recordingBridge = object : SdrNativeBridge by fake {
        override fun stop(handle: Long): Int { events += "native.stop"; return fake.stop(handle) }
        override fun close(handle: Long): Int { events += "native.close"; return fake.close(handle) }
        override fun destroy(handle: Long) { events += "native.destroy"; fake.destroy(handle) }
        override fun openUsb(handle: Long, fd: Int, source: Int): Int {
            events += "native.open($fd)"
            return fake.openUsb(handle, fd, source)
        }
    }
    private val control = QueueExecutor()
    private val main = QueueExecutor()
    private val lifecycle = UsbDeviceLifecycle<FakeConnection>(
        fdOf = { it.fd },
        closeConnection = { c -> c.closeCount++; events += "java.close(${c.fd})" },
        sessions = NativeUsbSessionRegistry { recordingBridge },
        nativeExecutor = control,
        mainExecutor = main,
    )

    private fun drain() { while (control.runAll() + main.runAll() > 0) {} }

    private fun openNative(name: String, conn: FakeConnection, source: SdrSource = SdrSource.RTLSDR): SdrResult? {
        assertTrue(lifecycle.tryAcquire(name, UsbSessionOwnership.Owner.NATIVE))
        lifecycle.adopt(name, conn)
        var rc: SdrResult? = null
        lifecycle.nativeOpen(name, source) { rc = it }
        drain()
        return rc
    }

    @Test
    fun `native open borrows the connection fd and never closes the Java connection`() {
        val conn = FakeConnection(41)
        assertEquals(SdrResult.OK, openNative("d", conn))
        assertEquals(listOf("native.open(41)"), events)
        assertEquals(0, conn.closeCount)
        assertSame(conn, lifecycle.connection("d"))
    }

    @Test
    fun `native commands run only on the control executor`() {
        openNative("d", FakeConnection(41))
        var rc: SdrResult? = null
        lifecycle.nativeCommand("d", { it.start() }) { rc = it }
        assertNull(rc)
        assertEquals(1, control.tasks.size) // nothing native ran on the caller's thread
        drain()
        assertEquals(SdrResult.OK, rc)
    }

    @Test
    fun `Dart cannot open or close a device held by native`() {
        val conn = FakeConnection(41)
        openNative("d", conn)
        assertFalse(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.DART))
        assertFalse(lifecycle.dartClose("d"))
        assertEquals(0, conn.closeCount)
    }

    @Test
    fun `native cannot claim a device held by Dart`() {
        assertTrue(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.DART))
        lifecycle.adopt("d", FakeConnection(41))
        assertFalse(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.NATIVE))
    }

    @Test
    fun `nativeClose stops, closes and destroys native before closing Java exactly once`() {
        val conn = FakeConnection(41)
        openNative("d", conn)
        lifecycle.nativeCommand("d", { it.start() }) {}
        drain()
        events.clear()
        var rc: SdrResult? = null
        lifecycle.nativeClose("d") { rc = it }
        // Until the control thread has run, Dart may not take the device over.
        assertFalse(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.DART))
        drain()
        assertEquals(SdrResult.OK, rc)
        assertEquals(listOf("native.stop", "native.close", "native.destroy", "java.close(41)"), events)
        assertEquals(1, conn.closeCount)
        assertNull(lifecycle.connection("d"))
        assertTrue(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.DART))
    }

    @Test
    fun `repeated nativeClose never closes the Java connection twice`() {
        val conn = FakeConnection(41)
        openNative("d", conn)
        lifecycle.nativeClose("d") {}
        lifecycle.nativeClose("d") {}
        drain()
        lifecycle.nativeClose("d") {}
        drain()
        assertEquals(1, conn.closeCount)
        assertEquals(1, events.count { it == "native.destroy" })
    }

    @Test
    fun `detach of a running native device tears down native before the Java connection`() {
        val conn = FakeConnection(41)
        openNative("d", conn)
        lifecycle.nativeCommand("d", { it.start() }) {}
        drain()
        events.clear()
        lifecycle.onDeviceDetached("d")
        assertNull(lifecycle.connection("d"))
        assertEquals(0, conn.closeCount) // Java connection outlives the native session
        assertTrue(lifecycle.isRetiring("d"))
        drain()
        assertEquals(listOf("native.stop", "native.close", "native.destroy", "java.close(41)"), events)
        assertEquals(1, conn.closeCount)
        assertNull(lifecycle.currentOwner("d"))
    }

    @Test
    fun `detach racing a queued nativeClose closes the Java connection exactly once`() {
        val conn = FakeConnection(41)
        openNative("d", conn)
        lifecycle.nativeClose("d") {}
        lifecycle.onDeviceDetached("d")
        drain()
        assertEquals(1, conn.closeCount)
        assertEquals(1, events.count { it == "native.destroy" })
        assertFalse(lifecycle.isRetiring("d"))
    }

    @Test
    fun `reconnect is refused while teardown is in flight and gets a fresh session after`() {
        val old = FakeConnection(41)
        openNative("d", old)
        lifecycle.onDeviceDetached("d")
        assertFalse(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.NATIVE))
        assertFalse(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.DART))
        drain()
        events.clear()
        val fresh = FakeConnection(57)
        assertEquals(SdrResult.OK, openNative("d", fresh))
        assertEquals(listOf("native.open(57)"), events)
        assertEquals(1, old.closeCount)
        assertEquals(0, fresh.closeCount)
    }

    @Test
    fun `detach of a Dart-held device closes immediately without touching native`() {
        val conn = FakeConnection(41)
        assertTrue(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.DART))
        lifecycle.adopt("d", conn)
        lifecycle.onDeviceDetached("d")
        assertEquals(1, conn.closeCount)
        assertTrue(control.tasks.isEmpty())
        assertNull(lifecycle.currentOwner("d"))
    }

    @Test
    fun `Dart open and close keep the existing behaviour`() {
        val conn = FakeConnection(41)
        assertTrue(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.DART))
        lifecycle.adopt("d", conn)
        assertTrue(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.DART)) // re-open
        assertSame(conn, lifecycle.connection("d"))
        assertTrue(lifecycle.dartClose("d"))
        assertTrue(lifecycle.dartClose("d")) // second close is a no-op
        assertEquals(1, conn.closeCount)
        assertTrue(control.tasks.isEmpty())
    }

    @Test
    fun `failed native open releases the claim and closes the connection it opened`() {
        fake.openUsbResult = SdrResult.IO_ERROR.code
        val conn = FakeConnection(41)
        assertEquals(SdrResult.IO_ERROR, openNative("d", conn))
        assertEquals(1, conn.closeCount)
        assertNull(lifecycle.currentOwner("d"))
        assertTrue(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.DART))
    }

    @Test
    fun `second native open is idempotent for the same source and refused for another`() {
        openNative("d", FakeConnection(41))
        var rc: SdrResult? = null
        lifecycle.nativeOpen("d", SdrSource.RTLSDR) { rc = it }
        drain()
        assertEquals(SdrResult.OK, rc)
        lifecycle.nativeOpen("d", SdrSource.HACKRF) { rc = it }
        drain()
        assertEquals(SdrResult.INVALID_STATE, rc)
        assertEquals(1, events.count { it.startsWith("native.open") })
        assertEquals(UsbSessionOwnership.Owner.NATIVE, lifecycle.currentOwner("d"))
    }

    @Test
    fun `abandon after a denied permission frees the device`() {
        assertTrue(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.NATIVE))
        lifecycle.abandon("d", UsbSessionOwnership.Owner.NATIVE)
        assertTrue(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.DART))
    }

    @Test
    fun `stopAllNative stops running streams but keeps sessions and connections open`() {
        val conn = FakeConnection(41)
        openNative("d", conn)
        lifecycle.nativeCommand("d", { it.start() }) {}
        drain()
        events.clear()
        var done = false
        lifecycle.stopAllNative { done = true }
        drain()
        assertTrue(done)
        assertEquals(listOf("native.stop"), events)
        assertEquals(0, conn.closeCount)
        var rc: SdrResult? = null
        lifecycle.nativeCommand("d", { it.start() }) { rc = it } // restart after stop
        drain()
        assertEquals(SdrResult.OK, rc)
    }

    @Test
    fun `service Stop closes every native session and fd before acknowledging`() {
        val first = FakeConnection(41)
        val second = FakeConnection(42)
        openNative("a", first)
        openNative("b", second)
        lifecycle.nativeCommand("a", { it.start() }) {}
        lifecycle.nativeCommand("b", { it.start() }) {}
        drain()
        events.clear()
        var done = false
        lifecycle.closeAllNative { done = true; events += "service.done" }
        assertFalse(done)
        assertFalse(lifecycle.tryAcquire("a", UsbSessionOwnership.Owner.DART))
        control.runAll()
        assertFalse(done)
        main.runAll()
        assertTrue(done)
        assertEquals(1, first.closeCount)
        assertEquals(1, second.closeCount)
        assertTrue(events.indexOf("service.done") > events.indexOf("java.close(41)"))
        assertTrue(events.indexOf("service.done") > events.indexOf("java.close(42)"))
        assertTrue(lifecycle.tryAcquire("a", UsbSessionOwnership.Owner.DART))
        lifecycle.closeAllNative { events += "again.done" }
        drain()
        assertEquals(1, first.closeCount)
    }

    @Test
    fun `service Stop racing detach waits until Java fd closes`() {
        val conn = FakeConnection(41)
        openNative("a", conn)
        lifecycle.onDeviceDetached("a")
        var done = false
        lifecycle.closeAllNative { done = true }
        drain()
        assertTrue(done)
        assertEquals(1, conn.closeCount)
        assertEquals(1, events.count { it == "native.destroy" })
    }

    @Test
    fun `shutdown closes native sessions before their Java connections and Dart ones directly`() {
        val nativeConn = FakeConnection(41)
        openNative("n", nativeConn)
        lifecycle.nativeCommand("n", { it.start() }) {}
        drain()
        val dartConn = FakeConnection(42)
        assertTrue(lifecycle.tryAcquire("d", UsbSessionOwnership.Owner.DART))
        lifecycle.adopt("d", dartConn)
        events.clear()
        lifecycle.shutdown()
        assertEquals(listOf("java.close(42)"), events)
        assertEquals(0, nativeConn.closeCount)
        control.runAll() // main thread may already be gone: teardown completes on control
        assertEquals(
            listOf("java.close(42)", "native.stop", "native.close", "native.destroy", "java.close(41)"),
            events,
        )
        assertEquals(1, nativeConn.closeCount)
        assertEquals(1, dartConn.closeCount)
    }

    @Test
    fun `commands without a native session report null`() {
        var called = false
        var rc: SdrResult? = SdrResult.OK
        lifecycle.nativeCommand("missing", { it.start() }) { called = true; rc = it }
        drain()
        assertTrue(called)
        assertNull(rc)
    }
}

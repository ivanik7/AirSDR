// FakeSdrNativeBridge — in-memory SdrNativeBridge test double, no native library involved.
//
// Models the ABI 2 state machine (native/include/sdrcore.h) closely enough to exercise
// NativeUsbSession and NativeUsbSessionRegistry: one handle per create(), OPEN/RUNNING tracked
// per handle, double start/stop return the same error codes the real engine would
// (SDR_INVALID_STATE), and destroy()/close() forget the handle so a stale handle can't be
// reused. Test-only: lives under src/test, never packaged into the app.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

class FakeSdrNativeBridge : SdrNativeBridge {
    data class Call(val name: String, val handle: Long)

    val calls = mutableListOf<Call>()

    private var nextHandle = 1L
    private val openHandles = HashMap<Long, Boolean>() // handle -> running

    /** When set, the next openUsb() call returns this code instead of SDR_OK. */
    var openUsbResult: Int = SdrResult.OK.code

    /** When set, start()/stop() return this instead of success, without changing state. */
    var forceStartResult: Int? = null
    var forceStopResult: Int? = null

    var abiVersion: Int = 2
    override fun version(): Int = abiVersion

    override fun create(): Long {
        val h = nextHandle++
        calls += Call("create", h)
        return h
    }

    override fun destroy(handle: Long) {
        calls += Call("destroy", handle)
        openHandles.remove(handle)
    }

    override fun openUsb(handle: Long, fd: Int, source: Int): Int {
        calls += Call("openUsb", handle)
        if (openUsbResult != SdrResult.OK.code) return openUsbResult
        openHandles[handle] = false
        return SdrResult.OK.code
    }

    override fun configure(handle: Long, frequencyHz: Long, samplesPerSecond: Int, gainTenthsDb: Int): Int {
        calls += Call("configure", handle)
        return if (openHandles.containsKey(handle)) SdrResult.OK.code else SdrResult.INVALID_STATE.code
    }

    override fun start(handle: Long): Int {
        calls += Call("start", handle)
        forceStartResult?.let { return it }
        val running = openHandles[handle] ?: return SdrResult.INVALID_STATE.code
        if (running) return SdrResult.INVALID_STATE.code
        openHandles[handle] = true
        return SdrResult.OK.code
    }

    override fun stop(handle: Long): Int {
        calls += Call("stop", handle)
        forceStopResult?.let { return it }
        val running = openHandles[handle] ?: return SdrResult.INVALID_STATE.code
        if (!running) return SdrResult.INVALID_STATE.code
        openHandles[handle] = false
        return SdrResult.OK.code
    }

    override fun close(handle: Long): Int {
        calls += Call("close", handle)
        if (!openHandles.containsKey(handle)) return SdrResult.INVALID_STATE.code
        openHandles.remove(handle)
        return SdrResult.OK.code
    }

    override fun stats(handle: Long): LongArray? {
        calls += Call("stats", handle)
        val running = openHandles[handle] ?: return null
        return longArrayOf(
            if (running) SdrState.RUNNING.code.toLong() else SdrState.OPEN.code.toLong(),
            SdrSource.RTLSDR.code.toLong(),
            SdrResult.OK.code.toLong(),
            2_400_000L,
            100_000_000L,
            0L,
            1234L,
            1230L,
            4L,
            999L,
        )
    }

    fun isOpen(handle: Long): Boolean = openHandles.containsKey(handle)
}

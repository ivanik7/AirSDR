// NativeUsbSession — one native sdrcore engine bound to a single USB device's borrowed fd.
//
// Mirrors the state machine and ordering rules in native/include/sdrcore.h: public commands are
// serialized by one owner (here: `synchronized(lock)`), sdr_v2_start/stop toggle OPEN<->RUNNING,
// and closing is synchronous — sdr_v2_stop/sdr_v2_close/sdr_destroy must all return before the
// caller may close the Java UsbDeviceConnection that the fd came from (see
// docs/native-n1-status.md and UsbSdrPlugin.kt's fd lifecycle comment). This class never
// duplicates the fd itself: it hands the live UsbDeviceConnection fd straight to
// sdr_v2_open_usb(), which the header says duplicates it internally and closes only its own
// duplicate.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

class NativeUsbSession(
    private val bridge: SdrNativeBridge,
    val deviceName: String,
) {
    enum class Phase { IDLE, OPENED, RUNNING, CLOSED }

    private val lock = Any()
    private var handle: Long = 0L

    @Volatile
    var phase: Phase = Phase.IDLE
        private set

    @Volatile
    var source: SdrSource? = null
        private set

    /** True between a successful open and close (OPENED or RUNNING). */
    val isActive: Boolean
        get() = phase == Phase.OPENED || phase == Phase.RUNNING

    /** Last raw SdrResult code observed from an open/configure/start/stop/close call, for
     * diagnostics; SdrResult.OK initially. */
    @Volatile
    var lastResult: SdrResult = SdrResult.OK
        private set

    /**
     * Opens a native engine against [fd] for [source] (RTLSDR or HACKRF). The caller
     * (UsbSdrPlugin.acquireFdForNative) must hold USB session ownership for [deviceName] before
     * calling this, and must keep the underlying UsbDeviceConnection open until [close] returns.
     */
    fun open(fd: Int, source: SdrSource): SdrResult = synchronized(lock) {
        if (phase != Phase.IDLE) return remember(SdrResult.INVALID_STATE)
        if (bridge.version() != 2) return remember(SdrResult.BRIDGE_UNAVAILABLE)
        val h = bridge.create()
        if (h == 0L) return remember(SdrResult.INTERNAL_ERROR)
        val rc = SdrResult.fromCode(bridge.openUsb(h, fd, source.code))
        if (rc != SdrResult.OK) {
            bridge.destroy(h)
            return remember(rc)
        }
        handle = h
        this.source = source
        phase = Phase.OPENED
        return remember(SdrResult.OK)
    }

    fun configure(frequencyHz: Long, samplesPerSecond: Int, gainTenthsDb: Int): SdrResult = synchronized(lock) {
        if (phase == Phase.IDLE || phase == Phase.CLOSED) return remember(SdrResult.INVALID_STATE)
        remember(SdrResult.fromCode(bridge.configure(handle, frequencyHz, samplesPerSecond, gainTenthsDb)))
    }

    fun start(): SdrResult = synchronized(lock) {
        if (phase != Phase.OPENED) return remember(SdrResult.INVALID_STATE)
        val rc = SdrResult.fromCode(bridge.start(handle))
        if (rc == SdrResult.OK) phase = Phase.RUNNING
        return remember(rc)
    }

    fun stop(): SdrResult = synchronized(lock) {
        if (phase != Phase.RUNNING) return remember(SdrResult.INVALID_STATE)
        val rc = SdrResult.fromCode(bridge.stop(handle))
        if (rc == SdrResult.OK) phase = Phase.OPENED
        return remember(rc)
    }

    fun stats(): SdrStatsSnapshot? = synchronized(lock) {
        if (phase == Phase.IDLE || phase == Phase.CLOSED) return null
        SdrStatsSnapshot.parse(bridge.stats(handle))
    }

    /**
     * Stops (if running) and closes synchronously, then destroys the handle. Idempotent: a
     * second call once CLOSED is a no-op returning SDR_OK. Blocks the calling thread until the
     * native engine has fully stopped and joined, by construction of the synchronous ABI. In
     * production it only runs on UsbDeviceLifecycle's serial native executor, never on the
     * Android main thread.
     */
    fun close(): SdrResult = synchronized(lock) {
        when (phase) {
            Phase.CLOSED -> return SdrResult.OK
            Phase.IDLE -> {
                phase = Phase.CLOSED
                return SdrResult.OK
            }
            else -> {}
        }
        var rc = SdrResult.OK
        if (phase == Phase.RUNNING) {
            rc = SdrResult.fromCode(bridge.stop(handle))
        }
        val closeRc = SdrResult.fromCode(bridge.close(handle))
        bridge.destroy(handle)
        handle = 0L
        source = null
        phase = Phase.CLOSED
        return remember(if (rc != SdrResult.OK) rc else closeRc)
    }

    private fun remember(result: SdrResult): SdrResult {
        lastResult = result
        return result
    }
}

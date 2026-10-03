// NativeUsbSessionRegistry — one NativeUsbSession per USB deviceName, created lazily.
//
// Kept separate from UsbSdrPlugin so the lifecycle/exclusivity logic is testable on a plain JVM
// (see NativeUsbSessionRegistryTest.kt): no android.* imports here. UsbSdrPlugin is the only
// production caller and is responsible for pairing registry operations with
// UsbSessionOwnership and the UsbDeviceConnection map so a native session can never outlive the
// Java connection whose fd it was given.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

class NativeUsbSessionRegistry(private val bridgeFactory: () -> SdrNativeBridge) {
    private val lock = Any()
    private val sessions = HashMap<String, NativeUsbSession>()

    /** Returns the existing session for [deviceName], creating one with a fresh bridge instance
     * if none exists yet. The session starts in [NativeUsbSession.Phase.IDLE]. */
    fun sessionFor(deviceName: String): NativeUsbSession = synchronized(lock) {
        sessions.getOrPut(deviceName) { NativeUsbSession(bridgeFactory(), deviceName) }
    }

    fun existing(deviceName: String): NativeUsbSession? = synchronized(lock) { sessions[deviceName] }

    /** Snapshot of all tracked sessions. */
    fun all(): List<NativeUsbSession> = synchronized(lock) { sessions.values.toList() }

    /**
     * Stops/closes/destroys the session for [deviceName] if one exists and removes it from the
     * registry. Safe to call even if no native session was ever opened for this device (returns
     * SdrResult.OK). The caller must run this, and wait for it to return, before closing the
     * Java UsbDeviceConnection that supplied the fd (see NativeUsbSession.close doc).
     */
    fun closeAndRemove(deviceName: String): SdrResult {
        val session = synchronized(lock) { sessions.remove(deviceName) } ?: return SdrResult.OK
        return session.close()
    }

    /** Closes every tracked session, e.g. on plugin/engine teardown. Errors from individual
     * sessions are swallowed (best-effort teardown mirrors UsbSdrPlugin's connection cleanup). */
    fun closeAll() {
        val names = synchronized(lock) { sessions.keys.toList() }
        for (name in names) closeAndRemove(name)
    }
}

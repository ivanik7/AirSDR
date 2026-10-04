// UsbSessionOwnership — exclusivity gate for a USB device's borrowed fd.
//
// AGENTS.md/the N1 contract require that the fd-ownership contract behind "open"/"close"
// (the ABI v3 FFI controller is tagged Owner.DART for protocol compatibility)
// and the independent ABI 2 diagnostic sdr_v2_open_usb() session
// (Owner.NATIVE, exercised by NativeUsbSession via lib/n1_qa.dart, not by the production app)
// never stream the same device at once. UsbSdrPlugin owns the single UsbDeviceConnection
// per device for the life of the process/service (see SdrApplication.getOrCreateEngine()); this
// class only arbitrates which side is currently allowed to stream from it.
//
// Deliberately free of any android.* import so it can be compiled and unit tested on a plain
// JVM without Robolectric or a device/emulator (see UsbSessionOwnershipTest.kt).
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

class UsbSessionOwnership {
    enum class Owner { DART, NATIVE }

    private val lock = Any()
    private val owners = HashMap<String, Owner>()

    /**
     * Claims [deviceName] for [owner]. Returns true if acquired, or if [owner] already held it
     * (idempotent re-open/reserve); false if the other side currently holds it — the caller
     * must surface that as a user-visible "device busy" error, not retry silently.
     */
    fun tryAcquire(deviceName: String, owner: Owner): Boolean = synchronized(lock) {
        val current = owners[deviceName]
        if (current == null || current == owner) {
            owners[deviceName] = owner
            true
        } else {
            false
        }
    }

    /**
     * Releases [deviceName] if currently held by [owner]. A release attempt by the side that
     * does not hold it is a no-op, so a stale/duplicate call from the losing side of a race
     * can't steal control away from the actual owner.
     */
    fun release(deviceName: String, owner: Owner) = synchronized(lock) {
        if (owners[deviceName] == owner) owners.remove(deviceName)
    }

    fun currentOwner(deviceName: String): Owner? = synchronized(lock) { owners[deviceName] }

    fun isHeld(deviceName: String): Boolean = synchronized(lock) { owners.containsKey(deviceName) }

    /**
     * Unconditionally releases [deviceName] regardless of owner. Used on USB detach: once the
     * device is gone, neither side may keep "holding" it. Returns the owner that was released
     * (or null if nobody held it) so the caller can decide whether to notify a native-side
     * stop/join hook before closing the Java connection.
     */
    fun forceRelease(deviceName: String): Owner? = synchronized(lock) { owners.remove(deviceName) }
}

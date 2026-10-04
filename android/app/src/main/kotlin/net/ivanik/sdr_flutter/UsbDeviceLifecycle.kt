// UsbDeviceLifecycle — single owner of per-device USB connections, Dart/native exclusivity and
// native sdrcore session ordering.
//
// Ownership rules (see docs/native-n1-android-lifecycle.md):
//   * One Java connection object [C] (a UsbDeviceConnection in production) per deviceName lives
//     in [connections]. Only this class closes it, exactly once: whoever removes it from the map
//     closes it. The original fd belongs to that connection; neither Kotlin nor Dart dup()s or
//     closes it. sdr_v2_open_usb() dup()s it internally and native closes only that duplicate.
//   * [ownership] says which side (DART xor NATIVE) may stream a device. A device held by
//     NATIVE stays held until the native session has been stopped, closed and destroyed and the
//     Java connection has been closed; only then may Dart claim it again.
//   * Every sdrcore call runs on [nativeExecutor], a serial (single-thread) executor, so
//     blocking stop/join/close never runs on the Android main thread and all commands on a
//     handle are serialized as sdrcore.h requires. Completions are posted back via
//     [mainExecutor]. Java connection close for a native-held device is always sequenced after
//     the native close on that executor.
//
// All public methods must be called on the main (platform) thread; callbacks run there too.
// No android.* imports, so the lifecycle is unit tested on a plain JVM (UsbDeviceLifecycleTest).
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

import java.util.concurrent.Executor

class UsbDeviceLifecycle<C : Any>(
    private val fdOf: (C) -> Int,
    private val closeConnection: (C) -> Unit,
    private val sessions: NativeUsbSessionRegistry,
    private val nativeExecutor: Executor,
    private val mainExecutor: Executor,
) {
    private val ownership = UsbSessionOwnership()
    private val connections = HashMap<String, C>()

    /** Devices whose native session/connection teardown is queued but not finished. While a
     * name is retiring nobody may claim it, so a reconnect cannot be handed a connection that
     * is about to be closed or have its new claim released by the old teardown. */
    private val retiring = HashMap<String, Int>() // name -> queued teardowns

    fun connection(name: String): C? = connections[name]

    fun currentOwner(name: String): UsbSessionOwnership.Owner? = ownership.currentOwner(name)

    fun isRetiring(name: String): Boolean = name in retiring

    private fun beginRetire(name: String) {
        retiring[name] = (retiring[name] ?: 0) + 1
    }

    private fun endRetire(name: String) {
        val n = (retiring[name] ?: 1) - 1
        if (n <= 0) retiring.remove(name) else retiring[name] = n
    }

    /** Claims [name] for [owner]; false means the other side holds it or a native teardown
     * for it is still in flight (report BUSY; the caller may retry later). */
    fun tryAcquire(name: String, owner: UsbSessionOwnership.Owner): Boolean =
        name !in retiring && ownership.tryAcquire(name, owner)

    /** Stores a freshly opened connection. The caller must already hold ownership. */
    fun adopt(name: String, conn: C) {
        val previous = connections[name]
        require(previous == null || previous === conn) { "second connection for $name" }
        connections[name] = conn
    }

    /**
     * Drops [owner]'s claim after a failed or denied open. If nobody holds the device any
     * more, its connection (if one was opened for this attempt) is closed and forgotten.
     */
    fun abandon(name: String, owner: UsbSessionOwnership.Owner) {
        ownership.release(name, owner)
        if (!ownership.isHeld(name)) closeIfCurrent(name, connections[name])
    }

    /** Dart "close": refused (false) while native holds the device; otherwise closes now. */
    fun dartClose(name: String): Boolean {
        if (ownership.currentOwner(name) == UsbSessionOwnership.Owner.NATIVE) return false
        ownership.release(name, UsbSessionOwnership.Owner.DART)
        closeIfCurrent(name, connections[name])
        return true
    }

    /**
     * Opens (or idempotently re-reports) the native session for [name] on the native executor.
     * The caller must hold NATIVE ownership and have adopted the connection. On failure with no
     * other live session the claim is abandoned and a connection opened for it is closed.
     */
    fun nativeOpen(name: String, source: SdrSource, done: (SdrResult) -> Unit) {
        val conn = connections[name]
        if (conn == null || ownership.currentOwner(name) != UsbSessionOwnership.Owner.NATIVE) {
            done(SdrResult.INVALID_STATE)
            return
        }
        val fd = fdOf(conn)
        nativeExecutor.execute {
            val existing = sessions.existing(name)
            val rc: SdrResult
            val active: Boolean
            if (existing != null && existing.isActive) {
                // Already open: same source is an idempotent success, another source is refused
                // without touching the running session.
                rc = if (existing.source == source) SdrResult.OK else SdrResult.INVALID_STATE
                active = true
            } else {
                val session = sessions.sessionFor(name)
                rc = session.open(fd, source)
                active = session.isActive
                if (!active) sessions.closeAndRemove(name) // forget the idle session
            }
            mainExecutor.execute {
                if (!active) abandon(name, UsbSessionOwnership.Owner.NATIVE)
                done(rc)
            }
        }
    }

    /** Runs [op] on the device's native session; [done] gets null if there is no session. */
    fun nativeCommand(name: String, op: (NativeUsbSession) -> SdrResult, done: (SdrResult?) -> Unit) {
        nativeExecutor.execute {
            val rc = sessions.existing(name)?.let(op)
            mainExecutor.execute { done(rc) }
        }
    }

    fun nativeStats(name: String, done: (SdrStatsSnapshot?) -> Unit) {
        nativeExecutor.execute {
            val snapshot = sessions.existing(name)?.stats()
            mainExecutor.execute { done(snapshot) }
        }
    }

    /**
     * Stops, closes and destroys the native session, then (if native held the device) closes
     * the Java connection and releases ownership. Dart cannot claim the device in between.
     */
    fun nativeClose(name: String, done: (SdrResult) -> Unit) {
        if (name in retiring) {
            // A close/detach for this device is already queued; it will finish the job.
            nativeExecutor.execute { mainExecutor.execute { done(SdrResult.OK) } }
            return
        }
        val heldByNative = ownership.currentOwner(name) == UsbSessionOwnership.Owner.NATIVE
        val conn = if (heldByNative) connections[name] else null
        if (heldByNative) beginRetire(name)
        nativeExecutor.execute {
            val rc = sessions.closeAndRemove(name)
            mainExecutor.execute {
                if (heldByNative) {
                    closeIfCurrent(name, conn)
                    ownership.release(name, UsbSessionOwnership.Owner.NATIVE)
                    endRetire(name)
                }
                done(rc)
            }
        }
    }

    /**
     * USB_DEVICE_DETACHED. A Dart-held device is released and its connection closed at once
     * (the existing Dart behaviour; pending ioctls fail with ENODEV). A native-held device is
     * taken out of [connections] immediately, its session is closed on the native executor and
     * only then is the Java connection closed and the claim released.
     */
    fun onDeviceDetached(name: String) {
        val conn = connections.remove(name)
        val nativeInvolved = ownership.currentOwner(name) == UsbSessionOwnership.Owner.NATIVE ||
            sessions.existing(name) != null
        if (!nativeInvolved) {
            ownership.forceRelease(name)
            conn?.let(closeConnection)
            return
        }
        // A queued nativeClose may still hold a reference to [conn]; it skips closing because
        // the connection is no longer current, so this path closes it exactly once.
        beginRetire(name)
        nativeExecutor.execute {
            sessions.closeAndRemove(name)
            mainExecutor.execute {
                conn?.let(closeConnection)
                ownership.forceRelease(name)
                endRetire(name)
            }
        }
    }

    /** Foreground-service Stop: stop every running native stream; sessions stay open. */
    fun stopAllNative(done: () -> Unit = {}) {
        nativeExecutor.execute {
            for (s in sessions.all()) if (s.phase == NativeUsbSession.Phase.RUNNING) s.stop()
            mainExecutor.execute(done)
        }
    }

    /** Foreground-service Stop: release native streams, sessions, duplicated fds and their
     * Java connections before reporting completion. Also waits for an already queued detach. */
    fun closeAllNative(done: () -> Unit = {}) {
        val names = (connections.keys.filter {
            ownership.currentOwner(it) == UsbSessionOwnership.Owner.NATIVE
        } + retiring.keys).distinct()
        if (names.isEmpty()) {
            nativeExecutor.execute { mainExecutor.execute(done) }
            return
        }
        var remaining = names.size
        for (name in names) {
            nativeClose(name) {
                if (--remaining == 0) done()
            }
        }
    }

    /**
     * Engine teardown. Dart-held connections close immediately; native sessions are closed on
     * the native executor and their connections closed right after, on that executor thread
     * (the main thread may no longer service callbacks). The caller shuts the executor down
     * afterwards; queued tasks still run.
     */
    fun shutdown() {
        val nativeConns = ArrayList<C>()
        for ((name, conn) in connections) {
            if (ownership.currentOwner(name) == UsbSessionOwnership.Owner.NATIVE) nativeConns += conn
            else closeConnection(conn)
            ownership.forceRelease(name)
        }
        connections.clear()
        retiring.clear()
        nativeExecutor.execute {
            sessions.closeAll()
            for (c in nativeConns) closeConnection(c)
        }
    }

    private fun closeIfCurrent(name: String, conn: C?) {
        if (conn != null && connections[name] === conn) {
            connections.remove(name)
            closeConnection(conn)
        }
    }
}

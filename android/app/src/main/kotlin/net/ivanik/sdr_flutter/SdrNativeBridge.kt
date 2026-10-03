// SdrNativeBridge — abstraction over the JNI entry points for native/include/sdrcore.h ABI 2.
//
// Kept in its own file with zero android.* imports so NativeUsbSession/NativeUsbSessionRegistry
// and their unit tests (FakeSdrNativeBridge) compile and run on a plain JVM. The real
// implementation backed by System.loadLibrary()/external fun JNI declarations is
// JniSdrNativeBridge.kt (android.util.Log for diagnostics), constructed only by UsbSdrPlugin.kt.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

/** Bridge abstraction so NativeUsbSession can be unit tested without a real native library. */
interface SdrNativeBridge {
    fun version(): Int
    fun create(): Long
    fun destroy(handle: Long)
    fun openUsb(handle: Long, fd: Int, source: Int): Int
    fun configure(handle: Long, frequencyHz: Long, samplesPerSecond: Int, gainTenthsDb: Int): Int
    fun start(handle: Long): Int
    fun stop(handle: Long): Int
    fun close(handle: Long): Int
    fun stats(handle: Long): LongArray?
}

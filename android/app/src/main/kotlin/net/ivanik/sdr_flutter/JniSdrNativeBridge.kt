// JniSdrNativeBridge — the real JNI control surface for native/include/sdrcore.h ABI 2.
//
// This is deliberately a real `external fun` JNI declaration set, not a documentation stub: it
// is wired into NativeUsbSession/NativeUsbSessionRegistry (via UsbSdrPlugin.kt) and loads the
// same "sdrcore" native library that android/app/build.gradle.kts already builds from
// native/CMakeLists.txt (externalNativeBuild). It stays usable even when the native side has
// not yet exported the matching JNI entry points: System.loadLibrary()/UnsatisfiedLinkError on
// an individual call are caught and mapped to SdrResult.BRIDGE_UNAVAILABLE instead of crashing
// the app or silently pretending the call succeeded.
//
// Required native-side JNI exports (native/ owns adding these; out of scope for this file):
//   JNIEXPORT jint      JNICALL Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeVersion(JNIEnv*, jobject)
//   JNIEXPORT jlong     JNICALL Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeCreate(JNIEnv*, jobject)
//   JNIEXPORT void      JNICALL Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeDestroy(JNIEnv*, jobject, jlong)
//   JNIEXPORT jint      JNICALL Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeOpenUsb(JNIEnv*, jobject, jlong, jint, jint)
//   JNIEXPORT jint      JNICALL Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeConfigure(JNIEnv*, jobject, jlong, jlong, jint, jint)
//   JNIEXPORT jint      JNICALL Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeStart(JNIEnv*, jobject, jlong)
//   JNIEXPORT jint      JNICALL Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeStop(JNIEnv*, jobject, jlong)
//   JNIEXPORT jint      JNICALL Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeClose(JNIEnv*, jobject, jlong)
//   JNIEXPORT jlongArray JNICALL Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeStats(JNIEnv*, jobject, jlong)
// nativeStats must pack SdrStats as [state, source, last_error, sample_rate, frequency_hz,
// gain_tenths_db, input_samples, processed_samples, dropped_samples, checksum] after setting
// `size`/`revision` itself (sdrcore.h requires the caller to set them); returns null on any
// non-SDR_OK sdr_v2_stats() result so the Kotlin side never fabricates a zeroed snapshot.
// nativeOpenUsb/nativeConfigure/nativeStart/nativeStop/nativeClose return the raw `enum
// SdrResult` code; nativeCreate returns 0 on sdr_create() failure (NULL), matching the header.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

import android.util.Log

/**
 * Real JNI-backed [SdrNativeBridge]. Safe to construct even when libsdrcore.so is missing or
 * does not export the JNI symbols yet (current native/ state, see docs/native-n1-status.md):
 * every call degrades to [SdrResult.BRIDGE_UNAVAILABLE] / null instead of throwing.
 */
class JniSdrNativeBridge(libraryName: String = "sdrcore") : SdrNativeBridge {
    companion object {
        private const val TAG = "SdrNativeBridge"
    }

    private val loaded: Boolean = try {
        System.loadLibrary(libraryName)
        true
    } catch (e: UnsatisfiedLinkError) {
        Log.w(TAG, "lib$libraryName.so unavailable; native USB control disabled", e)
        false
    } catch (e: SecurityException) {
        Log.w(TAG, "lib$libraryName.so blocked by SecurityManager", e)
        false
    }

    private inline fun <T> guarded(default: T, call: () -> T): T {
        if (!loaded) return default
        return try {
            call()
        } catch (e: UnsatisfiedLinkError) {
            // Expected until native/ exports the JNI symbols documented above.
            Log.w(TAG, "native JNI symbol not exported by libsdrcore.so yet", e)
            default
        }
    }

    override fun version(): Int = guarded(-1) { nativeVersion() }

    override fun create(): Long = guarded(0L) { nativeCreate() }

    override fun destroy(handle: Long) {
        guarded(Unit) { nativeDestroy(handle) }
    }

    override fun openUsb(handle: Long, fd: Int, source: Int): Int =
        guarded(SdrResult.BRIDGE_UNAVAILABLE.code) { nativeOpenUsb(handle, fd, source) }

    override fun configure(handle: Long, frequencyHz: Long, samplesPerSecond: Int, gainTenthsDb: Int): Int =
        guarded(SdrResult.BRIDGE_UNAVAILABLE.code) {
            nativeConfigure(handle, frequencyHz, samplesPerSecond, gainTenthsDb)
        }

    override fun start(handle: Long): Int = guarded(SdrResult.BRIDGE_UNAVAILABLE.code) { nativeStart(handle) }

    override fun stop(handle: Long): Int = guarded(SdrResult.BRIDGE_UNAVAILABLE.code) { nativeStop(handle) }

    override fun close(handle: Long): Int = guarded(SdrResult.BRIDGE_UNAVAILABLE.code) { nativeClose(handle) }

    override fun stats(handle: Long): LongArray? = guarded(null) { nativeStats(handle) }

    private external fun nativeVersion(): Int
    private external fun nativeCreate(): Long
    private external fun nativeDestroy(handle: Long)
    private external fun nativeOpenUsb(handle: Long, fd: Int, source: Int): Int
    private external fun nativeConfigure(
        handle: Long,
        frequencyHz: Long,
        samplesPerSecond: Int,
        gainTenthsDb: Int,
    ): Int
    private external fun nativeStart(handle: Long): Int
    private external fun nativeStop(handle: Long): Int
    private external fun nativeClose(handle: Long): Int
    private external fun nativeStats(handle: Long): LongArray?
}

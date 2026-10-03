// SdrResult — Kotlin mirror of the native `enum SdrResult` in native/include/sdrcore.h.
// Keep values in sync with that header; this is a value class, not a dependency on JNI.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

enum class SdrResult(val code: Int) {
    OK(0),
    INVALID_ARGUMENT(-1),
    INVALID_STATE(-2),
    UNSUPPORTED(-3),
    IO_ERROR(-4),
    DEVICE_GONE(-5),
    INTERNAL_ERROR(-6),
    /** The JNI bridge call itself could not reach native code (library not loaded, link error,
     * or no handle). Not a native ABI code: callers must not forward this to sdr_v2_stats() etc. */
    BRIDGE_UNAVAILABLE(-1000);

    companion object {
        fun fromCode(code: Int): SdrResult = entries.firstOrNull { it.code == code } ?: INTERNAL_ERROR
    }
}

/** Mirrors `enum SdrSource` in sdrcore.h. */
enum class SdrSource(val code: Int) {
    NONE(0), FILE(1), SYNTHETIC(2), RTLSDR(3), HACKRF(4);
}

/** Mirrors `enum SdrState` in sdrcore.h. */
enum class SdrState(val code: Int) {
    IDLE(0), OPEN(1), RUNNING(2), ERROR(3), UNKNOWN(-1);

    companion object {
        fun fromCode(code: Int): SdrState = entries.firstOrNull { it.code == code } ?: UNKNOWN
    }
}

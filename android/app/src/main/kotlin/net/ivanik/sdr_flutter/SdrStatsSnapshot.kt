// SdrStatsSnapshot — JNI-friendly projection of `struct SdrStats` (native/include/sdrcore.h).
//
// JNI cannot marshal a C struct by value, so the bridge packs SdrStats into a LongArray in a
// fixed field order (see SdrNativeBridge.nativeStats doc) and this class parses that array.
// `size`/`revision` are validated and stripped by the native wrapper before it crosses JNI
// (sdrcore.h requires the caller to set them before the call); `reserved` carries no data.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

data class SdrStatsSnapshot(
    val state: SdrState,
    val source: SdrSource,
    val lastError: SdrResult,
    val sampleRate: Long,
    val frequencyHz: Long,
    val gainTenthsDb: Long,
    val inputSamples: Long,
    val processedSamples: Long,
    val droppedSamples: Long,
    val checksum: Long,
) {
    companion object {
        /** Field count and order produced by the native JNI wrapper's `nativeStats()`:
         * [state, source, lastError, sampleRate, frequencyHz, gainTenthsDb, inputSamples,
         *  processedSamples, droppedSamples, checksum]. */
        const val FIELD_COUNT = 10

        /**
         * Parses the packed stats array. Returns null if [raw] is null (native reported
         * SDR_INVALID_ARGUMENT / no handle) or has the wrong length (a bridge/ABI mismatch that
         * must not be silently papered over with zeroed fields).
         */
        fun parse(raw: LongArray?): SdrStatsSnapshot? {
            if (raw == null || raw.size != FIELD_COUNT) return null
            return SdrStatsSnapshot(
                state = SdrState.fromCode(raw[0].toInt()),
                source = SdrSource.entries.firstOrNull { it.code == raw[1].toInt() } ?: SdrSource.NONE,
                lastError = SdrResult.fromCode(raw[2].toInt()),
                sampleRate = raw[3],
                frequencyHz = raw[4],
                gainTenthsDb = raw[5],
                inputSamples = raw[6],
                processedSamples = raw[7],
                droppedSamples = raw[8],
                checksum = raw[9],
            )
        }
    }
}

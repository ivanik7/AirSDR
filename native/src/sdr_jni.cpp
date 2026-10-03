// SPDX-License-Identifier: GPL-3.0-or-later
// Android-only control bridge. Raw IQ stays inside sdrcore; JNI carries commands
// and a fixed-size statistics snapshot, never sample buffers.
#include "sdrcore.h"

#include <jni.h>
#include <cstdint>

namespace {
SdrHandle* from_java(jlong handle) {
  return reinterpret_cast<SdrHandle*>(static_cast<uintptr_t>(handle));
}
}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeVersion(JNIEnv*, jobject) {
  return static_cast<jint>(sdr_version());
}

extern "C" JNIEXPORT jlong JNICALL
Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeCreate(JNIEnv*, jobject) {
  return static_cast<jlong>(reinterpret_cast<uintptr_t>(sdr_create()));
}

extern "C" JNIEXPORT void JNICALL
Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeDestroy(JNIEnv*, jobject, jlong handle) {
  sdr_destroy(from_java(handle));
}

extern "C" JNIEXPORT jint JNICALL
Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeOpenUsb(
    JNIEnv*, jobject, jlong handle, jint fd, jint source) {
  return sdr_v2_open_usb(from_java(handle), fd, static_cast<uint32_t>(source));
}

extern "C" JNIEXPORT jint JNICALL
Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeConfigure(
    JNIEnv*, jobject, jlong handle, jlong frequency, jint rate, jint gain) {
  if (frequency < 0 || rate < 0) return SDR_INVALID_ARGUMENT;
  return sdr_v2_configure(from_java(handle), static_cast<uint64_t>(frequency),
                          static_cast<uint32_t>(rate), gain);
}

extern "C" JNIEXPORT jint JNICALL
Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeStart(JNIEnv*, jobject, jlong handle) {
  return sdr_v2_start(from_java(handle));
}

extern "C" JNIEXPORT jint JNICALL
Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeStop(JNIEnv*, jobject, jlong handle) {
  return sdr_v2_stop(from_java(handle));
}

extern "C" JNIEXPORT jint JNICALL
Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeClose(JNIEnv*, jobject, jlong handle) {
  return sdr_v2_close(from_java(handle));
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_nativeStats(
    JNIEnv* env, jobject, jlong handle) {
  SdrStats stats{};
  stats.size = sizeof(stats);
  stats.revision = 2;
  if (sdr_v2_stats(from_java(handle), &stats) != SDR_OK) return nullptr;
  const jlong values[] = {
      static_cast<jlong>(stats.state), static_cast<jlong>(stats.source),
      static_cast<jlong>(stats.last_error), static_cast<jlong>(stats.sample_rate),
      static_cast<jlong>(stats.frequency_hz), static_cast<jlong>(stats.gain_tenths_db),
      static_cast<jlong>(stats.input_samples), static_cast<jlong>(stats.processed_samples),
      static_cast<jlong>(stats.dropped_samples), static_cast<jlong>(stats.checksum)};
  jlongArray array = env->NewLongArray(10);
  if (!array) return nullptr;
  env->SetLongArrayRegion(array, 0, 10, values);
  return array;
}

// SPDX-License-Identifier: GPL-3.0-or-later
// SAF provider for the recording writer. The Java plugin holds only an
// application Context; no Activity or Dart isolate is touched by this callback.
#include "sdrcore_record_v1.h"

#ifdef __ANDROID__
#include <dlfcn.h>
#include <jni.h>
#include <codecvt>
#include <cstring>
#include <locale>
#include <memory>
#include <string>

namespace {
struct Bridge {
  JavaVM* vm;
  jobject plugin; // Global reference, released after replacement quiesces.
  jmethodID create;
};
Bridge* current = nullptr;

jstring to_java(JNIEnv* env, const char* text, size_t length) {
  try {
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
    const auto utf16 = converter.from_bytes(text, text + length);
    return env->NewString(reinterpret_cast<const jchar*>(utf16.data()),
                          static_cast<jsize>(utf16.length()));
  } catch (const std::range_error&) {
    return nullptr;
  }
}

int32_t create_file(void* ctx, const char* folder, uint32_t folder_bytes,
                    const char* name, uint32_t name_bytes,
                    const char* mime, int32_t* out_fd) {
  if (!ctx || !out_fd || !folder || !name || !mime) return SDR_INVALID_ARGUMENT;
  *out_fd = -1;
  auto* bridge = static_cast<Bridge*>(ctx);
  JNIEnv* env = nullptr;
  bool attached = false;
  if (bridge->vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    if (bridge->vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return SDR_IO_ERROR;
    attached = true;
  }
  const jstring path = to_java(env, folder, folder_bytes);
  const jstring file = to_java(env, name, name_bytes);
  const jstring type = to_java(env, mime, strlen(mime));
  int32_t result = SDR_IO_ERROR;
  if (path && file && type && !env->ExceptionCheck()) {
    const jint fd = env->CallIntMethod(bridge->plugin, bridge->create, path, file, type);
    if (!env->ExceptionCheck()) {
      if (fd >= 0) { *out_fd = fd; result = SDR_OK; }
      else result = fd;
    }
  }
  if (env->ExceptionCheck()) env->ExceptionClear();
  if (path) env->DeleteLocalRef(path);
  if (file) env->DeleteLocalRef(file);
  if (type) env->DeleteLocalRef(type);
  if (attached) bridge->vm->DetachCurrentThread();
  return result;
}
} // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_net_ivanik_sdr_1flutter_RecordFolderPlugin_registerProvider(JNIEnv* env, jobject plugin) {
  // A contract-only build does not export recording. Keep the picker usable,
  // but do not claim native support until the recorder is linked.
  void* lib = dlopen("libsdrcore.so", RTLD_NOW);
  if (!lib) return JNI_FALSE;
  using SetProvider = int32_t (*)(const char*, uint32_t, SdrRecordCreateFile, void*);
  auto set = reinterpret_cast<SetProvider>(dlsym(lib, "sdr_record_set_provider"));
  if (!set) { dlclose(lib); return JNI_FALSE; }
  auto next = std::make_unique<Bridge>();
  if (env->GetJavaVM(&next->vm) != JNI_OK) { dlclose(lib); return JNI_FALSE; }
  next->plugin = env->NewGlobalRef(plugin);
  if (!next->plugin) { dlclose(lib); return JNI_FALSE; }
  jclass cls = env->GetObjectClass(plugin);
  next->create = env->GetMethodID(cls, "createFile",
                                   "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)I");
  env->DeleteLocalRef(cls);
  if (!next->create || env->ExceptionCheck()) {
    env->ExceptionClear();
    env->DeleteGlobalRef(next->plugin);
    dlclose(lib);
    return JNI_FALSE;
  }
  const int32_t result = set("content", 7, create_file, next.get());
  if (result == SDR_OK) {
    if (current) {
      env->DeleteGlobalRef(current->plugin);
      delete current;
    }
    current = next.release();
  } else env->DeleteGlobalRef(next->plugin);
  dlclose(lib);
  return result == SDR_OK ? JNI_TRUE : JNI_FALSE;
}
#endif

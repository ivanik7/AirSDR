// SPDX-License-Identifier: LGPL-2.1-or-later
// Hand-written libusb build config for the Linux/Android POSIX backend used by
// this project (replaces autotools/meson configure output). libusb itself is
// vendored unmodified under third_party/libusb/libusb; this file and the
// surrounding CMakeLists.txt are project glue, not upstream libusb sources.
// Mirrors the subset of defines libusb's upstream android/jni/libusb.mk and
// configure.ac enable for a Linux-kernel/glibc-or-bionic POSIX target.
#ifndef SDRCORE_THIRD_PARTY_LIBUSB_CONFIG_H
#define SDRCORE_THIRD_PARTY_LIBUSB_CONFIG_H

// Hermes note: upstream libusb defines DEFAULT_VISIBILITY as an explicit
// __attribute__((visibility("default"))) on every public API_EXPORTED
// symbol, for building libusb as its own standalone shared library. Here
// libusb is a compile-time-only implementation detail linked statically into
// libsdrcore.so (see native/CMakeLists.txt's CXX_VISIBILITY_PRESET hidden);
// leaving DEFAULT_VISIBILITY empty lets -fvisibility=hidden (set on the
// sdrcore_libusb CMake target) actually hide these symbols from the ABI 2
// surface instead of re-exporting all of libusb from libsdrcore.so.
#define DEFAULT_VISIBILITY
#define ENABLE_LOGGING 1
#define HAVE_ASM_TYPES_H 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_NFDS_T 1
#define HAVE_PIPE2 1
#define HAVE_SYS_TIME_H 1
#define HAVE_STRUCT_TIMESPEC 1
// eventfd/timerfd/pthread_condattr_setclock are available on glibc (Linux
// host, our CMake-only CI target) and on Android/bionic since API 21, below
// the project's minSdk 24: safe to enable unconditionally for this target set.
#define HAVE_EVENTFD 1
#define HAVE_TIMERFD 1
#define HAVE_DECL_EFD_CLOEXEC 1
#define HAVE_DECL_EFD_NONBLOCK 1
#define HAVE_DECL_TFD_CLOEXEC 1
#define HAVE_DECL_TFD_NONBLOCK 1
#define HAVE_PTHREAD_CONDATTR_SETCLOCK 1
#define PLATFORM_POSIX 1
#define PRINTF_FORMAT(a, b) __attribute__((__format__(__printf__, a, b)))
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#endif  // SDRCORE_THIRD_PARTY_LIBUSB_CONFIG_H

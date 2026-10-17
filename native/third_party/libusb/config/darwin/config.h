// SPDX-License-Identifier: LGPL-2.1-or-later
// Hand-written libusb build config for the macOS (Darwin/IOKit) backend used
// by this project's desktop build: libusb/os/darwin_usb.c + events_posix.c +
// threads_posix.c. Based on upstream libusb v1.0.30 Xcode/config.h; project
// glue, not an upstream libusb source. libusb itself stays unmodified.
#ifndef SDRCORE_THIRD_PARTY_LIBUSB_CONFIG_H
#define SDRCORE_THIRD_PARTY_LIBUSB_CONFIG_H

#include <AvailabilityMacros.h>

// Empty, unlike upstream: libusb is linked statically into libsdrcore and
// compiled with -fvisibility=hidden, so none of its API is re-exported (see
// the Linux config.h for the full rationale).
#define DEFAULT_VISIBILITY
#define ENABLE_LOGGING 1
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060
#define HAVE_PTHREAD_THREADID_NP 1
#endif
#define HAVE_CLOCK_GETTIME 1
#define HAVE_NFDS_T 1
#define HAVE_SYS_TIME_H 1
#define HAVE_STRUCT_TIMESPEC 1
#define PLATFORM_POSIX 1
#define PRINTF_FORMAT(a, b) __attribute__((__format__(__printf__, a, b)))
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#endif  // SDRCORE_THIRD_PARTY_LIBUSB_CONFIG_H

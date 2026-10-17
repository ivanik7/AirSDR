// SPDX-License-Identifier: LGPL-2.1-or-later
// Hand-written libusb build config for the Windows backend used by this
// project's desktop build (MinGW-w64 clang / llvm-mingw, UCRT):
// windows_common.c + windows_winusb.c + windows_usbdk.c + events_windows.c +
// threads_windows.c. Based on upstream libusb v1.0.30 msvc/config.h minus the
// MSVC-only pragmas; project glue, not an upstream libusb source.
//
// WinUSB, SetupAPI, Cfgmgr32, AdvAPI32 and UsbDk are loaded at run time by
// libusb (DLL_GET_HANDLE / LoadLibrary), so nothing extra is linked.
// LIBUSB_WINDOWS_HOTPLUG stays undefined (upstream default): enumeration is
// rescanned on every libusb_get_device_list call, which is all the host
// layer needs.
#ifndef SDRCORE_THIRD_PARTY_LIBUSB_CONFIG_H
#define SDRCORE_THIRD_PARTY_LIBUSB_CONFIG_H

// Empty: libusb is linked statically into sdrcore.dll and must not be
// exported from it (only the dllexport'ed sdr_* API is).
#define DEFAULT_VISIBILITY
#define ENABLE_LOGGING 1
#define PLATFORM_WINDOWS 1
#define PRINTF_FORMAT(a, b) __attribute__((__format__(__printf__, a, b)))
#define HAVE_STRUCT_TIMESPEC 1

#endif  // SDRCORE_THIRD_PARTY_LIBUSB_CONFIG_H

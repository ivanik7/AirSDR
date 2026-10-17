# Desktop builds of the native core

`native/` builds `libsdrcore` for four targets from the same vendored sources.
No prebuilt SDR libraries are used.

| Target  | Toolchain                          | Output              | libusb backend                |
|---------|------------------------------------|---------------------|-------------------------------|
| Android | NDK 28 clang (Gradle)              | `libsdrcore.so`     | linux_usbfs (fd handoff only) |
| Linux   | GCC or Clang                       | `libsdrcore.so`     | linux_usbfs + netlink         |
| macOS   | Apple Clang                        | `libsdrcore.dylib`  | darwin_usb (IOKit)            |
| Windows | llvm-mingw Clang, x86_64 UCRT      | `sdrcore.dll`       | WinUSB / UsbDk                |

The Flutter runners for all desktops are in `linux/`, `macos/` and
`windows/`. CI builds and packages each of them (docs/ci.md). Linux builds
`libsdrcore.so` as part of the runner's CMake project. macOS and Windows
build the core separately and copy it into the app (`Contents/Frameworks`,
and beside the runner via `SDRCORE_DLL`). The macOS and Windows apps have
not been run on real hardware.

## Commands

Linux (tests included when `native/` is the top-level project):

    cmake -S native -B build-linux -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build build-linux && ctest --test-dir build-linux

macOS (unverified: no macOS SDK on the dev host):

    cmake -S native -B build-mac -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
    cmake --build build-mac --target sdrcore

Windows, cross from Linux or native, with llvm-mingw
(https://github.com/mstorsjo/llvm-mingw/releases, the `ucrt` flavour):

    cmake -S native -B build-win -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE="$PWD/native/cmake/llvm-mingw-x86_64.cmake" \
      -DLLVM_MINGW_ROOT=/path/to/llvm-mingw-<ver>-ucrt-<host> \
      -DCMAKE_BUILD_TYPE=Release
    cmake --build build-win --target sdrcore

## Why llvm-mingw and not MSVC

liquid-dsp (the RDS demodulator) uses C99 `_Complex` arithmetic and
`<complex.h>`. Neither MSVC nor clang-cl with the UCRT headers supports them,
and the sources also use GNU flags. `native/CMakeLists.txt` therefore stops
with a clear error under MSVC. The Flutter Windows runner itself stays MSVC.
It loads `sdrcore.dll` through FFI only: the ABI is plain C, and no CRT
objects cross it.

`sdrcore.dll` is linked with `-static`, so libc++, libunwind and winpthreads
are inside it. Its import table lists only `KERNEL32.dll` and the
`api-ms-win-crt-*` UCRT forwarders, which are present on Windows 10 and
later. WinUSB, SetupAPI, Cfgmgr32 and UsbDk are loaded at run time by libusb.
WASAPI is loaded at run time by miniaudio.

## Symbol export policy

Only the `sdr_*` C API is exported, on every target:

- Linux/Android: `-fvisibility=hidden`, `--exclude-libs,ALL` and
  `--gc-sections`.
- macOS: `-dead_strip` and `cmake/sdrcore-macos.exp` (an exported-symbols list
  of the `sdr_*` families). The install name is `@rpath/libsdrcore.dylib`; the
  app bundles the dylib in `Contents/Frameworks`.
- Windows: only the `__declspec(dllexport)` `SDRCORE_API` symbols are
  exported, plus `--exclude-all-symbols` and `--gc-sections`. The vendored
  drivers are compiled with `rtlsdr_STATIC` / `HACKRF_STATIC`, so their own
  `dllexport` markers do not leak into the export table.

## Platform notes

- USB open: Linux opens `/dev/bus/usb/BBB/DDD` and hands the fd to the driver.
  macOS and Windows open by bus/address with `libusb_open()`
  (`sdr_host_open_usb_direct`, see `native/include/sdrcore_host.h`). On
  Windows the RTL-SDR/HackRF must be bound to WinUSB (Zadig). Otherwise the
  open fails with `SDR_HOST_DRIVER_UNSUPPORTED`.
- Audio: ALSA on Linux, AAudio on Android, miniaudio (CoreAudio/WASAPI) on
  macOS/Windows; see `native/src/audio/MINIAUDIO.md`.
- rtl_433: ELF `--gc-sections` drops the CLI-only paths of `r_api.c`, but
  ld64 and lld-COFF resolve symbols before dead stripping. On macOS/Windows
  `src/decoder/rtl433_cli_stubs.c` defines those unreachable symbols as
  aborting placeholders, and upstream `rfraw.c` is compiled.
- redsea: the built-in UCS-2/Latin-1 converter in `ext/iconvpp/iconv.hpp` is
  used on Android, Windows and macOS. Desktop Linux uses glibc iconv.
- Native tests: Linux runs the full ctest suite. Tests that rely on POSIX fds,
  pipes or `-Wl,--wrap` are Linux-only. macOS and Windows configure a portable
  CTest subset (ABI, decoder ABI, direct USB open, PCM and sink tests); the
  Windows cross build compiles these executables but cannot run them here (no
  Windows host or Wine).
- Dart loads `libsdrcore.dylib` from `<App>.app/Contents/Frameworks` on macOS,
  `sdrcore.dll` beside the Windows runner, and `lib/libsdrcore.so` on Linux.
  `SDRCORE_HOST_LIBRARY` overrides the bundled library on desktops. All
  desktops use the host USB device source; macOS/Windows select the direct
  libusb entry point. `SDR_AUDIO_SINK` overrides the OS default (`null` on
  Linux, `miniaudio` on macOS/Windows). Native radio settings are stored in
  the platform's application-support directory; favorites stay in the
  platform shared-preferences backend. Missing native libraries surface as
  an error rather than silently falling back to a mock receiver.

## Local patches added for portability

- `patches/rtlsdr-open-bus-address.patch`: additive `rtlsdr_open_bus_address()`.
- `patches/hackrf-static-windows.patch`: a `HACKRF_STATIC` guard around
  hackrf.h's `dllexport`/`dllimport`.
- `ext/iconvpp/iconv.hpp` (redsea): built-in converter on Windows/macOS
  (RDS-PROVENANCE.md).

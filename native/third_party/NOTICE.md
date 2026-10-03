# Third-party SDR USB driver sources — provenance & licenses

All code in this directory is built from source by `native/third_party/CMakeLists.txt`.
No prebuilt binaries are vendored or linked. Nothing here is part of the ABI 2
contract in `native/include/sdrcore.h`; see `native/src/usb_adapter.h` for the
internal interface that bridges these drivers into the engine.

## libusb — `libusb/`

- Upstream: https://github.com/libusb/libusb
- Version: **v1.0.30** release tarball
  `libusb-1.0.30.tar.bz2`, sha256 `fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf`
- License: **LGPL-2.1-or-later** (`libusb/COPYING`)
- Vendored: the full upstream `libusb/` source directory verbatim (all
  platform backends included, not just Linux/POSIX — see "Build selection"
  below for why the full tree is kept instead of deleted down to only the
  files we compile).
- Added by us (not upstream libusb): `config.h` — a hand-written
  `configure`-equivalent header providing the `HAVE_*`/`PLATFORM_POSIX`
  defines libusb needs for a Linux-kernel (glibc or Android bionic) build,
  modeled on libusb's own `android/config.h` reference file and
  `configure.ac`. See the comments in that file.
- Not patched: used as-is. `libusb_wrap_sys_device()` /
  `LIBUSB_OPTION_NO_DEVICE_DISCOVERY` (the primitives both driver's
  open-by-fd patches build on) have shipped in upstream libusb since 1.0.23 —
  v1.0.30 already has them, no patch needed.
- Build selection (`third_party/CMakeLists.txt`): only
  `core.c descriptor.c hotplug.c io.c sync.c strerror.c` plus
  `os/linux_usbfs.c os/linux_netlink.c os/events_posix.c os/threads_posix.c`
  are compiled (the Linux/POSIX backend used by both the host build and
  Android). Darwin/Windows/Haiku/Solaris/emscripten backend files remain
  present in the vendored tree (full upstream library, for provenance/audit)
  but are never added to a CMake target and never compiled.

## librtlsdr — `rtl-sdr/`

- Upstream: https://github.com/osmocom/rtl-sdr, pinned at the project's
  already-checked-out `~/prj/ref/rtl-sdr` revision
  **797f8143266d983c56d8f35d2d442527529dd8a5** (2026-08-12).
- License: **GPL-2.0-or-later** (`rtl-sdr/COPYING`)
- Vendored: library-only sources (CLI tools `rtl_sdr.c`/`rtl_fm.c`/etc. are
  excluded) — `librtlsdr.c tuner_e4k.c tuner_fc0012.c tuner_fc0013.c
  tuner_fc2580.c tuner_r82xx.c` + headers.
- **Patch applied**: "Android open-by-fd" support, cherry-picked from
  AlexandreRouma/rtl-sdr (https://github.com/AlexandreRouma/rtl-sdr):
  - `40a1598` "Added android support" — adds `rtlsdr_open_sys_dev()`, which
    calls `libusb_wrap_sys_device()` + `LIBUSB_OPTION_NO_DEVICE_DISCOVERY`
    instead of `libusb_open()`/enumeration, required because enumerating all
    USB devices is restricted on unrooted Android — ported with `git apply`
    cleanly onto the pinned 797f814 base.
  - `7f68c34` "fixed typo" and `ddd6811` "fix missing return statement" —
    two small upstream bugfixes to that same patch (uninitialized-variable
    use, missing early return), applied by hand since they post-date
    `40a1598` and are not optional correctness fixes.
  - Net new public API: `int rtlsdr_open_sys_dev(rtlsdr_dev_t **dev, int fd)`
    declared in `include/rtl-sdr.h`.
  - Our adapter (`native/src/usb_rtlsdr_adapter.cpp`) `dup()`s the fd before
    calling this, because `libusb_wrap_sys_device()` stores the fd verbatim
    and neither duplicates nor closes it — see that file's ownership comment.

## libhackrf — `hackrf/libhackrf/`

- Upstream: https://github.com/greatscottgadgets/hackrf, pinned at the
  project's already-checked-out `~/prj/ref/hackrf` revision
  **7f96cc8e3fa625c4263a71ba8dd44d1f6110e4fa** (2026-09-17), `host/libhackrf/`
  subtree only.
- License: **BSD-3-Clause** (per-file header in `hackrf.c`/`hackrf.h`)
- Vendored: `hackrf.c`, `hackrf.h` only (the full host CLI tools are not
  needed). `CMakeLists.txt` from upstream is not vendored; our own build
  rules for this library live in `native/third_party/CMakeLists.txt`.
- **Patch applied**: "Android open-by-fd" support, cherry-picked from
  AlexandreRouma/hackrf (https://github.com/AlexandreRouma/hackrf):
  - `703160f5` "added android support" plus follow-up `a5534372`/`b1275e9c`
    "Renamed option in library code" (combined diff
    `git diff 703160f5~1 b1275e9c -- host/libhackrf/`).
  - The 2022-era fork base is too divergent from the pinned 2026 upstream
    for a clean `git apply`: `hackrf.c`'s hunk applied cleanly with
    `git apply --reject`; the small `hackrf.h` enum/declaration addition and
    the `CMakeLists.txt` option (not used — we have our own CMake file) were
    re-applied by hand to match the modern Doxygen-commented header layout.
  - Net new public API: `HACKRF_ERROR_UNSUPPORTED = -12` enum value, and
    `int hackrf_open_by_fd(int fd, hackrf_device** device)` declared in
    `hackrf.h`, implemented via `libusb_wrap_sys_device()` +
    `LIBUSB_OPTION_NO_DEVICE_DISCOVERY` the same way as rtlsdr's variant.
  - `DISABLE_USB_DEVICE_DISCOVERY` compile definition, set only for
    `ANDROID` builds in `third_party/CMakeLists.txt`, skips the
    `libusb_init()`-time device enumeration that fails on unrooted Android.
  - Our adapter (`native/src/usb_hackrf_adapter.cpp`) `dup()`s the fd before
    calling this, for the same reason as the rtlsdr adapter.

## License compatibility

GPL-2.0-or-later (rtl-sdr) + LGPL-2.1-or-later (libusb) + BSD-3-Clause
(hackrf), all statically linked into `libsdrcore.so` which is itself part of
a GPL-3.0-or-later project (`docs/native-n1-status.md`) — compatible: the
combined work may be distributed under GPL-3.0-or-later, the strictest
applicable term among the four.

## Reproducing the pin / patch provenance

```
# rtl-sdr base (already pinned in the repo's ~/prj/ref checkout):
git -C ~/prj/ref/rtl-sdr log -1 --format='%H %ci'
# -> 797f8143266d983c56d8f35d2d442527529dd8a5 2026-08-12 00:11:56 +0200

# hackrf base (already pinned in the repo's ~/prj/ref checkout):
git -C ~/prj/ref/hackrf log -1 --format='%H %ci'
# -> 7f96cc8e3fa625c4263a71ba8dd44d1f6110e4fa 2026-09-17 11:09:19 -0400

# open-by-fd source commits (for reference only; not vendored wholesale):
git ls-remote https://github.com/AlexandreRouma/rtl-sdr.git  # HEAD ddd6811b71359c299cf31b4e3e75fbb1ed5c964d
git ls-remote https://github.com/AlexandreRouma/hackrf.git   # HEAD b1275e9c240b64cd7a8fd9bac70d77a8dd957616
```

The exact unified diffs applied are kept in `patches/` for audit/reproduction.

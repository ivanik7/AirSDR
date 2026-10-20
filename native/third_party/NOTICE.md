# Third-party sources — provenance & licenses

Vendored dependencies are built from source through `native/third_party/CMakeLists.txt`
and the included `third_party/*.cmake` modules. No prebuilt binaries are
vendored or linked. USB drivers are not part of the ABI 2 contract in
`native/include/sdrcore.h`; see `native/src/usb_adapter.h` for their internal
engine interface.

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
  already-checked-out `<refs>/rtl-sdr` revision
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
  - Local failure-path correction in `rtlsdr_create_device()`: if
    `libusb_init()` fails, free the allocated device rather than the
    output-pointer address and clear that output pointer. Preserve the
    libusb error code. This is separate from the archived open-by-fd patch.
  - Net new public API: `int rtlsdr_open_sys_dev(rtlsdr_dev_t **dev, int fd)`
    declared in `include/rtl-sdr.h`.
  - Our adapter (`native/src/usb_rtlsdr_adapter.cpp`) `dup()`s the fd before
    calling this, because `libusb_wrap_sys_device()` stores the fd verbatim
    and neither duplicates nor closes it — see that file's ownership comment.
- **Patch applied (local, additive)**: `patches/rtlsdr-open-bus-address.patch`
  adds `int rtlsdr_open_bus_address(rtlsdr_dev_t **dev, uint8_t bus,
  uint8_t address)` for the desktop direct open path
  (`sdr_host_open_usb_direct`; the only path on macOS and Windows, which have
  no usbfs file descriptors). It is `rtlsdr_open()` with the device matched by
  libusb bus number / device address instead of by index, and returns the raw
  libusb error (`LIBUSB_ERROR_NOT_FOUND` when no supported device is there)
  so the host layer can report access denied / busy / missing WinUSB.
  Existing functions are unchanged. Not used on Android.

## libhackrf — `hackrf/libhackrf/`

- Upstream: https://github.com/greatscottgadgets/hackrf, pinned at the
  project's already-checked-out `<refs>/hackrf` revision
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
- **Patch applied (local)**: `patches/hackrf-static-windows.patch` guards
  hackrf.h's Windows `__declspec(dllexport/dllimport)` with
  `!defined(HACKRF_STATIC)`. The build sets `HACKRF_STATIC`, so the
  statically linked libhackrf API is not exported from `sdrcore.dll`. There
  is no behaviour change on other targets.

## License compatibility

GPL-2.0-or-later (rtl-sdr) + LGPL-2.1-or-later (libusb) + BSD-3-Clause
(hackrf), all statically linked into `libsdrcore.so` which is itself part of
a GPL-3.0-or-later project (`docs/native-n1-status.md`) — compatible: the
combined work may be distributed under GPL-3.0-or-later, the strictest
applicable term among the four.

## Meshtastic packet layer (`meshtastic.cmake`)

Built into the static target `sdrcore_meshtastic_pb` and linked into
`libsdrcore`. Only the protobuf decoder runtime is compiled (no encoder, no
`PB_ENABLE_MALLOC`); nothing here runs protoc or Python at app build time.

### nanopb — `nanopb/`

- Upstream: https://github.com/nanopb/nanopb, tag `nanopb-0.4.9.2`,
  commit `160d4f09e5fabb2b66aa2dea32d4f38ace2c4b3f`.
- License: **zlib** (`nanopb/LICENSE.txt`).
- Vendored verbatim: `pb.h pb_common.c pb_common.h pb_decode.c pb_decode.h`.
  The encoder and generator are not vendored; the generator from the same
  tag is fetched on demand by `meshtastic-protobufs/regen.sh`.
- Why nanopb: a ~2 kLoC C runtime with static, size-bounded structs; the
  Meshtastic firmware itself uses it with the same `.options` files. A full
  protobuf runtime (libprotobuf/protobuf-lite) was rejected by the task.

### Meshtastic protobufs — `meshtastic-protobufs/`

- Upstream: https://github.com/meshtastic/protobufs, commit
  `95c5f8c1c4223bb27faa81417b90560037f8ad31` (2026-10-03).
- License: **GPL-3.0** (`meshtastic-protobufs/LICENSE`).
- Vendored verbatim under `proto/meshtastic/`: `mesh channel config
  device_ui module_config atak xmodem telemetry portnums paxcount
  storeforward remote_hardware field_metadata` (`.proto` and `.options`
  where present) — `mesh.proto` and its import closure plus the app payload
  messages. Not vendored: admin, deviceonly, localonly, powermon, mqtt,
  apponly, cannedmessages, rtttl, clientonly, interdevice, nanopb.proto.
- `generated/meshtastic/*.pb.{c,h}`: committed output of
  `meshtastic-protobufs/regen.sh` (nanopb 0.4.9.2 generator,
  `-s enum_to_string:true`). Regenerate with that script; do not hand-edit.

### crypto-algorithms AES — `crypto-algorithms/`

- Upstream: https://github.com/B-Con/crypto-algorithms, commit
  `cfbde48414baacf51fc7c74f275190881f037d32` (2015-04-26).
- License: **public domain** (`crypto-algorithms/README.md`).
- Vendored: `aes.c aes.h README.md`. Only `aes_key_setup` and
  `aes_encrypt` are used; Meshtastic's CTR mode (32-bit big-endian counter
  in the last 4 nonce bytes, firmware `CryptoEngine` with
  `setCounterSize(4)`) is implemented in `native/src/meshtastic`.
- Patched: `patches/crypto-algorithms-aes-shift-ub.patch` casts two
  `BYTE << 24` shifts to `WORD` (signed-int overflow found by UBSan in
  `meshtastic_packet_test`; results unchanged on all real targets).
- Side channels: table-based AES, not constant time. Acceptable here: the
  decoder only decrypts received broadcast traffic with keys typed by the
  user; nothing is encrypted or transmitted.

### License compatibility

zlib (nanopb) and public domain (AES) are GPL-compatible. The Meshtastic
protobufs are GPL-3.0 and this project is GPL-3.0-or-later, so the combined
`libsdrcore` is distributed under GPL-3.0.

## Reproducing the pin / patch provenance

```
# rtl-sdr base (already pinned in the local reference checkout):
git -C <refs>/rtl-sdr log -1 --format='%H %ci'
# -> 797f8143266d983c56d8f35d2d442527529dd8a5 2026-08-12 00:11:56 +0200

# hackrf base (already pinned in the local reference checkout):
git -C <refs>/hackrf log -1 --format='%H %ci'
# -> 7f96cc8e3fa625c4263a71ba8dd44d1f6110e4fa 2026-09-17 11:09:19 -0400

# open-by-fd source commits (for reference only; not vendored wholesale):
git ls-remote https://github.com/AlexandreRouma/rtl-sdr.git  # HEAD ddd6811b71359c299cf31b4e3e75fbb1ed5c964d
git ls-remote https://github.com/AlexandreRouma/hackrf.git   # HEAD b1275e9c240b64cd7a8fd9bac70d77a8dd957616
```

The exact unified diffs applied are kept in `patches/` for audit/reproduction.

## miniaudio — `miniaudio/`

- Upstream: https://github.com/mackron/miniaudio, tag **0.11.25**; only
  `miniaudio.h` and `LICENSE`, unmodified (hashes in
  `miniaudio/PROVENANCE.md`).
- License: Public Domain (Unlicense) or MIT No Attribution, at the
  recipient's choice; GPL-3.0-compatible.
- Desktop playback only (`native/src/audio/miniaudio_sink.cpp`): CoreAudio on
  macOS, WASAPI on Windows, PulseAudio/ALSA (dlopen'ed) or the null backend on
  Linux. Compiled with hidden visibility; not part of Android builds.

## SDR++ rtl_tcp client — `sdrpp_rtl_tcp/`

- Upstream: https://github.com/AlexandreRouma/SDRPlusPlus, commit
  `8c9f5ee8fe405775bfcd62c8c8f8c0fc928a64af`,
  `source_modules/rtl_tcp_source/src/rtl_tcp_client.{h,cpp}` and `main.cpp`.
- License: **GPL-3.0**, compatible with this GPL-3.0-or-later app.
- `upstream/` holds the reference client's source (formatting condensed);
  `rtl_tcp_source/src/` builds the dependency-substituted port. The client
  retains its opcode set, big-endian command packing and u8-IQ conversion.
  See `sdrpp_rtl_tcp/PATCHES.md` for dependency substitutions, server-version
  limitations and the original-vs-port command/IQ oracle.

## Recording codecs — `codecs.cmake`

Pinned release archives (verify a fresh download with `sha256sum`) are trimmed
only to the library source, headers, source manifests, and relevant license
files. The four static PIC targets are built from those checked-in files;
there is no `find_package`, FetchContent, system codec library, or prebuilt
binary. The parent CMake file must `include(third_party/codecs.cmake)` after
`add_subdirectory(third_party)` and link the targets where recording needs them.

| Directory / target | Upstream archive | SHA-256 | License |
| --- | --- | --- | --- |
| `flac/` / `sdrcore_flac` | https://downloads.xiph.org/releases/flac/flac-1.4.3.tar.xz | `6c58e69cd22348f441b861092b825e591d0b822e106de6eb0ee4d05d27205b70` | BSD-3-Clause (`flac/COPYING.Xiph`, libFLAC file headers) |
| `lame/` / `sdrcore_lame` | https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz | `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e` | LGPL-2.0 (`lame/COPYING`, `lame/README`); optional decoder excluded |
| `ogg/` / `sdrcore_ogg` | https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz | `c4d91be36fc8e54deae7575241e03f4211eb102afb3fc0775fbbc1b740016705` | BSD-3-Clause (`ogg/COPYING`) |
| `opus/` / `sdrcore_opus` | https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz | `65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1` | BSD-3-Clause (`opus/COPYING`) |

Local added files inside the upstream trees are
`ogg/include/ogg/config_types.h` and `lame/sdrcore_config/config.h`, portable
replacements for upstream configure-generated headers. The upstream FLAC 1.4.3
`src/share/win_utf8_io/win_utf8_io.c` was restored from
https://github.com/xiph/flac/blob/1.4.3/src/share/win_utf8_io/win_utf8_io.c
for the Windows build (SHA-256
`04fe4e8fc1764eaccea092a789476375e12e8ada09637d7ddd04b3e3e6a84794`).
The sole upstream source edit adds `<inttypes.h>` to `flac/src/libFLAC/stream_decoder.c` for its
`PRIu64` diagnostic on toolchains that do not include it transitively.
libFLAC and Opus use portable scalar implementations;
FLAC Ogg mapping is disabled, while the separate Opus target propagates
`sdrcore_ogg` for writing Ogg Opus files. LAME's encoder is linked statically
without mpglib decoder; preserving LGPL-2.0 terms includes providing source
and the ability to relink with a modified library (e.g. replacement static
objects). These permissive and LGPL components can be combined with this
GPL-3.0 application; retain their upstream notices and source when distributing.
MP3 patent constraints may differ by jurisdiction; this is not patent advice.

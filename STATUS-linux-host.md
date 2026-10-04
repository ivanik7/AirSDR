# L1 — Linux desktop target: status

Task: t_44ca5b44 (board `sdr`). Scope: make libsdrcore.so and the Flutter app
usable on desktop Linux as the dev/test target for the receiver, before N2.
The Dart receive engine is intentionally NOT supported on Linux.

## What landed

Native (shared `native/` tree, same sources as Android):
- `native/include/sdrcore_host.h` + `native/src/sdrcore_host.cpp`: optional
  host-only extension of ABI 2. `sdr_version()` stays 2; clients probe the
  symbols by name. Android builds do not compile or export them.
  - `sdr_host_usb_list(out, capacity, count)`: libusb enumeration of non-hub
    devices; strings come from sysfs (no control transfers to a device that
    may be streaming).
  - `sdr_host_open_usb(handle, bus, address, source)`: opens
    `/dev/bus/usb/BBB/DDD` and hands the fd to the existing `sdr_v2_open_usb`
    path. That path dup()s the fd and owns the duplicate. New codes:
    `SDR_HOST_ACCESS_DENIED = -16` (EACCES/EPERM) and
    `SDR_HOST_NOT_FOUND = -17`.
- `native/src/audio/`: the internal audio sink contract (`audio_sink.h`) for N2,
  with null, WAV (16-bit stereo, header kept valid while recording, clipping
  +1.5→32767 / −1.5→−32768), and ALSA (non-blocking; drops are counted and
  never block) backends. The contract is not part of the public ABI, and its
  symbols are hidden. N2 will connect the demodulator to it; nothing produces
  audio yet.
- Tests: `sdrcore_host_usb` (argument validation, enumeration consistency,
  failed open leaves the handle state untouched) and `sdrcore_audio_sink`.
  Diagnostic tool: `sdrcore_host_rx_diag`, which writes a JSON Lines real-RX
  log. The tests and the tool are configured only when `native/` is the
  top-level CMake project.

Flutter:
- `linux/`: generated runner. `linux/CMakeLists.txt` builds `native/` with
  `add_subdirectory` and installs `libsdrcore.so` into `bundle/lib/`.
- `lib/native/sdr_core.dart`: `openSdrCoreLibrary()` looks for the library in
  this order: explicit path, `$SDRCORE_HOST_LIBRARY`, `<exe dir>/lib/libsdrcore.so`,
  then the loader path. Also adds host USB bindings (probed with
  `providesSymbol`), typed `SdrCoreError`, and the result/state/source
  constants.
- `lib/platform/linux/host_iq_radio_controller.dart`: a `RadioController` on
  the native engine.
  - Hotplug polling, auto-start, and stop/replug semantics match the Android
    controller.
  - Retune and gain changes use a debounced stop→configure→start, because
    ABI 2 has no live retune. The VFO recenters at rest.
  - Access-denied errors produce a plugdev/udev hint.
  - Settings persist in `linux_host_radio.json`.
- `lib/platform/linux/native_required_radio_controller.dart`: shown when the
  library cannot be loaded or lacks the host layer. It has no devices, never
  runs, uses linkState `failed`, and explains in `lastError` that the native
  core is required.
- `lib/main.dart`: on Linux it picks one of the two controllers above;
  Android is unchanged.
- `compactStatsLine`: for the native host engine it shows `ring drops N` and
  `IQ only, no audio (N2)` instead of USB/audio drop counters.

## Verification (debian-ai, RTL-SDR Blog V4 0bda:2838 on /dev/bus/usb/009/002)

- `cmake -S native -B <b> -G Ninja && cmake --build <b> && ctest --test-dir <b>`:
  8/8 passed. ALSA was found (1.2.14). On this VM, ALSA `default` fails to open
  because no playback PCM exists; the sink handles that as −4.
- `nm -D --defined-only bundle/lib/libsdrcore.so`: only `sdr_*` exports
  (11 ABI-2 symbols and 2 `sdr_host_*` symbols); audio symbols are hidden.
- Native real RX, `sdrcore_host_rx_diag --seconds 610`: log in
  `~/prj/docs/l1-host-rx-600s.jsonl`. Summary `ok: true`.
  - Run 1: 610.0 s at 101.4 MHz, 2.4 MSPS, gain 20 dB. 1 463 246 848 samples,
    2 398 616 S/s average. 40 960 ring drops (0.0028 %), all in the first 30 s
    and none afterwards.
  - Then: stop → configure to 99.5 MHz at gain 38 dB → restart.
  - Run 2: 61 s, 2 399 720 S/s, 0 drops, no native error.
- Dart controller on hardware, `SDR_HW_TEST=1 SDR_HW_SECONDS=600 flutter test
  test/platform/host_iq_hw_test.dart`: passed in 10:13. Snapshots are in
  `~/prj/docs/l1-host-controller-600s.json`.
  - 600 one-second snapshots, 100 MHz, 2.4 MSPS. Steady average
    2 400 256 S/s (error 0.011 %), 1.45 G samples. Every snapshot was
    `receiving` with 0 ring drops and native error 0.
  - Retune to 99.5 MHz at gain 38 dB: 5 s. After stop/start: 5 s. VFO offset
    0 at rest.
  - Final state: `stoppedByUser`, `lastError` null.
- App: `flutter build linux --debug` succeeded. Under `xvfb-run` the app
  auto-opened the Blog V4 ("RTL-SDR Blog V4 Detected" in the log). The status
  line reads `2.40 MS/s · ring drops 0 · IQ only, no audio (N2)`; see
  `~/prj/docs/screens/l1-linux-receive.png`. With an invalid
  `SDRCORE_HOST_LIBRARY` the app shows `ошибка подключения` and the
  native-required message (`~/prj/docs/screens/l1-linux-native-required.png`).
- `flutter analyze`: no issues. `flutter test` on master: 647 passed, 7
  skipped. The pre-existing timer test `ConfigManager: load default, debounced
  autosave, reload` times out intermittently under full-suite load. It fails the
  same way on baseline 981ebed, without L1 (1 of 2 runs), and passes alone.

## Known gaps / not verified

- No spectrum, waterfall, demodulation, or sound on Linux yet. That is N2 by
  design: ABI 2 only streams IQ into the native ring. The waterfall is empty
  rather than faked.
- The early ring-drop burst (about 41 k samples in the first 30 s) is
  consistent with the 8-slot × 8 KiB ring having no consumer pacing during
  warm-up. It was not investigated further. It is ring overflow, not USB loss.
- Audible ALSA output is unverified: this VM has no playback PCM. Only the
  WAV/null backends were checked bit-exactly.
- HackRF on the host path is untested (no device attached).
- Android: `flutter build apk --debug` on master succeeded. The arm64
  `libsdrcore.so` exports only the ABI-2 `sdr_*` and JNI symbols, with no
  `sdr_host_*`. The APK was not installed, and the phone was not touched, per
  scope.
- USB permissions: the user needs rw access to `/dev/bus/usb/*` (plugdev group
  plus the librtlsdr udev rule). Otherwise the app shows the
  `permissionDenied` state with that hint.

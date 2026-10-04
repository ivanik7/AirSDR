# AirSDR

Flutter receiver for RTL-SDR and HackRF on Android (API 26+, arm64-v8a) and Linux desktop. GPL-3.0-or-later. The C++ `libsdrcore` ABI v3 is the **only production receiver**: USB drivers, IQ ingestion, FFT, demodulation and audio stay native. Dart/Flutter owns the UI and low-rate control/FFT snapshots. There is one receiver, one VFO and one audio stream. `SDR_ENGINE=dart` and the Dart engine fallback were removed in N5; an incompatible or missing native library is reported as an error, never replaced with a mock receiver. Older Android API 24/25 devices cannot install this version because native AAudio needs API 26.

## Layout

| Path | Role |
| --- | --- |
| `native/` | C++ ABI v3, source-built libusb/librtlsdr/libhackrf, DSP/FFT, audio sinks, CTest and host golden-IQ oracles. |
| `lib/native/` | FFI, native radio controller, USB device catalog, Android USB permission/fd MethodChannel client, persisted radio settings and legacy JSON migration. |
| `lib/platform/linux/` | Honest unavailable-native state. Linux receives through `NativeRadioController`, not an IQ-only adapter. |
| `lib/runtime/background_reception.dart` | Foreground notification updates and Stop handoff; the native controller promotes the Android service before DSP start and releases it after teardown. |
| `lib/ui/` | Spectrum/waterfall, frequency/step/scan, Receive/Presets/Settings UI, favorites/channels/bands and shared-preferences persistence. `DemoRadioController` is only for UI tests. |
| `android/app/` | USB permission and connection/fd ownership, foreground service, audio focus and Android lifecycle. Kotlin's ABI-2 diagnostic bridge remains for the opt-in N1 QA harness, not a second production receiver. |

Native radio settings live in `native_radio.json`. On first launch after an upgrade the controller reads `config.json` / `radio_config.json` or `linux_host_radio.json` where available, writes the migrated native file, and leaves all legacy files untouched. Favorites, channels, band and step data remain in their existing shared-preferences stores. A legacy engine-selection value has no effect. The old RTL gain index is saved as pending, then resolved against the opened dongle's sorted native tuner-gain table when its serial matches. If the identity/table/index cannot be verified, the native default gain is used and the pending index plus legacy file are retained; no index is misread as dB. Other supported frequency, mode, bandwidth, sample-rate and squelch values migrate. The old receiver is recoverable from Git history, not an installed fallback.

Native ABI v3 does not expose tuner AGC or device-specific controls. Its additive `sdr_v3_set_wfm_stereo` switch enables pilot-locked WFM stereo; absent/weak pilots fall back to mono, and the default remains mono for existing settings. Decoder shows the switch only in WFM and persists it in `native_radio.json`. See `STATUS-wfm-stereo.md`, `docs/native-n2-adr.md` and `docs/native-n5-inventory.md`. Historical Dart architecture and its verification records are retained in `STATUS-*.md` and the history of `~/prj/docs/10-architecture.md`.

## Build and test

```sh
source ~/prj/env.sh
flutter pub get
flutter analyze
flutter test --concurrency=1
native/tests/run_host_tests.sh
native/tests/n2/run_n2_oracles.sh --hw  # requires RTL-SDR; includes baseline and 600-second soak
flutter build linux --debug
flutter build apk --debug
flutter build apk --release --target-platform android-arm64
```

For FFI tests, set `SDRCORE_HOST_LIBRARY` or `SDRCORE_V3_PROBE_LIBRARY` to the absolute path of a host `libsdrcore.so`; without them the opt-in tests are skipped. On Linux the app loads the bundled `libsdrcore.so`, needs access to `/dev/bus/usb/*` and defaults to the native null audio sink; set `SDR_AUDIO_SINK=wav:<path>` or `alsa:<pcm>` for output. Android debug APKs can also target emulator ABIs, but a missing arm64 native library is an error, not fake reception. Release is arm64-v8a only, currently signed with the debug key.

Host acceptance uses the attached RTL-SDR Blog V4 (see `STATUS-n2-integration.md` for prior 600-second soak, drop comparison, spectrum/waterfall screenshots and WAV). The optional phone-only Android QA card covers USB OTG, AAudio audibility, detach/replug, background/notification Stop and Activity recreation. A build or host WAV does not establish phone audibility.

Supported native sources: RTL2832U devices from the librtlsdr registry (including Blog V4) and HackRF receive. Airspy and FC2580 remain unsupported. Decoder backends are not implemented; do not infer otherwise from UI placeholders.

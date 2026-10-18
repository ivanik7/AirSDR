<div align="center">

<img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="AirSDR icon" width="128" height="128">

# AirSDR

**The all-in-one SDR app for your pocket and your desktop.**
Plug in an RTL-SDR or HackRF and listen, see and decode the radio spectrum,
with a native C++ engine and a touch-first interface.

[Features](#features) ·
[Decoders](#decoders) ·
[Hardware](#supported-hardware) ·
[Downloads](#downloads) ·
[Build](#build-from-source) ·
[Architecture](#architecture) ·
[Roadmap](#roadmap) ·
[AI disclosure](#ai-disclosure)

</div>

---

## Why AirSDR?

Most SDR software is powerful but was built for a mouse, a big screen and
a lot of patience. AirSDR keeps that power and adds **a UX you can use with one thumb**:

- **It works like a real handheld radio.** A big frequency readout, a numeric keypad,
  VFO memory slots, squelch and step keys. If you have ever held a handheld transceiver,
  you already know how to use AirSDR.
- **One app instead of five.** Listening, the spectrum, the waterfall, scanning, favorites
  and data decoders live in one place. You don't need a separate `rtl_433`
  terminal, a separate ADS-B server or a separate SSTV program.
- **The native engine does the heavy lifting.** The USB drivers, DSP, FFT, demodulation and
  audio run in C/C++. High-rate IQ never goes through the UI layer, so the waterfall
  stays smooth and the CPU doesn't drain your battery.
- **Proven upstream decoders.** AirSDR embeds the real `rtl_433`,
  `dump1090-fa`, `redsea` and `csdr` SSTV engines, built from source
  and checked against the original tools with oracle tests.

## Features

### 📟 Handheld-radio UX
- **Numeric keypad inspired by real handheld radios:** type `1` `4` `5` `.` `5`, press **OK**, and you're tuned.
- **Channel slots like VFO memories:** each slot keeps its own frequency and mode, and one tap switches between them.
- **Step keys and a frequency grid:** every input snaps to the selected step, and band plans like CB use their own channel origin.
- Drag the VFO across the spectrum and release it: the receiver retunes once and recenters.

### 🌊 Spectrum and waterfall
- Real-time FFT spectrum and waterfall.
- **Auto-contrast:** waterfall levels follow the noise floor on their own, with no manual sliders.
- Pinch to zoom, drag to pan, and tap a signal to tune to it.

### ⭐ Presets, channels and scanning
- Favorites and presets grouped by band.
- **Sequential channel scanner** on a single real receiver, with no fake "multi-channel" indicators.

### 🔋 Built for mobile
- **Background reception** with a foreground notification and a Stop button.
- Android USB OTG: the permission prompt, device hot-plug and audio focus are all handled.
- Native AAudio output on Android and ALSA/WAV on Linux.

## Decoders

| Decoder | What it does | Engine |
| --- | --- | --- |
| **Analog voice** | NFM · WFM (stereo) · AM · USB · LSB · DSB · CW · RAW | native `libsdrcore` DSP |
| **ADS-B** | Live aircraft list at 1090 MHz: callsign, altitude, position and details | embedded `dump1090-fa` |
| **RDS / RBDS** | FM broadcast metadata: PS, RadioText and PTY | `redsea` + `liquid-dsp` |
| **SSTV** | Slow-scan TV pictures with VIS auto-detect, a live preview, a gallery and saving | `csdr-plus` SstvDecoder + FFTW |
| **rtl_433** | Hundreds of ISM devices at 433/868/915 MHz: weather stations, sensors, remotes and TPMS | embedded upstream `rtl_433` |

## Supported hardware

| Device | Status |
| --- | --- |
| **RTL-SDR** (RTL2832U, including RTL-SDR Blog V4) | ✅ Supported |
| **HackRF One** | ✅ Receive |
| **rtl_tcp** (network RTL-SDR) | ✅ Classic rtl_tcp v1; Settings → SDR CONNECTION |

| Platform | Status |
| --- | --- |
| **Android** | ✅ API 26+; arm64-v8a, armeabi-v7a, x86_64 |
| **Linux** desktop | ✅ deb, rpm, Arch and tar.gz packages (needs more testing) |
| macOS | 🛠️ Built in CI; not yet tested on real hardware |
| Windows | 🛠️ Built in CI; not yet tested on real hardware |

## Downloads

[![ci](https://github.com/ivanik7/AirSDR/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/ivanik7/AirSDR/actions/workflows/ci.yml?query=branch%3Amaster)

| Platform | [Stable release](https://github.com/ivanik7/AirSDR/releases/latest) | [Latest build](https://github.com/ivanik7/AirSDR/releases/tag/nightly) |
| --- | --- | --- |
| **Android** 8.0+ | [arm64](https://github.com/ivanik7/AirSDR/releases/latest/download/AirSDR-android-arm64-v8a.apk) · [armv7](https://github.com/ivanik7/AirSDR/releases/latest/download/AirSDR-android-armeabi-v7a.apk) · [x86_64](https://github.com/ivanik7/AirSDR/releases/latest/download/AirSDR-android-x86_64.apk) | [arm64](https://github.com/ivanik7/AirSDR/releases/download/nightly/AirSDR-android-arm64-v8a.apk) · [armv7](https://github.com/ivanik7/AirSDR/releases/download/nightly/AirSDR-android-armeabi-v7a.apk) · [x86_64](https://github.com/ivanik7/AirSDR/releases/download/nightly/AirSDR-android-x86_64.apk) |
| **Linux** x86_64 | [deb](https://github.com/ivanik7/AirSDR/releases/latest/download/AirSDR-linux-amd64.deb) · [rpm](https://github.com/ivanik7/AirSDR/releases/latest/download/AirSDR-linux-x86_64.rpm) · [Arch](https://github.com/ivanik7/AirSDR/releases/latest/download/AirSDR-linux-x86_64.pkg.tar.zst) · [tar.gz](https://github.com/ivanik7/AirSDR/releases/latest/download/AirSDR-linux-x86_64.tar.gz) | [deb](https://github.com/ivanik7/AirSDR/releases/download/nightly/AirSDR-linux-amd64.deb) · [rpm](https://github.com/ivanik7/AirSDR/releases/download/nightly/AirSDR-linux-x86_64.rpm) · [Arch](https://github.com/ivanik7/AirSDR/releases/download/nightly/AirSDR-linux-x86_64.pkg.tar.zst) · [tar.gz](https://github.com/ivanik7/AirSDR/releases/download/nightly/AirSDR-linux-x86_64.tar.gz) |
| **macOS** 12+ | [Universal](https://github.com/ivanik7/AirSDR/releases/latest/download/AirSDR-macos.dmg) | [Universal](https://github.com/ivanik7/AirSDR/releases/download/nightly/AirSDR-macos.dmg) |
| **Windows** 10+ | [x64](https://github.com/ivanik7/AirSDR/releases/latest/download/AirSDR-windows-x86_64.zip) | [x64](https://github.com/ivanik7/AirSDR/releases/download/nightly/AirSDR-windows-x86_64.zip) |

Android: arm64 fits most phones, armv7 older 32-bit phones, x86_64
emulators and Chromebooks. Linux: deb for Debian 13+ and Ubuntu 24.04+, rpm
for Fedora and openSUSE, tar.gz for any other distribution. The latest build
(`nightly` pre-release) is rebuilt from master on every push and is not a
stable release. The release and build pages show the exact versions.
macOS and Windows builds have not been tested on real hardware yet. The
macOS app is not notarized (System Settings > Privacy & Security > Open Anyway on the first launch), and on
Windows the dongle needs the WinUSB driver (Zadig). Linux packages install
udev rules for the dongles and play audio through ALSA.

## Build from source

```sh
flutter pub get
flutter analyze
flutter test --concurrency=1

# Native core: host tests
native/tests/run_host_tests.sh

# Apps
flutter build linux --debug
flutter build apk --debug
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64,android-x64
```

Requirements: the Flutter SDK version from `pubspec.yaml`, JDK 21, the Android SDK and NDK, and CMake.
All native dependencies (libusb, librtlsdr, libhackrf, FFTW, liquid-dsp and others)
are **built from source** and checked for licenses. No prebuilt binaries are used.

On Linux the app needs access to `/dev/bus/usb/*`. Audio output is set with
`SDR_AUDIO_SINK=alsa:<pcm>` or `SDR_AUDIO_SINK=wav:<path>`.
Release APKs are split per ABI and signed with the release key; releases are cut with
`tool/release.sh`. More details are in [`docs/desktop-build.md`](docs/desktop-build.md),
[`docs/ci.md`](docs/ci.md) and [`docs/releasing.md`](docs/releasing.md).

## Architecture

```
┌─────────────────────────────── Flutter (Dart) ───────────────────────────────┐
│  Receive · Presets · Decoders · Settings      spectrum/waterfall, tuning, UI   │
│                    ▲ low-rate FFT snapshots, decoder events (JSON)             │
└────────────────────┼──────────────────────────────────────────────────────────┘
                     │ FFI (C ABI v3)
┌────────────────────┴──────────── libsdrcore (C/C++) ──────────────────────────┐
│  USB (libusb · librtlsdr · libhackrf) → IQ → FFT                               │
│                                         └→ VFO → demod → audio (AAudio/ALSA)   │
│                                              └→ decoders: rtl_433 · dump1090 · │
│                                                 SSTV · redsea · DMR …          │
└───────────────────────────────────────────────────────────────────────────────┘
```

- **One receiver, one VFO, one audio stream.** This simple model keeps the UI predictable.
- High-rate IQ and audio **never** cross into Dart.
- The C ABI is stable and documented: [`native/include/sdrcore_v3.h`](native/include/sdrcore_v3.h),
  [`docs/native-n2-adr.md`](docs/native-n2-adr.md).

| Path | Role |
| --- | --- |
| `native/` | C++ core, drivers, DSP, decoders, CTest and golden-IQ oracles |
| `lib/native/` | FFI, the native radio controller, the USB device catalog and settings |
| `lib/ui/` | Spectrum/waterfall, tuning, presets, channels and decoder panels |
| `android/app/` | USB permission and fd handling, the foreground service and audio focus |
| `docs/` | ADRs, the decoder architecture and per-feature status reports |

## Roadmap

- [x] Native C++ receiver for RTL-SDR and HackRF
- [x] WFM stereo + RDS
- [x] rtl_433, ADS-B and SSTV decoders
- [x] Channel scanner, presets and band plans
- [ ] DMR voice
- [ ] Meshtastic / LoRa
- [ ] ADS-B map view
- [ ] Recording and playback of IQ and audio
- [x] Linux packages and macOS/Windows builds in CI
- [ ] Test the macOS and Windows apps on real hardware

## Acknowledgements

AirSDR stands on the shoulders of great open-source projects:

- [SDR++](https://github.com/AlexandreRouma/SDRPlusPlus): the UI and tuning model
- [OpenWebRX+](https://github.com/luarvique/openwebrx): reference decoder chains
- [rtl_433](https://github.com/merbanan/rtl_433): ISM device decoding
- [dump1090-fa](https://github.com/flightaware/dump1090): ADS-B
- [redsea](https://github.com/windytan/redsea): RDS/RBDS
- [csdr](https://github.com/jketterl/csdr): SSTV
- [digiham](https://github.com/jketterl/digiham): DMR framing
- [mbelib](https://github.com/szechyjs/mbelib): AMBE voice synthesis
- [liquid-dsp](https://github.com/jgaeddert/liquid-dsp): DSP primitives
- [FFTW](https://www.fftw.org/): FFT
- [librtlsdr](https://github.com/osmocom/rtl-sdr): the RTL-SDR driver
- [HackRF](https://github.com/greatscottgadgets/hackrf): the HackRF driver
- [libusb](https://libusb.info/): USB access
- [miniaudio](https://miniaud.io/): audio output

Provenance and licenses for each embedded component are in `native/third_party/`.

## AI disclosure

AirSDR is written entirely with AI assistance. The code, tests and documentation
were produced by AI coding agents, including [Claude Code](https://claude.com/claude-code)
and [Hermes Agent](https://github.com/NousResearch/hermes-agent).
Changes are checked by static analysis and by unit, widget and native tests.
Decoders are also compared against the original upstream tools, and receiver changes
are tested on a real RTL-SDR. Co-author lines in the commit history show which agent
took part in each change.

## License

AirSDR is free software, licensed under **GPL-3.0-or-later**.
Third-party components keep their own licenses; see `native/third_party/NOTICE.md`.


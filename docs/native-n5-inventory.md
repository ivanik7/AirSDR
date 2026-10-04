# N5 receiver inventory and deletion boundary

This is the pre-deletion inventory for the N5 transition. N2 ABI v3 is the sole production receive contract after this change; the old implementation remains available in Git history, not in the application. Linux Blog V4 N2 acceptance is recorded in `STATUS-n2-integration.md` and `docs/native-n2-adr.md`. Android-only reception is assigned to the independent phone-check card.

| Component | Decision | Reason / replacement |
| --- | --- | --- |
| `lib/main.dart` engine switch, `createRadioController`, `SDR_ENGINE`, Android API/ABI Dart fallback | Delete fallback; fail visibly if native ABI unavailable | A silent Dart fallback would contradict one engine. Raise Android minSdk to 26 because native AAudio needs it; APK upgrade on API 24/25 is not supported. |
| `lib/runtime/sdr_radio_controller.dart`, DSP engine/isolate/protocol, source registry, audio output, `link_tone.dart` | Delete | Native ABI v3 owns USB, DSP, demodulation and audio; no IQ or PCM in Dart. |
| `lib/runtime/background_reception.dart` | Keep and simplify | UI/service notification control and native Stop remain required; remove Dart-specific start/stop ownership. |
| `lib/runtime/device_sources.dart` | Delete DSP registry/controls; move only device display metadata to `lib/native/` | Native controller needs VID/PID classification, valid sample rates, gain/range and display names, not Dart source modules. |
| `lib/usb/` and `lib/drivers/` | Delete Dart usbfs transport/drivers; move Android MethodChannel discovery, permission and fd ownership into `lib/native/` | Kotlin still owns the original USB connection; ABI v3 duplicates fd and closes its own copy. |
| `lib/sdrpp/dsp`, `core`, `modules`, `signal_path` | Delete | Native pipeline and host golden IQ/oracle tests replace the DSP and source graph. The `SourceSetting` UI value classes move into UI, not an SDR++ runtime directory. |
| `lib/platform/linux/host_iq_radio_controller.dart` | Delete | ABI v2 IQ-only fallback has no DSP/audio; `NativeRadioController` with ABI v3 is the Linux receiver. |
| `lib/platform/linux/native_required_radio_controller.dart` | Keep | Reports missing/incompatible native library without falsely starting another engine. |
| `lib/native/` | Keep | ABI/FFI, native controller and settings. Legacy JSON migration readers stay: do not delete user config data. |
| `lib/ui/` | Keep | `RadioController` contract, spectrum/waterfall, frequency/step, scan, bands, presets/channels/favorites and shared-preferences persistence remain UI/control work. Remove only Dart-controller-specific branching. |
| Android `UsbSdrPlugin.kt` and lifecycle, `ReceptionService` | Keep native USB permission/fd handoff and service, remove Dart-only branches when no longer used | Service Stop must release native USB/audio. Native session diagnostics may still exercise ABI v2 independently; do not delete a bridge used by native lifecycle tests. |
| `test/drivers`, `test/usb`, `test/sdrpp`, Dart `test/runtime`, Dart engine selection tests, obsolete Dart benchmark/oracle tools | Delete or replace | Keep host-native golden IQ tests (`native/tests/n2`) and tests for native controller, migration, UI and Android lifecycle. |

Native gaps are explicit, not secretly restored by Dart: tuner AGC, device-specific controls and true WFM stereo are unavailable under ABI v3. Preference migration from `config.json` / `radio_config.json` / `linux_host_radio.json` to `native_radio.json` is retained; favorites and channels retain their existing stores. No saved user data file is removed by the application.

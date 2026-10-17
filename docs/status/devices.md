# STATUS — worker `devices` (branch `wip/devices`)

SDR++ `rtl_sdr_source` and `hackrf_source` ported to Dart as `SourceHandler`s
(contract `lib/sdrpp/signal_path/source_handler.dart`) on top of the merged
drivers (`lib/drivers/rtlsdr`, `lib/drivers/hackrf`) and the usbfs transport.

## Done
| File | What |
|---|---|
| `lib/sdrpp/modules/sources/rtl_sdr_source.dart` | `RtlSdrSourceModule` — 1:1 port of `rtl_sdr_source/src/main.cpp` (header maps C++ lines). Sample-rate table (11 rates, 2.4 MS/s default in per-device config), `refresh` (Android: one device = the fd we got), `selectByName/selectById` (open → `getTunerGains` sorted → per-device config load/create → close), `select()` → `core.setInputSampleRate`, `start` in the exact SDR++ order (sr → freq → ppm → bw 0 → direct sampling → bias-T → RTL AGC → gain → gain mode/gain → offset tuning), `asyncCount = roundf(sr/(200*512))*512` (2.4M → 11776 B), worker = `resetBuffer` + `readAsync(cb, 0 /*15 bufs*/, asyncCount)`, `stop` (drop sink = stopWriter → `cancelAsync` → await worker = join → `close`), `tune` 10× retry loop with "took N attempts" warn, menu → `settings`/`applySetting` incl. the "re-apply AGC/gain mode/gain after disabling direct sampling" librtlsdr-bug workaround, ppm clamp ±1e6, gain slider over the tuner gain table (disabled with tuner AGC), widgets disabled while running are ignored. |
| `lib/sdrpp/modules/sources/rtl_sdr_convert.dart` | u8 → f32 via 256-entry LUT built with the C++ expression `((double)b - 127.4) / 128.0` (double math, one float rounding) — bit-identical to SDR++ (test over all 256 values vs the literal expression). |
| `lib/sdrpp/modules/sources/hackrf_source.dart` | `HackrfSourceModule` — 1:1 port of `hackrf_source/src/main.cpp`: 7 sample rates (2 MHz default), 16 bandwidths + Auto (`hackrfComputeBasebandFilterBw(sr)`), LNA 0–40 step 8 / VGA 0–62 step 2 (SDR++ `SliderFloatWithSteps` quantisation), amp, bias-T, `selectBySerial` defaults/validation (incl. C++ quirks: `created` never true, invalid sr leaves srId 0), start order from docs/status/hackrf.md (`hackrfOpenSetup` → sr → bw → freq → antenna → amp → lna → vga → `startRx`), stop = `close()` (no stop_rx, like SDR++), callback int8 → f32 via `hackrfConvertS8ToF32`, returns -1 once the sink is dropped. |
| `lib/sdrpp/modules/sources/usb_source.dart` | Shared glue: `UsbSourceParams` (sendable map `{fd, vid, pid, deviceName, serial, manufacturer, product}` from the UI isolate), `UsbDeviceOpener` (default `UsbfsDeviceHandle.wrap(fd)`; tests inject mocks), `SourceModuleConfig` (ConfigManager stand-in: `acquire/release(modified)` → `onConfigChanged(fullConfigCopy)`; no dependency on sigpath's ConfigManager), `UsbSourceModule` interface (`saveConfig/restoreConfig/onConfigChanged/onError/refresh/dispose/deviceNames`), `SourceLog` (flog), `WatchedUsbDeviceHandle` (delegating handle that detects noDevice / bulk stream ending without cancel → module reports `onError(fatal: true)` and stops itself cleanly). |
| `lib/sdrpp/modules/sources/usb_source_factory.dart` | `usbSdrKind(vid,pid)` (RTL `knownDevices` 42 IDs / HackRF 3 IDs / Airspy R2/Mini + HF+ / unknown), `isSupportedUsbSdr`, `createUsbSource(params, core, …)` → `RtlSdrSourceModule` / `HackrfSourceModule`, Airspy/unknown → `UnsupportedUsbSdrException` (`UsbError.notSupported`). `usbSdrDisplayName(...)` / `usbSdrDisplayNameFromParams` for UI lists. |
| `tool/oracle/sources/` | Golden traces from the **real C libraries**: `rtl_scenarios/*.txt` (librtlsdr call sequences of the SDR++ module, run by the existing `tool/oracle/rtlsdr` interpreter) and `hackrf_source_oracle.c` (hackrf_source start/tune/menu/stop against real `hackrf.c` + `tool/oracle/hackrf/fake_libusb`). `build.sh` rebuilds both and regenerates `golden/*.trace` (committed). |
| `tool/source_convert_bench.dart` | AOT converter microbench. |

### Integration notes (for sigpath / runtime)
- Construct on the DSP isolate: `createUsbSource(paramsMap, core, savedConfig: …, onConfigChanged: …, onError: …)`; `paramsMap` = `AndroidUsb.open()` result (`fd,vid,pid`) + `AndroidUsbDevice.toMap()` fields (`deviceName, serial, manufacturer, product`).
- Register under `module.sourceName` ("RTL-SDR" / "HackRF"). `select()` pushes the rate; `start(sink)` → sink gets interleaved `Float32List` + sample count, buffer valid only during the call (RTL: 5888 samples/call at 2.4 MS/s; HackRF: 131072 samples/call).
- Persist `onConfigChanged(config)` per module (SDR++ files `rtl_sdr_config.json`, `hackrf_config.json`) and pass it back as `savedConfig`. Keys are per device: RTL `"<manufacturer> <product> [<serial>]"`, HackRF USB serial (or `fake_serial` if Android hides it).
- `onError(message, error, fatal:)`: `fatal: true` = device lost while streaming, the module already stopped itself (the UI should flip play state and call `AndroidUsb.close(deviceName)`).
- Device lost detection needs the usbfs reader to either `addError(UsbException(noDevice))` or close its stream (both handled).

## Tests
```
source ~/prj/env.sh
flutter test test/sdrpp/modules/sources/        # +39: All tests passed!
flutter analyze lib/sdrpp/modules test/sdrpp/modules tool/source_convert_bench.dart   # No issues found!
tool/oracle/sources/build.sh                    # regenerate goldens (gcc, ~/prj/ref/rtl-sdr, ~/prj/ref/hackrf)
```
- `rtl_sdr_source_test.dart` (19): full control-transfer trace of the module on `MockUsbDeviceHandle` (answers from the Dart twin of the oracle's RTL2832U/R82xx model) == C librtlsdr golden for 3 scenarios: default (ctor select + start + tune + stop), saved config + every menu action while running (incl. DS workaround), Blog V4 HF/VHF, E4000 / FC0012 / FC0013 (start, tune incl. SDR++ retry loop — 2 tries on E4000 PLL unlock, 10 on FC0012 at 1090 MHz —, gain slider, tuner AGC, stop); start prefix == driver oracle `r820t_sdrpp_start` up to the first `set_tuner_gain`; `BULKIN 81 15 asyncCount`; u8 → sink values bit-exact and counts (3 full + odd block), slots released; stop cancels stream/closes handle, restart with other rate; unplug → one fatal `noDevice` error, stream cancelled, handle closed; open failure; tune retry (3 injected I2C failures → "took 3 attempts"; permanent → 10 and freq 0); settings list; config create/save/restore/clamps; no-fd; unported tuner (FC2580) refused with error.
- `hackrf_source_test.dart` (10): control trace == C libhackrf golden (default; saved config + menu while running), non-control order `CFG 1, CLAIM 0, BULKIN 81 4 262144, RELEASE 0, CLOSE`; int8 → sink bit-exact over 262144+1000 B; stop/restart, Auto bandwidth; unplug → fatal error + clean stop; open failure; settings; selectBySerial quirks; stepped sliders.
- `usb_source_factory_test.dart` (10): all 42 known_devices → RTL, HackRF/Airspy/unknown, display names, factory types, Airspy → `UnsupportedUsbSdrException`, params round trip, RTL LUT == C++ expression for all 256 bytes.

### Converter microbench (AOT, x86-64 host)
`dart compile exe tool/source_convert_bench.dart -o $TMPDIR/scb && $TMPDIR/scb`
```
rtl u8 LUT (rtlsdrConvertU8ToF32)      1519 MB/s =   760 MS/s complex
rtl u8 reference (C++ expression)       338 MB/s =   169 MS/s complex
hackrf s8 LUT (hackrfConvertS8ToF32)   1517 MB/s =   758 MS/s complex
needed: RTL 3.2 MS/s max (6.4 MB/s), HackRF 20 MS/s (40 MB/s)
```

## Deviations from SDR++ (all documented in file headers)
- No threads: worker thread → un-awaited `readAsync` future; `stream.swap` → synchronous sink call (no back-pressure; the usbfs reader drops when slots run out, docs/10 §3).
- `start/stop` are serialized futures (a stop during an in-flight start waits for it).
- RTL device names use the desktop format without the ImGui `##i` suffix (Android SDR++ uses the constant "RTL-SDR Dongle USB") so config is per dongle serial. HackRF uses the USB serial instead of "fake_serial" when available.
- `freq` starts at 100 MHz (uninitialised in C++).
- Errors are reported via `onError` (SDR++ only logs). The one still unported RTL tuner (FC2580) is reported at select and `start()` refuses (librtlsdr would drive it).
- HackRF `startRx` failure is reported and the device closed (C++ ignores the result).

## Not done / next
- Not run against a real dongle or the real `UsbfsDeviceHandle` (fd path only covered by the default opener).
- FC2580 tuner not ported (rare; E4000/FC0012/FC0013 done, below).

## Optional item 5 — RTL tuners E4000 / FC0012 / FC0013 (done)
- `lib/drivers/rtlsdr/tuner_e4k.dart` (port of `tuner_e4k.c`, 1000 lines: PLL params, band/RF filter, IF filters, LNA/mixer/IF-stage gains, manual/auto gain, DC offset helpers, standby, init), `tuner_fc0012.dart`, `tuner_fc0013.dart` (shared PLL arithmetic `fcPllRegs`, C integer wrap-around reproduced incl. 32-bit `freq * multi`), wired into `librtlsdr.dart` `tuners[]` exactly as `librtlsdr.c:129-201` (incl. FC0012 GPIO6 V/U-band switch, `e4k_s.vco.fosc` refresh on ppm/xtal change).
- Verified by trace-diff against the real C drivers: `tool/oracle/rtlsdr/scenarios/{e4000,fc0012,fc0013}_full.txt` (replacing the probe-only scenarios) — every USB transfer and return value identical. The fakes (`fake_libusb.c` + Dart twin `fake_rtl_usb.dart`) now model the E4000 PLL-lock bit and FC001x VCO voltage readback so the error/re-selection paths are exercised.
- Source-level goldens `tool/oracle/sources/golden/rtl_source_{e4000,fc0012,fc0013}.trace`.

## Contract questions
- `SourceHandler` has no way to report errors / state changes to SourceManager; implemented as module-level `onError`. Suggest adding `onError`/`onStopped` to the contract (or a `SourceCore.sourceError(...)`).
- `SliderSetting` for the RTL gain is an index slider (0..N-1); the label carries the dB text (`Gain 29.7 dB`). A `valueLabel` field in `SliderSetting` would be cleaner.
- No "button" setting type: RTL/HackRF "Refresh" is `applySetting('refresh', true)` and not listed in `settings`.

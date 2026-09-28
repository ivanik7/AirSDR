# STATUS — worker `sigpath` (branch `wip/sigpath`)

Port of the SDR++ signal path, core module/config system, the radio decoder module with all
of its demodulators, and file/synthetic sources. Also includes the DSP isolate runtime and the
real `RadioController`. The reference is SDR++ @8c9f5ee. Every file header cites its C++ source
file and line numbers.

## Done

### `lib/sdrpp/core/`
| File | C++ | Notes |
|---|---|---|
| `event.dart` | utils/event.h | `Event<T>`, `EventHandler<T>`; unbind by identity; `bind()` helper |
| `config.dart` | config.h/.cpp | JSON `ConfigManager`, path injectable (null = in memory), missing/corrupt file resets to the default. Auto-save is debounced (1 s timer instead of the 1 s poll thread). Writes are atomic (tmp + rename). `flush()` added |
| `module.dart` | module.h/.cpp | `ModuleManager`/`ModuleFactory` (the 5 exported symbols)/`ModuleInstance` without dlopen. Error codes and maxInstances match 1:1. Added `createInstancesFromConfig` and `endAll` |
| `module_com.dart` | module_com.h/.cpp | `ModuleComManager` (in → argument, out → return value) |
| `core.dart` | core.cpp:34-57 | `Core` object (configManager, moduleManager, modComManager, sigpath); implements `SourceCore.setInputSampleRate`. The waterfall zoom reset becomes the `onInputSampleRateChanged` event |

### `lib/sdrpp/signal_path/`
| File | C++ | Notes |
|---|---|---|
| `iq_frontend.dart` | iq_frontend.h/.cpp | Runs preproc Chain [PowerDecimator, DCBlocker, Conjugate] → split into three branches: Reshaper → window·(−1)^i → FFT → `10log10(\|X/N\|²)`; the VFOs (RxVFO); and raw IQ taps. Also covers fftSize/Rate/Window, addVFO/removeVFO and setDecimation → core. Runs synchronously via `process(iq, count)`. The `init()` window bug is intentionally not reproduced (docs/03 §1.4). Power is floored at −200 dB |
| `vfo_manager.dart` | vfo_manager.h/.cpp + waterfall.cpp:1219-1293 | `VFOManager`/`VFO` plus a `WaterfallVFO` model (REF_LOWER/CENTER/UPPER; the DSP gets centerOffset). Applies the offset immediately, since there is no GUI frame loop |
| `source_manager.dart` | source.h/.cpp | register/unregister/select/start/stop/tune. Supports tuneOffset (|f+off|), panadapter mode and onRetune. A handler that is not selected feeds into nullSource |
| `sink_manager.dart` | sink.h/.cpp | `SinkStream` (splitter → Volume(v²) → Sink), `SinkManager` (providers, streams, per-stream config `streams{sink,volume,muted}`), `NullSink` |
| `signal_path.dart` | signal_path.h | `SignalPath` object replaces the globals (`iqFrontEnd`, `vfoManager`, `sourceManager`, `sinkManager`) |

### `lib/sdrpp/modules/radio/`
- `demod.dart` (demod.h + radio_interface.h). `demodulators/{wfm,nfm,am,usb,lsb,dsb,cw,raw}.dart`: usb/lsb/dsb re-export a shared `ssb_common.dart` because the C++ files are identical apart from 4 constants. ImGui `showMenu` is replaced by `options`/`setOption` with config save.
- `radio_module.dart` (radio_module.h + main.cpp):
  - IF chain: NoiseBlanker, PowerSquelch.
  - Demodulator stage.
  - AF chain: RationalResampler → 48 kHz, HPF 300 Hz, Deemphasis.
  - Output goes to the SinkStream.
  - `selectDemodByID`/`selectDemod` restore settings per mode. Persisted per mode: bandwidth, snap, squelch mode/level, highPass, deempMode, FMIFNR, noise blanker.
  - Setters follow C++. The module_com interface ("radio") is included.
  - `RadioModuleFactory` corresponds to `_INIT_`/`_END_` (radio_config.json).

### `lib/sdrpp/modules/sources/` (the device sources are left to the 'devices' worker)
- `file_source.dart` (file_source/main.cpp + wavreader.h):
  - WAV: walks the RIFF chunks. Handles 16-bit PCM and float32 (format 3/0xFFFE); 8-bit is read as cu8.
  - Raw formats: cf32/cu8/cs8/cs16, taken from an explicit param or the file extension.
  - Other behaviour: loops at EOF, reads the `NNNHz` frequency from the filename, ignores tuning.
- `synth_source.dart`: noise plus carriers with none/AM/NFM/WFM/WFM-stereo (19 kHz pilot, same MPX as the oracle)/USB/LSB/DSB/CW modulation, and a configurable sample rate. `tune()` moves the virtual LO. Output is deterministic (xorshift seed) with no per-block allocation (LUT oscillators).
- `source_pump.dart`: replaces the worker threads. Block size is sr/200. Modes: realTime (Timer + Stopwatch; skips the backlog after a stall of more than 250 ms), asFastAsPossible (bursts with event-loop yields), and manual (deterministic tests).

### `lib/runtime/`
- `dsp_protocol.dart`: the command/event constants. The protocol is documented in the file.
- `dsp_engine.dart`:
  - Contains Core + SignalPath + radio "Radio" + the selected source + the FFT-row producer + audio.
  - Isolate-agnostic, so it can be tested synchronously.
  - FFT rows are built with `zoomWindow`+`doZoom` (clamped to the band) and sent as a `TransferableTypedData` row of the requested width, at 20 rows/s by default. Default FFT is 8192 points at 20 Hz.
  - Persists `config.json` (frequency, vfoOffsets, streams, sources.*) and `radio_config.json` under `configDir`.
- `dsp_isolate.dart`: `DspIsolate.spawn(options, registerSources: hook)`, `send`, `request` (ack/err), `events`, `close` (graceful shutdown saves configs). Commands run strictly in order. Uncaught isolate errors are delivered as a fatal `error` event.
- `source_registry.dart`:
  - `SourceRegistry` maps id → factory(params, SourceContext). `SourceContext` provides core, reportError and loadConfig/saveConfig.
  - `SourceControls`/`GenericSourceControls` map sampleRate/gain/agc onto `applySetting` ids.
  - Built-in sources: `synth` and `file`.
  - **Integrator hook:** a top-level `void registerDeviceSources(SourceRegistry r)` that calls `r.register('usb', (p, ctx) => SourceInstance(createUsbSource(p, ctx.core, …), controls: …))`, using `createUsbSource` from the devices worker's `usb_source_factory.dart`. An example is in the file header.
- `audio_output.dart`:
  - Defines the `AudioOutput` abstraction with Null/Capture/MpAudioStream implementations, plus an `AudioOutputSink` SinkManager provider named "Audio".
  - **mp_audio_stream was checked** (0.3.0, pub cache). It is a pure ffiPlugin with no platform channel, so it can be called from a background isolate. Its native ring buffer is SPSC and drops blocks rather than blocking when full.
  - Its Dart `push()` does calloc + copy + free on every call, so the port binds `ma_stream_init/push/uninit` directly with one persistent native buffer (400 ms ring, 60 ms pre-roll).
  - On the host VM the .so is not built, so `tryCreate()` returns null and the engine falls back to NullAudioOutput. **Audio on a real Android device has not been verified.**
- `sdr_radio_controller.dart`: `SdrRadioController extends RadioController`.
  - Spawns the isolate and maps every UI call to a message.
  - Setters update local state optimistically. Once no command is in flight, local state is reconciled from DSP `state` events.
  - `fftRows` is a broadcast stream of `FftRow` (absolute low/high frequency).
  - Errors are reported through `lastError`.
  - Extension point: `List<DeviceProvider>` (`listDevices`/`owns`/`open` → `SourceSelection(id, params)`/`close`/`changes`). Built-in providers: `SynthDeviceProvider` and `FileDeviceProvider`.
  - The USB provider (`android_usb.dart` listDevices/open → fd → `SourceSelection('usb', {fd,vid,pid,…})`) is left to the integrator.
  - `lib/main.dart` is **not** changed.

### `tool/pipeline_bench.dart`: real-time factor of the full chain

## Tests

`source ~/prj/env.sh && flutter test`: **all 331 tests pass**, including every earlier test. `dart analyze lib test tool` reports **No issues found**.

Tests added by this worker (29):
- `test/sdrpp/modules/radio/radio_module_test.dart` (end to end: synth → IQFrontEnd → VFO → radio → 48 kHz, captured on the stream splitter; results from the FFT peak):
  - WFM stereo: L = 999.8 Hz, R = 400.1 Hz (rms 0.55).
  - WFM mono: 1 kHz.
  - NFM: 999.8 Hz (rms 0.34).
  - AM: 700.0 Hz.
  - USB: 1500.0 Hz; REF_LOWER centre = dial + bw/2 is checked.
  - LSB: 1200 Hz.
  - CW: 800 Hz tone.
  - DSB/RAW produce 48 kHz output.
  - Power squelch stays closed on noise and opens on a carrier.
  - Per-mode config persistence.
- `test/sdrpp/signal_path/signal_path_test.dart`:
  - FFT bin for a +300 kHz carrier is `N/2 + f/fs·N`, at level 20log10(A·0.3636) ±0.5 dB (normalised by N).
  - Reshape params; decimation → core.
  - `computeRow` puts a carrier on the expected pixel.
  - FFT rows run at 20 rows/s through the Rig.
  - SourceManager: tune offset, upconverter |f+off|, panadapter IF, stale-sink drop, unregister.
  - VFO references lower/upper.
  - ConfigManager: one write per burst, reload, corrupt-file reset.
  - Radio config survives a restart (file-backed).
  - ModuleManager errors and limits.
  - Event unbind.
  - FileSource: cf32/cs16/cs8/cu8 with looping; WAV float32 and int16.
- `test/sdrpp/modules/sources/sources_test.dart`: pump real-time pacing, synth determinism and reset, tune.
- `test/runtime/dsp_isolate_test.dart`:
  - Spawns the isolate with the synth source. Over 1.5 s it receives **30 FFT rows** (width 800; carrier on pixel 500 ±3) and **72,000 audio frames** (NFM 1 kHz peak). Stats: samplesIn 3.6 M, audioDropped 0.
  - The registerSources hook source ('fake-usb', fd=42) works.
  - A bad command is acked as an error.
  - `SdrRadioController` against the real isolate: start, rows 512 wide, mode/bandwidth/squelch, audioFrames > 0, stop.

## Real-time factor (host, AOT)
`dart compile exe tool/pipeline_bench.dart -o $TMPDIR/pipeline_bench && $TMPDIR/pipeline_bench 10 2400000 <mode>`

Setup: AMD Ryzen 7 5700G, 2.4 MSPS, full chain = IQFrontEnd (FFT 8192 @ 20/s) + VFO + demod + AF chain to 48 kHz, single core. Source generation is measured separately.

| mode | RTF | CPU of 1 core |
|---|---|---|
| WFM stereo | **8.0×** | 12.4 % |
| WFM mono | 15.5× | 6.4 % |
| NFM | 30.7× | 3.3 % |
| AM | 45.1× | 2.2 % |
| USB | 37.3× | 2.7 % |

The synth generator alone runs at about 6.6× real time at 2.4 MSPS (5 carriers + noise). On a phone, expect roughly 3–5× lower figures; WFM stereo at 2.4 MSPS should stay real-time.

## Not done / left
- **FMIF (FM IF noise reduction)** and **CTCSSSquelch** are missing from lib/sdrpp/dsp. RadioModule stores and saves their flags and modes exactly as C++ does, but inserts no block. CTCSS modes pass audio through unmuted.
- **RDS decoding** is not ported. The WFM `rds` option only enables the BroadcastFM RDS baseband output.
- IQFrontEnd `buffering` (SampleFrameBuffer) is stored but not used: there are no threads, and jitter is absorbed by the message queue.
- The real-time pump uses a Dart Timer (10 ms tick) on the DSP isolate. Device sources push from their USB callbacks instead, so this only affects file/synth.
- mp_audio_stream on Android has not been checked on a device (requires an APK build, which is the integrator's job). If `libmp_audio_stream.so` fails to load, the engine silently uses NullAudioOutput, visible in `stats.audioOutput`.
- The UI shows no source-specific settings (`state.sourceSettings` / `SdrRadioController.command({cmd: sourceSetting, …})` are available). The same applies to demod options such as WFM stereo (`command({cmd: demodOption, key: 'stereo', value: true})`).
- `SdrRadioController.setGain`/`setAgc` go through `GenericSourceControls` conventions (`gain`/`agc` ids). The devices worker's RTL/HackRF use different ids (`gain`, `tunerAgc`, `lnaGain`/`vgaGain`), so the integrator should supply a `SourceControls` for each device when registering 'usb'.

## Integrator checklist
1. Write a top-level `registerDeviceSources(SourceRegistry r)` in a devices-aware file that registers `'usb'` via `createUsbSource(params, ctx.core, onError: ctx.reportError, savedConfig: ctx.loadConfig(kind), onConfigChanged: (c) => ctx.saveConfig(kind, c))`, with suitable `SourceControls`.
2. Write a `UsbDeviceProvider implements DeviceProvider` on top of `AndroidUsb.instance`:
   - `listDevices` filtered by `isSupportedUsbSdr`;
   - `open` → fd → `SourceSelection('usb', {fd, vid, pid, deviceName, …})`;
   - `close`;
   - `changes` from the event channel.
3. In `lib/main.dart`: `SdrRadioController(providers: [UsbDeviceProvider(), SynthDeviceProvider()], options: DspEngineOptions(configDir: <app support dir>), registerSources: registerDeviceSources)`.

## Contract notes
- `source_handler.dart` is **unchanged**.
- `pubspec.yaml`: added `mp_audio_stream: ^0.3.0` (flutter pub add).

// SPDX-License-Identifier: GPL-3.0-or-later
// Integration of the USB SDR source modules (lib/sdrpp/modules/sources/usb_source_factory.dart)
// into the DSP isolate's SourceRegistry, plus the mapping of the RadioController's generic
// controls (sample rate, gain, AGC) onto each device's SDR++ menu settings.
//
// SDR++ equivalent: the rtl_sdr_source / hackrf_source modules registering themselves with
// SourceManager at init (docs/01 §2); here the module is created on demand from the fd the UI
// isolate obtained (lib/usb/usb_device_provider.dart → SourceSelection('usb', {...})).
//
// Generic control mapping (the UI shows one "Gain" slider in dB and one "AGC" checkbox):
//  * RTL-SDR: gain dB → nearest entry of the tuner gain table (`gainList`, tenths of dB) →
//    `gain` index slider; AGC → `tunerAgc` (the tuner's own AGC; SDR++ disables the gain slider
//    then). The RTL2832 digital AGC (`rtlAgc`) stays a device-specific setting.
//  * HackRF: gain dB (0‥102) → LNA (0‥40, step 8) + VGA (0‥62, step 2) split proportionally
//    (LNA:VGA ≈ 40:62, like SDR++'s two sliders moved together); the RF amp is never touched by
//    the generic slider (stays off unless enabled in the device settings). No AGC.
//  * Sample rate → nearest entry of the module's rate table (`sampleRate` choice index).
import '../sdrpp/modules/sources/hackrf_source.dart';
import '../sdrpp/modules/sources/rtl_sdr_source.dart';
import '../sdrpp/modules/sources/usb_source.dart';
import '../sdrpp/modules/sources/usb_source_factory.dart';
import '../sdrpp/signal_path/source_handler.dart';
import '../ui/radio_controller.dart' show GainRange;
import 'source_registry.dart';

/// Registry id of the USB device source.
const String usbSourceId = 'usb';

/// RegistryHook passed to `SdrRadioController(registerSources: …)` / `DspIsolate.spawn`.
/// Must stay a top-level function (sent to the DSP isolate).
void registerDeviceSources(SourceRegistry r) {
  r.register(usbSourceId, createUsbSourceInstance);
}

/// Factory for the 'usb' source (also used directly by tests with an injected [opener]).
SourceInstance createUsbSourceInstance(Map<Object?, Object?> params, SourceContext ctx,
    {UsbDeviceOpener? opener}) {
  final kind = usbSdrKind((params['vid'] as num).toInt(), (params['pid'] as num).toInt());
  // Per-module config key, like SDR++'s rtl_sdr_config.json / hackrf_config.json.
  final configKey = switch (kind) {
    UsbSdrKind.rtlSdr => 'rtl_sdr',
    UsbSdrKind.hackrf => 'hackrf',
    _ => 'usb',
  };
  String? lastError; // onError may fire inside the constructor (select → open)
  final module = createUsbSource(
    params,
    ctx.core,
    opener: opener,
    savedConfig: ctx.loadConfig(configKey),
    onConfigChanged: (c) => ctx.saveConfig(configKey, c),
    onError: (message, error, {bool fatal = false}) {
      lastError = error == null ? message : '$message ($error)';
      ctx.reportError(message, fatal: fatal);
    },
  );
  final handler = UsbSourceHandler(module, () => lastError, () => lastError = null);
  final SourceControls controls = switch (module) {
    RtlSdrSourceModule() => const RtlSdrControls(),
    HackrfSourceModule() => const HackrfControls(),
    _ => const SourceControls(),
  };
  return SourceInstance(
    handler,
    controls: controls,
    dispose: () => module.dispose(),
    stats: () => <String, Object?>{'droppedBuffers': handler.droppedBuffers},
  );
}

/// Delegating [SourceHandler] around a [UsbSourceModule]: the SDR++ modules report start
/// failures through `onError` and simply do not run; the engine needs a thrown error to keep
/// its play state consistent.
class UsbSourceHandler implements SourceHandler {
  UsbSourceHandler(this.module, this._lastError, this._clearError);

  final UsbSourceModule module;

  /// Last message given to `onError` (used as the start failure reason).
  final String? Function() _lastError;
  final void Function() _clearError;

  int get droppedBuffers => switch (module) {
        RtlSdrSourceModule m => m.openDev?.droppedBuffers ?? 0,
        _ => 0,
      };

  @override
  void select() => module.select();

  @override
  void deselect() => module.deselect();

  @override
  Future<void> start(SourceSink sink) async {
    _clearError();
    await module.start(sink);
    if (!module.running) {
      throw StateError(_lastError() ?? '${module.sourceName}: device did not start');
    }
  }

  @override
  Future<void> stop() => module.stop();

  @override
  void tune(double frequencyHz) => module.tune(frequencyHz);

  @override
  List<SourceSetting> get settings => module.settings;

  @override
  void applySetting(String id, Object value) => module.applySetting(id, value);
}

int _nearestIndex(List<num> table, double v) {
  int best = 0;
  for (int i = 1; i < table.length; i++) {
    if ((table[i] - v).abs() < (table[best] - v).abs()) best = i;
  }
  return best;
}

UsbSourceModule _module(SourceHandler h) => h is UsbSourceHandler ? h.module : h as UsbSourceModule;

// ---- RTL-SDR -------------------------------------------------------------------------------

/// UI gain range for RTL dongles (R820T/R828D table: 0‥49.6 dB; E4000 −1‥42, FC001x −9.9‥19.7).
const GainRange rtlSdrGainRange = GainRange(min: 0, max: 49.6, step: 0);

class RtlSdrControls extends SourceControls {
  const RtlSdrControls();

  @override
  bool setSampleRate(SourceHandler h, double sampleRate) {
    _module(h).applySetting(RtlSdrSettingId.sampleRate, _nearestIndex(rtlSdrSampleRates, sampleRate));
    return true;
  }

  @override
  bool setGain(SourceHandler h, double gain) {
    final m = _module(h) as RtlSdrSourceModule;
    if (m.gainList.isEmpty) return true;
    final idx = _nearestIndex(m.gainList, gain * 10);
    // SDR++ ignores the gain slider while the tuner AGC is on (BeginDisabled); remember it anyway.
    if (m.tunerAgc) {
      m.gainId = idx;
      m.updateGainTxt();
    } else {
      m.applySetting(RtlSdrSettingId.gain, idx);
    }
    return true;
  }

  @override
  bool setAgc(SourceHandler h, bool enabled) {
    _module(h).applySetting(RtlSdrSettingId.tunerAgc, enabled);
    return true;
  }

  @override
  double? gainOf(SourceHandler h) {
    final m = _module(h) as RtlSdrSourceModule;
    if (m.gainList.isEmpty) return null;
    return m.gainList[m.gainId.clamp(0, m.gainList.length - 1)] / 10.0;
  }

  @override
  bool? agcOf(SourceHandler h) => (_module(h) as RtlSdrSourceModule).tunerAgc;
}

// ---- HackRF --------------------------------------------------------------------------------

/// UI gain range for HackRF: LNA (0‥40) + VGA (0‥62) dB, amp off.
const GainRange hackrfGainRange = GainRange(min: 0, max: 102, step: 2);

/// Splits a combined gain (dB) into the (LNA, VGA) pair used by [HackrfControls].
(double, double) hackrfSplitGain(double gain) {
  final g = gain.clamp(0.0, 102.0);
  double lna = ((g * 40.0 / 102.0) / 8.0).round() * 8.0;
  lna = lna.clamp(0.0, 40.0);
  double vga = ((g - lna) / 2.0).round() * 2.0;
  vga = vga.clamp(0.0, 62.0);
  return (lna, vga);
}

class HackrfControls extends SourceControls {
  const HackrfControls();

  @override
  bool setSampleRate(SourceHandler h, double sampleRate) {
    _module(h).applySetting(HackrfSettingId.sampleRate, _nearestIndex(hackrfSampleRates, sampleRate));
    return true;
  }

  @override
  bool setGain(SourceHandler h, double gain) {
    final m = _module(h);
    final (lna, vga) = hackrfSplitGain(gain);
    m.applySetting(HackrfSettingId.lnaGain, lna);
    m.applySetting(HackrfSettingId.vgaGain, vga);
    return true;
  }

  @override
  bool setAgc(SourceHandler h, bool enabled) => true; // no AGC on HackRF

  @override
  double? gainOf(SourceHandler h) {
    final m = _module(h) as HackrfSourceModule;
    return m.lna + m.vga;
  }

  @override
  bool? agcOf(SourceHandler h) => false;
}

// ---- UI-side device metadata ----------------------------------------------------------------

/// Sample rates (Hz) offered by the UI for a USB device kind (the module's own tables).
List<double> usbSdrSampleRates(UsbSdrKind kind) => switch (kind) {
      UsbSdrKind.rtlSdr => rtlSdrSampleRates,
      UsbSdrKind.hackrf => <double>[for (final r in hackrfSampleRates.reversed) r.toDouble()],
      _ => const <double>[],
    };

GainRange usbSdrGainRange(UsbSdrKind kind) => switch (kind) {
      UsbSdrKind.rtlSdr => rtlSdrGainRange,
      UsbSdrKind.hackrf => hackrfGainRange,
      _ => const GainRange(min: 0, max: 0),
    };

bool usbSdrHasAgc(UsbSdrKind kind) => kind == UsbSdrKind.rtlSdr;

/// Tunable range shown by the frequency selector.
(double, double) usbSdrFrequencyRange(UsbSdrKind kind) => switch (kind) {
      UsbSdrKind.rtlSdr => (0, 2200000000), // incl. direct sampling (HF)
      UsbSdrKind.hackrf => (1000000, 6000000000),
      _ => (0, 999999999999),
    };

// SPDX-License-Identifier: GPL-3.0-or-later
// SourceRegistry: id → factory creating a [SourceHandler] inside the DSP isolate from a
// sendable params map. Replaces SDR++'s "one source module instance per device type,
// registered with SourceManager at module init" (docs/01 §2) with on-demand creation, since
// Android USB devices are opened by fd from the UI isolate.
//
// Built-in ids: 'synth' (SynthSource), 'file' (FileSource). The integrator plugs the
// devices worker's sources in via [SourceRegistry.register] — e.g.
//
//   registry.register('usb', (params, ctx) {
//     final m = createUsbSource(params, ctx.core, onError: ctx.reportError,
//         savedConfig: ctx.loadConfig('usb'), onConfigChanged: (c) => ctx.saveConfig('usb', c));
//     return SourceInstance(m, controls: UsbSourceControls(m));
//   });
//
// inside a top-level `void registerExtraSources(SourceRegistry r)` passed to
// [DspIsolate.spawn] as `registerSources` (see [SourceRegistryHook]).
import 'dart:async';
import 'dart:math' as math;

import '../sdrpp/modules/sources/file_source.dart';
import '../sdrpp/modules/sources/source_pump.dart';
import '../sdrpp/modules/sources/synth_source.dart';
import '../sdrpp/signal_path/source_handler.dart';

/// Services the DSP isolate offers a source factory.
class SourceContext {
  SourceContext({
    required this.core,
    required this.reportError,
    this.configLoad,
    this.configSave,
  });

  final SourceCore core;

  /// Reports an asynchronous source error (device unplugged…) to the UI. [fatal] = the source
  /// has stopped itself (the engine flips to not running).
  final void Function(String message, {bool fatal}) reportError;

  final Map<String, Object?>? Function(String key)? configLoad;
  final void Function(String key, Map<String, Object?> config)? configSave;

  Map<String, Object?>? loadConfig(String key) => configLoad?.call(key);
  void saveConfig(String key, Map<String, Object?> config) =>
      configSave?.call(key, config);
}

/// Maps the RadioController's generic source controls (sample rate, gain, AGC) onto a
/// specific source's [SourceHandler.applySetting] ids. Every method is optional.
class SourceControls {
  const SourceControls();

  /// Returns true if handled.
  bool setSampleRate(SourceHandler h, double sampleRate) => false;
  bool setGain(SourceHandler h, double gain) => false;
  bool setAgc(SourceHandler h, bool enabled) => false;

  /// Current gain/AGC in the UI's units, or null if unknown (reported in the DSP state so the
  /// UI adopts per-device persisted settings).
  double? gainOf(SourceHandler h) => null;
  bool? agcOf(SourceHandler h) => null;
}

/// Maps generic controls onto setting ids by convention: a `sampleRate` ChoiceSetting whose
/// options parse as numbers (Hz, or "x MSPS"), a `gain` SliderSetting, an `agc` BoolSetting.
/// Suitable for most sources; the integrator may provide device-specific subclasses.
class GenericSourceControls extends SourceControls {
  const GenericSourceControls({
    this.sampleRates = const <double>[],
    this.gainId = 'gain',
    this.agcId = 'agc',
  });
  final List<double> sampleRates;
  final String gainId;
  final String agcId;

  @override
  bool setSampleRate(SourceHandler h, double sampleRate) {
    if (sampleRates.isEmpty) return false;
    int best = 0;
    for (int i = 1; i < sampleRates.length; i++) {
      if ((sampleRates[i] - sampleRate).abs() <
          (sampleRates[best] - sampleRate).abs()) {
        best = i;
      }
    }
    h.applySetting('sampleRate', best);
    return true;
  }

  @override
  bool setGain(SourceHandler h, double gain) {
    if (!h.settings.any((s) => s.id == gainId)) return false;
    h.applySetting(gainId, gain);
    return true;
  }

  @override
  bool setAgc(SourceHandler h, bool enabled) {
    if (!h.settings.any((s) => s.id == agcId)) return false;
    h.applySetting(agcId, enabled);
    return true;
  }
}

/// A created source plus its metadata.
class SourceInstance {
  SourceInstance(
    this.handler, {
    this.controls = const SourceControls(),
    this.centerFrequencyLocked = false,
    this.fixedCenterFrequency,
    this.dispose,
    this.stats,
  });

  final SourceHandler handler;
  final SourceControls controls;

  /// File source: the centre frequency is fixed by the recording (C++
  /// `gui::waterfall.centerFrequencyLocked`).
  final bool centerFrequencyLocked;
  final double? fixedCenterFrequency;

  /// Releases resources (close file / device) when another source is selected.
  /// Awaited by the engine before the next source is created (a USB module must be done with
  /// its fd before a new device, possibly with the same fd number, is opened).
  final FutureOr<void> Function()? dispose;

  /// Extra source statistics merged into the DSP `stats` event (e.g. `droppedBuffers`).
  final Map<String, Object?> Function()? stats;
}

typedef SourceFactory = SourceInstance Function(
  Map<Object?, Object?> params,
  SourceContext ctx,
);

/// Top-level function run inside the DSP isolate to add sources (must be sendable:
/// a top-level or static function).
typedef SourceRegistryHook = void Function(SourceRegistry registry);

class SourceRegistry {
  final Map<String, SourceFactory> _factories = <String, SourceFactory>{};

  void register(String id, SourceFactory factory) {
    _factories[id] = factory;
  }

  bool contains(String id) => _factories.containsKey(id);
  Iterable<String> get ids => _factories.keys;

  SourceInstance create(
    String id,
    Map<Object?, Object?> params,
    SourceContext ctx,
  ) {
    final f = _factories[id];
    if (f == null) throw ArgumentError('Unknown source id: $id');
    return f(params, ctx);
  }

  /// Registry with the built-in sources.
  static SourceRegistry withBuiltins() {
    final r = SourceRegistry();
    r.register('synth', createSynth);
    r.register('file', createFile);
    return r;
  }

  static PumpMode _pumpMode(Object? v) => PumpMode.values.firstWhere(
    (m) => m.name == v,
    orElse: () => PumpMode.realTime,
  );

  /// params: sampleRate, centerFreq, noiseLevel, seed, pump ('realTime'|'asFastAsPossible'),
  /// carriers (list of maps, see [SynthCarrier.fromMap]; omitted = demo band).
  static SourceInstance createSynth(
    Map<Object?, Object?> p,
    SourceContext ctx,
  ) {
    final sr = (p['sampleRate'] as num?)?.toDouble() ?? 2400000;
    final center = (p['centerFreq'] as num?)?.toDouble() ?? 100e6;
    final carriers = p['carriers'] is List
        ? (p['carriers'] as List)
              .map((c) => SynthCarrier.fromMap(c as Map<Object?, Object?>))
              .toList()
        : null;
    final s = SynthSource(
      ctx.core,
      sampleRate: sr,
      centerFreq: center,
      noiseLevel: (p['noiseLevel'] as num?)?.toDouble() ?? 0.01,
      carriers: carriers,
      seed: (p['seed'] as num?)?.toInt() ?? 0x1234567,
      mode: _pumpMode(p['pump']),
    );
    return SourceInstance(
      s,
      controls: const _SynthControls(),
      dispose: s.pump.stop,
    );
  }

  /// params: path (required), format ('cf32'|'cu8'|'cs8'|'cs16'), sampleRate, centerFreq, pump.
  static SourceInstance createFile(Map<Object?, Object?> p, SourceContext ctx) {
    final path = p['path'];
    if (path is! String) throw ArgumentError('file source: missing path');
    final fmt = p['format'] is String
        ? IQFileFormat.parse(p['format'] as String)
        : null;
    final f = FileSource(
      ctx.core,
      path: path,
      format: fmt,
      sampleRate: (p['sampleRate'] as num?)?.toDouble() ?? 1000000,
      centerFreq: (p['centerFreq'] as num?)?.toDouble(),
      mode: _pumpMode(p['pump']),
    );
    return SourceInstance(
      f,
      centerFrequencyLocked: f.centerFreq != 0,
      fixedCenterFrequency: f.centerFreq,
      dispose: f.close,
    );
  }
}

class _SynthControls extends SourceControls {
  const _SynthControls();
  @override
  bool setSampleRate(SourceHandler h, double sampleRate) {
    (h as SynthSource).setSampleRate(math.max(1000, sampleRate));
    return true;
  }

  @override
  bool setGain(SourceHandler h, double gain) => true; // no gain stage
  @override
  bool setAgc(SourceHandler h, bool enabled) => true;
}

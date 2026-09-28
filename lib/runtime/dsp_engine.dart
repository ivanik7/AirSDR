// SPDX-License-Identifier: GPL-3.0-or-later
// The DSP engine hosted by the DSP isolate: Core + SignalPath + RadioModule "Radio" + the
// selected source + FFT row producer + audio output. It is isolate-agnostic (events go to an
// [emit] callback), so it can be unit-tested synchronously on the test isolate.
//
// Equivalent SDR++ pieces:
//  * main_window.cpp:676-692 setPlayState  → [start]/[stop]
//  * gui/tuner.cpp tune()                   → [tune] (policy is done by the UI, lib/ui/tuner.dart)
//  * WaterFall::pushFFT + doZoom            → [_releaseFFT] (zoomWindow + doZoom of
//    lib/ui/waterfall_math.dart, then one TransferableTypedData row per FFT frame)
//  * main.cpp module list                   → the radio module is created from a
//    RadioModuleFactory registered in the ModuleManager.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../sdrpp/core/config.dart';
import '../sdrpp/core/core.dart';
import '../sdrpp/modules/radio/radio_module.dart';
import '../sdrpp/signal_path/iq_frontend.dart';
import '../sdrpp/signal_path/source_handler.dart';
import '../ui/waterfall_math.dart' show doZoom;
import 'audio_output.dart';
import 'dsp_protocol.dart';
import 'source_registry.dart';

/// Engine construction options (sendable).
class DspEngineOptions {
  const DspEngineOptions({
    this.configDir,
    this.fftSize = 8192,
    this.fftRate = 20,
    this.audio = 'auto',
    this.statsInterval = const Duration(milliseconds: 500),
  });

  /// Directory for config.json / radio_config.json; null = in memory.
  final String? configDir;
  final int fftSize;
  final double fftRate;

  /// 'auto' (mp_audio_stream if loadable, else null), 'mp', 'null'.
  final String audio;
  final Duration statsInterval;
}

class DspEngine {
  DspEngine(this.emit, {this.options = const DspEngineOptions(), SourceRegistry? registry, AudioOutput? audioOutput})
      : registry = registry ?? SourceRegistry.withBuiltins() {
    final dir = options.configDir;
    coreConfig = ConfigManager();
    radioConfig = ConfigManager();
    if (dir != null) {
      coreConfig.setPath('$dir${Platform.pathSeparator}config.json');
      radioConfig.setPath('$dir${Platform.pathSeparator}radio_config.json');
    }
    coreConfig.load(<String, dynamic>{
      'frequency': 100000000.0,
      'fftSize': options.fftSize,
      'fftRate': options.fftRate,
      'vfoOffsets': <String, dynamic>{},
      'streams': <String, dynamic>{},
    });
    coreConfig.enableAutoSave();

    core = Core(configManager: coreConfig, log: _log);
    final fe = core.iqFrontEnd;
    fe.acquireFFTBuffer = _acquireFFT;
    fe.releaseFFTBuffer = _releaseFFT;
    fe.setFFTRate(options.fftRate);
    fe.setFFTSize(options.fftSize);
    core.onInputSampleRateChanged.bind((sr) {
      _viewOffset = 0;
      _viewBandwidth = sr;
      _sendState();
    });

    // Audio sink provider
    audio = audioOutput ?? _makeAudio(options.audio);
    core.sigpath.sinkManager.registerSinkProvider('Audio', AudioOutputSink.provider(audio));

    // Radio module
    radioFactory = RadioModuleFactory(core, config: radioConfig);
    core.moduleManager.loadModule(radioFactory);
    radioConfig.enableAutoSave();
    core.moduleManager.createInstance('Radio', 'radio');
    radio = core.moduleManager.instances['Radio']!.instance as RadioModule;
    if (core.sigpath.sinkManager.getStream('Radio')!.providerName == 'None') {
      core.sigpath.sinkManager.setStreamSink('Radio', 'Audio');
    }
    radio.stream.bindStream(_audioTapHandler);
    _ready = true;

    final vfoOffsets = coreConfig.conf['vfoOffsets'];
    if (vfoOffsets is Map && vfoOffsets['Radio'] is num) {
      radio.vfo?.setOffset((vfoOffsets['Radio'] as num).toDouble());
    }
    final f = coreConfig.conf['frequency'];
    _centerFreq = f is num ? f.toDouble() : 100e6;
    _viewBandwidth = fe.getEffectiveSamplerate();
  }

  final void Function(Map<String, Object?> msg) emit;
  final DspEngineOptions options;
  final SourceRegistry registry;

  late final ConfigManager coreConfig;
  late final ConfigManager radioConfig;
  late final Core core;
  late final AudioOutput audio;
  late final RadioModuleFactory radioFactory;
  late final RadioModule radio;

  SourceInstance? _source;
  String? _sourceId;
  bool _running = false;
  double _centerFreq = 100e6;

  // FFT output
  int _fftWidth = 1024;
  double _viewOffset = 0;
  double _viewBandwidth = 0;
  Float32List _fftRaw = Float32List(0);
  Float32List _row = Float32List(1024);
  int _fftSeq = 0;
  bool _fftWanted = false;

  // Audio tap
  bool _audioTap = false;

  Timer? _statsTimer;
  bool _closed = false;
  bool _ready = false;

  bool get running => _running;
  double get centerFrequency => _centerFreq;
  SourceInstance? get source => _source;
  int get fftRowsSent => _fftSeq;

  static AudioOutput _makeAudio(String kind) {
    if (kind == 'null') return NullAudioOutput();
    final mp = MpAudioStreamOutput.tryCreate();
    if (mp != null) return mp;
    return NullAudioOutput();
  }

  void _log(String m) {}

  SourceContext _ctx() => SourceContext(
        core: core,
        reportError: (m, {bool fatal = false}) {
          _error(m, fatal: fatal);
          if (fatal) scheduleMicrotask(_sourceStopped);
        },
        configLoad: (k) {
          final v = coreConfig.conf['sources'];
          if (v is Map && v[k] is Map) return Map<String, Object?>.from(v[k] as Map);
          return null;
        },
        configSave: (k, c) {
          coreConfig.acquire();
          coreConfig.obj('sources')[k] = c;
          coreConfig.release(true);
        },
      );

  /// The running source stopped itself (device lost): mirror stop() without calling into it.
  void _sourceStopped() {
    if (!_running) return;
    _running = false;
    _fftWanted = false;
    _statsTimer?.cancel();
    _statsTimer = null;
    core.iqFrontEnd.flushInputBuffer();
    _sendStats();
    _sendState();
  }

  void _error(String message, {bool fatal = false}) {
    emit(<String, Object?>{DspMsg.evt: DspEvt.error, 'message': message, 'fatal': fatal});
  }

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------

  /// Dispatches one UI message. Returns when the command is complete.
  Future<void> handle(Map<Object?, Object?> m) async {
    final cmd = m[DspMsg.cmd];
    final req = m[DspMsg.req];
    try {
      switch (cmd) {
        case DspCmd.selectSource:
          await selectSource(m['id'] as String, (m['params'] as Map?)?.cast<Object?, Object?>() ?? const {});
        case DspCmd.start:
          await start();
        case DspCmd.stop:
          await stop();
        case DspCmd.tune:
          tune(center: (m['center'] as num?)?.toDouble(), offset: (m['offset'] as num?)?.toDouble());
        case DspCmd.setMode:
          setMode((m['mode'] as num).toInt());
        case DspCmd.setBandwidth:
          radio.setBandwidth((m['hz'] as num).toDouble());
          _sendState();
        case DspCmd.setSampleRate:
          _withSource((s) => s.controls.setSampleRate(s.handler, (m['hz'] as num).toDouble()));
          _sendState();
        case DspCmd.setGain:
          _withSource((s) => s.controls.setGain(s.handler, (m['value'] as num).toDouble()));
          _sendState();
        case DspCmd.setAgc:
          _withSource((s) => s.controls.setAgc(s.handler, m['enabled'] as bool));
          _sendState();
        case DspCmd.sourceSetting:
          _withSource((s) {
            s.handler.applySetting(m['id'] as String, m['value']!);
            return true;
          });
          _sendState();
        case DspCmd.setVolume:
          core.sigpath.sinkManager.setStreamVolume('Radio', (m['value'] as num).toDouble());
        case DspCmd.setSquelch:
          setSquelch(enabled: m['enabled'] as bool?, level: (m['level'] as num?)?.toDouble());
        case DspCmd.demodOption:
          radio.selectedDemod?.setOption(m['key'] as String, m['value']!);
          _sendState();
        case DspCmd.setFft:
          setFft(
              width: (m['width'] as num?)?.toInt(),
              viewOffset: (m['viewOffset'] as num?)?.toDouble(),
              viewBandwidth: (m['viewBandwidth'] as num?)?.toDouble(),
              size: (m['size'] as num?)?.toInt(),
              rate: (m['rate'] as num?)?.toDouble(),
              window: m['window'] as String?);
        case DspCmd.audioTap:
          _audioTap = m['enabled'] == true;
        case DspCmd.getState:
          _sendState();
        case DspCmd.shutdown:
          await shutdown();
        default:
          throw ArgumentError('unknown command $cmd');
      }
      if (req != null) emit(<String, Object?>{DspMsg.evt: DspEvt.ack, DspMsg.req: req, 'ok': true});
    } catch (e) {
      if (req != null) {
        emit(<String, Object?>{DspMsg.evt: DspEvt.ack, DspMsg.req: req, 'ok': false, 'error': '$e'});
      } else {
        _error('$cmd: $e');
      }
    }
  }

  void _withSource(bool Function(SourceInstance s) f) {
    final s = _source;
    if (s != null) f(s);
  }

  Future<void> selectSource(String id, Map<Object?, Object?> params) async {
    final wasRunning = _running;
    if (_running) await stop();
    final old = _source;
    if (old != null) {
      core.sigpath.sourceManager.unregisterSource(_sourceId!);
      old.dispose?.call();
      _source = null;
      _sourceId = null;
    }
    final inst = registry.create(id, params, _ctx());
    _source = inst;
    _sourceId = id;
    core.sigpath.sourceManager.registerSource(id, inst.handler);
    core.sigpath.sourceManager.selectSource(id); // → setInputSampleRate
    if (inst.centerFrequencyLocked && inst.fixedCenterFrequency != null) {
      _centerFreq = inst.fixedCenterFrequency!;
    }
    _sendState();
    if (wasRunning) await start();
  }

  /// main_window.cpp:676-692.
  Future<void> start() async {
    if (_running) return;
    if (_source == null) throw StateError('No source selected');
    core.iqFrontEnd.flushInputBuffer();
    try {
      await core.sigpath.sourceManager.start();
    } catch (e) {
      _error('Source start failed: $e');
      _sendState();
      rethrow;
    }
    core.sigpath.sourceManager.tune(_centerFreq);
    _running = true;
    _fftWanted = true;
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(options.statsInterval, (_) => _sendStats());
    _sendState();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _fftWanted = false;
    _statsTimer?.cancel();
    _statsTimer = null;
    await core.sigpath.sourceManager.stop();
    core.iqFrontEnd.flushInputBuffer();
    _sendStats();
    _sendState();
  }

  void tune({double? center, double? offset}) {
    final locked = _source?.centerFrequencyLocked ?? false;
    if (center != null && center != _centerFreq && !locked) {
      _centerFreq = center;
      core.sigpath.sourceManager.tune(center);
      coreConfig.acquire();
      coreConfig.conf['frequency'] = center;
      coreConfig.release(true);
    }
    if (offset != null) {
      radio.vfo?.setOffset(offset);
      coreConfig.acquire();
      coreConfig.obj('vfoOffsets')['Radio'] = offset;
      coreConfig.release(true);
    }
  }

  void setMode(int modeId) {
    final id = DemodID.fromId(modeId);
    if (id == null) throw ArgumentError('bad mode $modeId');
    radio.selectDemodByID(id);
    _sendState();
  }

  void setSquelch({bool? enabled, double? level}) {
    if (enabled != null) radio.setSquelchMode(enabled ? SquelchMode.power : SquelchMode.off);
    if (level != null) radio.setSquelchLevel(level);
  }

  void setFft({int? width, double? viewOffset, double? viewBandwidth, int? size, double? rate, String? window}) {
    if (width != null && width > 0) {
      _fftWidth = width;
      if (_row.length != width) _row = Float32List(width);
    }
    if (viewOffset != null) _viewOffset = viewOffset;
    if (viewBandwidth != null && viewBandwidth > 0) _viewBandwidth = viewBandwidth;
    final fe = core.iqFrontEnd;
    if (size != null && size != fe.fftSize && size >= 64) fe.setFFTSize(size);
    if (rate != null && rate != fe.fftRate && rate > 0) fe.setFFTRate(rate);
    if (window != null) {
      final w = FFTWindow.values.where((e) => e.name == window).firstOrNull;
      if (w != null && w != fe.fftWindow) fe.setFFTWindow(w);
    }
  }

  Future<void> shutdown() async {
    if (_closed) return;
    await stop();
    _source?.dispose?.call();
    _closed = true;
    core.moduleManager.endAll(); // radio: disableAutoSave + save
    coreConfig.disableAutoSave();
    coreConfig.flush();
    audio.close();
  }

  // ---------------------------------------------------------------------------
  // FFT rows
  // ---------------------------------------------------------------------------

  Float32List? _acquireFFT(int fftSize) {
    if (!_fftWanted || _fftWidth <= 0) return null;
    if (_fftRaw.length != fftSize) _fftRaw = Float32List(fftSize);
    return _fftRaw;
  }

  /// WaterFall::pushFFT (waterfall.cpp:880-905) on the DSP side: visible window + doZoom.
  void _releaseFFT(int fftSize) {
    if (!_fftWanted || _fftWidth <= 0 || _fftRaw.length != fftSize) return;
    final sr = core.iqFrontEnd.getEffectiveSamplerate();
    final (low, high) = computeRow(_fftRaw, fftSize, sr, _viewOffset, _viewBandwidth, _row);
    _fftSeq++;
    emit(<String, Object?>{
      DspMsg.evt: DspEvt.fft,
      'data': TransferableTypedData.fromList(<TypedData>[_row]),
      'low': _centerFreq + low,
      'high': _centerFreq + high,
      'seq': _fftSeq,
    });
  }

  /// Decimates the visible part of a full-band dB row ([raw], [fftSize] bins covering
  /// [-sr/2, sr/2)) into [out]. Returns the covered (low, high) offsets from the LO.
  static (double, double) computeRow(
      Float32List raw, int fftSize, double sr, double viewOffset, double viewBandwidth, Float32List out) {
    // zoomWindow (waterfall.cpp:887-889), clamped to the band instead of doZoom's hack.
    final vbw = math.min(viewBandwidth, sr);
    final offsetRatio = viewOffset / (sr / 2.0);
    int size = ((vbw / sr) * fftSize).toInt();
    if (size < 1) size = 1;
    int start = (((fftSize / 2.0) * (offsetRatio + 1)) - (size ~/ 2)).toInt();
    if (start < 0) start = 0;
    if (start + size > fftSize) start = fftSize - size;
    doZoom(start, size, fftSize, out.length, raw, out);
    final binW = sr / fftSize;
    final low = -sr / 2.0 + start * binW;
    return (low, low + size * binW);
  }

  // ---------------------------------------------------------------------------
  // Audio tap / stats / state
  // ---------------------------------------------------------------------------

  void _audioTapHandler(Float32List data, int count) {
    if (!_audioTap) return;
    emit(<String, Object?>{
      DspMsg.evt: DspEvt.audio,
      'data': TransferableTypedData.fromList(<TypedData>[Float32List.sublistView(data, 0, 2 * count)]),
      'frames': count,
    });
  }

  Map<String, Object?> statsMap() => <String, Object?>{
        'samplesIn': core.iqFrontEnd.samplesIn,
        'audioFrames': radio.audioFrames,
        'fftRows': _fftSeq,
        'audioWritten': audio.framesWritten,
        'audioDropped': audio.framesDropped,
        'audioOutput': audio.name,
        ...?_source?.stats?.call(),
      };

  void _sendStats() {
    emit(<String, Object?>{DspMsg.evt: DspEvt.stats, ...statsMap()});
  }

  Map<String, Object?> stateMap() {
    final src = _source;
    return <String, Object?>{
      'running': _running,
      'sourceId': _sourceId,
      'sampleRate': core.iqFrontEnd.getEffectiveSamplerate(),
      'centerFreq': _centerFreq,
      'centerLocked': src?.centerFrequencyLocked ?? false,
      'vfoOffset': radio.vfo?.getOffset() ?? 0.0,
      'vfoCenterOffset': radio.vfo?.centerOffset ?? 0.0,
      'mode': radio.selectedDemodID,
      'bandwidth': radio.bandwidth,
      'minBandwidth': radio.minBandwidth,
      'maxBandwidth': radio.maxBandwidth,
      'squelchEnabled': radio.squelchMode == SquelchMode.power,
      'squelchLevel': radio.squelchLevel,
      'volume': radio.stream.getVolume(),
      'fftSize': core.iqFrontEnd.fftSize,
      'fftRate': core.iqFrontEnd.fftRate,
      'demodOptions': <String, Object?>{for (final o in radio.selectedDemod?.options ?? const <DemodOption>[]) o.key: o.value},
      'sourceSettings': src == null ? const <Object?>[] : src.handler.settings.map(settingToMap).toList(),
      'gain': src?.controls.gainOf(src.handler),
      'agc': src?.controls.agcOf(src.handler),
    };
  }

  static Map<String, Object?> settingToMap(SourceSetting s) => switch (s) {
        ChoiceSetting c => <String, Object?>{
            'type': 'choice',
            'id': c.id,
            'label': c.label,
            'options': c.options,
            'selected': c.selected
          },
        SliderSetting sl => <String, Object?>{
            'type': 'slider',
            'id': sl.id,
            'label': sl.label,
            'min': sl.min,
            'max': sl.max,
            'step': sl.step,
            'value': sl.value
          },
        BoolSetting b => <String, Object?>{'type': 'bool', 'id': b.id, 'label': b.label, 'value': b.value},
      };

  void _sendState() {
    if (_closed || !_ready) return;
    emit(<String, Object?>{DspMsg.evt: DspEvt.state, ...stateMap()});
  }
}

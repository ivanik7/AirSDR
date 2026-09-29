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
import 'link_tone.dart';
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
  DspEngine(
    this.emit, {
    this.options = const DspEngineOptions(),
    SourceRegistry? registry,
    AudioOutput? audioOutput,
  }) : registry = registry ?? SourceRegistry.withBuiltins() {
    final dir = options.configDir;
    coreConfig = ConfigManager();
    radioConfig = ConfigManager();
    // RadioModuleFactory.init() calls radioConfig.setPath(configPath), so the
    // radio config path must be passed to the factory (setting it here alone
    // was overwritten with null → mode/bandwidth/squelch never persisted).
    final radioConfigPath = dir == null
        ? null
        : '$dir${Platform.pathSeparator}radio_config.json';
    if (dir != null) {
      coreConfig.setPath('$dir${Platform.pathSeparator}config.json');
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

    // Delay registering the native sink: RadioModule starts its stream in its
    // constructor. It must see only the None sink until we stop it below, otherwise
    // Android opens AAudio briefly before the cold-start mute takes effect.
    audio = audioOutput ?? _makeAudio(options.audio);

    // Radio module
    radioFactory = RadioModuleFactory(
      core,
      config: radioConfig,
      configPath: radioConfigPath,
    );
    core.moduleManager.loadModule(radioFactory);
    radioConfig.enableAutoSave();
    core.moduleManager.createInstance('Radio', 'radio');
    radio = core.moduleManager.instances['Radio']!.instance as RadioModule;
    core.sigpath.sinkManager.stopStream('Radio');
    core.sigpath.sinkManager.registerSinkProvider(
      'Audio',
      AudioOutputSink.provider(audio),
    );
    if (core.sigpath.sinkManager.getStream('Radio')!.providerName == 'None') {
      core.sigpath.sinkManager.setStreamSink('Radio', 'Audio');
    }
    // Every session starts muted: a persisted `muted: false` is deliberately not restored.
    core.sigpath.sinkManager.getStream('Radio')?.setMuted(true);
    _updateAudio();
    radio.stream.bindStream(_audioTapHandler);
    // Auto squelch open/close reaches the UI at once, not only with the periodic stats.
    radio.autoSquelch.onChange = (_) {
      if (_running) _sendStats();
    };
    _ready = true;

    final vfoOffsets = coreConfig.conf['vfoOffsets'];
    final savedOffset = vfoOffsets is Map && vfoOffsets['Radio'] is num
        ? (vfoOffsets['Radio'] as num).toDouble()
        : 0.0;
    final f = coreConfig.conf['frequency'];
    // Migrate old offset-based sessions to the centered single-VFO UI: preserve
    // the tuned frequency, not the old LO position. Do this before any USB source
    // selection (selectSource can reset the VFO's offset in SourceManager).
    _centerFreq = (f is num ? f.toDouble() : 100e6) + savedOffset;
    radio.vfo?.setOffset(0);
    if (savedOffset != 0) {
      coreConfig.acquire();
      coreConfig.conf['frequency'] = _centerFreq;
      coreConfig.obj('vfoOffsets')['Radio'] = 0.0;
      coreConfig.release(true);
    }
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
  int _sourceGen = 0; // bumped per created source: late errors of a replaced source are ignored
  bool _running = false;
  bool _muted = true;
  bool _lostWhileRunning = false;
  final LinkTone _linkTone = LinkTone();
  int _linkBeepCount = 0;
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
  bool get muted => _muted;
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

  SourceContext _ctx(int gen) => SourceContext(
    core: core,
    reportError: (m, {bool fatal = false}) {
      if (gen != _sourceGen) {
        return; // a released/replaced source (e.g. the lost dongle)
      }
      _error(m, fatal: fatal);
      if (fatal) scheduleMicrotask(_sourceStopped);
    },
    configLoad: (k) {
      final v = coreConfig.conf['sources'];
      if (v is Map && v[k] is Map) {
        return Map<String, Object?>.from(v[k] as Map);
      }
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
    _lostWhileRunning = _sourceId == 'usb';
    _running = false;
    _updateAudio();
    _fftWanted = false;
    _statsTimer?.cancel();
    _statsTimer = null;
    core.iqFrontEnd.flushInputBuffer();
    _sendStats();
    _sendState();
  }

  /// The Android playback device is held only while a source runs AND the user unmuted
  /// (docs/device-qa.md: AAudio must not stay `started` while idle or silent).
  void _updateAudio() {
    final sm = core.sigpath.sinkManager;
    if (_running && !_muted) {
      sm.startStream('Radio');
    } else {
      sm.stopStream('Radio');
    }
  }

  void setMuted(bool muted) {
    _muted = muted;
    core.sigpath.sinkManager.getStream('Radio')?.setMuted(muted);
    _updateAudio();
    _sendState();
  }

  void _error(String message, {bool fatal = false}) {
    emit(<String, Object?>{
      DspMsg.evt: DspEvt.error,
      'message': message,
      'fatal': fatal,
    });
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
          await selectSource(
            m['id'] as String,
            (m['params'] as Map?)?.cast<Object?, Object?>() ?? const {},
          );
        case DspCmd.start:
          await start(reconnected: m['reconnected'] == true);
        case DspCmd.stop:
          await stop();
        case DspCmd.tune:
          tune(
            center: (m['center'] as num?)?.toDouble(),
            offset: (m['offset'] as num?)?.toDouble(),
          );
        case DspCmd.setMode:
          setMode((m['mode'] as num).toInt());
        case DspCmd.setBandwidth:
          _floorCache.clear();
          radio.setBandwidth((m['hz'] as num).toDouble());
          _sendState();
        case DspCmd.setSampleRate:
          _floorCache.clear();
          _withSource(
            (s) => s.controls.setSampleRate(
              s.handler,
              (m['hz'] as num).toDouble(),
            ),
          );
          radio.resetAutoSquelch();
          _sendState();
        case DspCmd.setGain:
          _floorCache.clear();
          _withSource(
            (s) =>
                s.controls.setGain(s.handler, (m['value'] as num).toDouble()),
          );
          // The noise floor moved with the gain: the level squelch relearns it.
          radio.resetAutoSquelch();
          _sendState();
        case DspCmd.setAgc:
          _floorCache.clear();
          _withSource(
            (s) => s.controls.setAgc(s.handler, m['enabled'] as bool),
          );
          radio.resetAutoSquelch();
          _sendState();
        case DspCmd.sourceSetting:
          _floorCache.clear();
          _withSource((s) {
            s.handler.applySetting(m['id'] as String, m['value']!);
            return true;
          });
          radio.resetAutoSquelch();
          _sendState();
        case DspCmd.setVolume:
          core.sigpath.sinkManager.setStreamVolume(
            'Radio',
            (m['value'] as num).toDouble(),
          );
        case DspCmd.setMuted:
          setMuted(m['muted'] == true);
        case DspCmd.releaseSource:
          await releaseSource(deviceLost: m['deviceLost'] == true);
        case DspCmd.setSquelch:
          setSquelch(
            enabled: m['enabled'] as bool?,
            level: (m['level'] as num?)?.toDouble(),
            mode: m['mode'] as String?,
            autoOffset: (m['autoOffset'] as num?)?.toDouble(),
          );
          _sendState();
        case DspCmd.demodOption:
          radio.selectedDemod?.setOption(m['key'] as String, m['value']!);
          _sendState();
        case DspCmd.setFft:
          setFft(
            enabled: m['enabled'] as bool?,
            width: (m['width'] as num?)?.toInt(),
            viewOffset: (m['viewOffset'] as num?)?.toDouble(),
            viewBandwidth: (m['viewBandwidth'] as num?)?.toDouble(),
            size: (m['size'] as num?)?.toInt(),
            rate: (m['rate'] as num?)?.toDouble(),
            window: m['window'] as String?,
          );
        case DspCmd.audioTap:
          _audioTap = m['enabled'] == true;
        case DspCmd.getState:
          _sendState();
        case DspCmd.shutdown:
          await shutdown();
        default:
          throw ArgumentError('unknown command $cmd');
      }
      if (req != null) {
        emit(<String, Object?>{
          DspMsg.evt: DspEvt.ack,
          DspMsg.req: req,
          'ok': true,
        });
      }
    } catch (e) {
      if (req != null) {
        emit(<String, Object?>{
          DspMsg.evt: DspEvt.ack,
          DspMsg.req: req,
          'ok': false,
          'error': '$e',
        });
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
    _floorCache.clear();
    final wasRunning = _running;
    await _dropSource();
    final inst = registry.create(id, params, _ctx(++_sourceGen));
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

  /// Stops (if needed) and disposes the current source; the engine then has no source.
  Future<void> releaseSource({bool deviceLost = false}) async {
    // Only a running hardware source can have been unplugged. A second release after
    // ENODEV + Android's detach broadcast sees no source and cannot sound twice.
    final beep =
        deviceLost &&
        _sourceId == 'usb' &&
        !_muted &&
        (_running || _lostWhileRunning);
    _lostWhileRunning = false;
    if (beep) {
      // The source can no longer feed audio. Stop its stream, queue the earcon on the
      // same output, then let miniaudio drain it before releasing AAudio and the fd.
      if (_running) {
        await stop();
      } else {
        _updateAudio(); // fatal source loss already stopped the source
      }
      if (audio.open(LinkTone.sampleRate)) {
        if (_linkTone.play(
          audio,
          LinkToneKind.disconnected,
          radio.stream.getVolume(),
        )) {
          _linkBeepCount++;
        }
        // mp_audio_stream buffers 60 ms of pre-roll plus the 120 ms tone.
        await Future<void>.delayed(const Duration(milliseconds: 240));
        audio.close();
      }
    }
    await _dropSource();
    _sendState();
    _sendStats();
  }

  Future<void> _dropSource() async {
    if (_running) await stop();
    final old = _source;
    if (old == null) return;
    _sourceGen++;
    core.sigpath.sourceManager.unregisterSource(_sourceId!);
    _source = null;
    _sourceId = null;
    try {
      await old.dispose?.call();
    } catch (e) {
      _error('Source dispose failed: $e');
    }
  }

  /// main_window.cpp:676-692.
  Future<void> start({bool reconnected = false}) async {
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
    radio.resetAutoSquelch();
    _running = true;
    _updateAudio();
    _lostWhileRunning = false;
    if (reconnected &&
        _sourceId == 'usb' &&
        !_muted &&
        _linkTone.play(
          audio,
          LinkToneKind.reconnected,
          radio.stream.getVolume(),
        )) {
      _linkBeepCount++;
    }
    _fftWanted = core.iqFrontEnd.fftEnabled;
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
    // Audio first: a source whose device vanished may throw from stop().
    _updateAudio();
    try {
      await core.sigpath.sourceManager.stop();
    } catch (e) {
      _error('Source stop failed: $e');
    }
    core.iqFrontEnd.flushInputBuffer();
    _sendStats();
    _sendState();
  }

  void tune({double? center, double? offset}) {
    final locked = _source?.centerFrequencyLocked ?? false;
    var retuned = false;
    var centerChanged = false;
    if (center != null && center != _centerFreq && !locked) {
      _rememberFloor();
      centerChanged = true;
      _centerFreq = center;
      core.sigpath.sourceManager.tune(center);
      coreConfig.acquire();
      coreConfig.conf['frequency'] = center;
      coreConfig.release(true);
      retuned = true;
    }
    if (offset != null) {
      retuned |= offset != radio.vfo?.getOffset();
      radio.vfo?.setOffset(offset);
      coreConfig.acquire();
      coreConfig.obj('vfoOffsets')['Radio'] = offset;
      coreConfig.release(true);
    }
    // New channel: the auto squelch relearns (level squelch: noise floor of the new channel).
    if (retuned) {
      _squelchEpoch++;
      radio.resetAutoSquelch();
      if (centerChanged) _restoreFloor();
    }
  }

  int _squelchEpoch = 0;
  final Map<(int, int, double), List<double>> _floorCache = {};

  (int, int, double) get _floorKey =>
      (_centerFreq.round(), radio.selectedDemodID, radio.bandwidth);

  void _rememberFloor() {
    final floor = radio.autoSquelch.floorSnapshot;
    if (floor.isEmpty) return;
    if (_floorCache.length >= 256 && !_floorCache.containsKey(_floorKey)) {
      _floorCache.remove(_floorCache.keys.first);
    }
    _floorCache[_floorKey] = floor;
  }

  void _restoreFloor() {
    final floor = _floorCache[_floorKey];
    if (floor != null) radio.autoSquelch.restoreFloor(floor);
  }

  void setMode(int modeId) {
    final id = DemodID.fromId(modeId);
    if (id == null) throw ArgumentError('bad mode $modeId');
    _rememberFloor();
    _squelchEpoch++;
    radio.selectDemodByID(id);
    _restoreFloor();
    _sendState();
  }

  void setSquelch({
    bool? enabled,
    double? level,
    String? mode,
    double? autoOffset,
  }) {
    final m = mode == null ? null : squelchModeKeys[mode];
    if (m != null) {
      radio.setSquelchMode(m);
      if (m == SquelchMode.auto) _restoreFloor();
    } else if (enabled != null) {
      radio.setSquelchMode(enabled ? SquelchMode.power : SquelchMode.off);
    }
    if (level != null) radio.setSquelchLevel(level);
    if (autoOffset != null) radio.setAutoSquelchOffset(autoOffset);
  }

  /// Live auto squelch status for the UI (null unless the auto squelch is active).
  Map<String, Object?>? squelchStatus() {
    if (radio.squelchMode != SquelchMode.auto) return null;
    final a = radio.autoSquelch;
    return <String, Object?>{
      'open': a.open,
      'metric': a.metricDb,
      'threshold': a.thresholdDb,
      'detector': a.detector.name,
    };
  }

  void setFft({
    bool? enabled,
    int? width,
    double? viewOffset,
    double? viewBandwidth,
    int? size,
    double? rate,
    String? window,
  }) {
    if (enabled != null) {
      core.iqFrontEnd.fftEnabled = enabled;
      _fftWanted = enabled && _running;
    }
    if (width != null && width > 0) {
      _fftWidth = width;
      if (_row.length != width) _row = Float32List(width);
    }
    if (viewOffset != null) _viewOffset = viewOffset;
    if (viewBandwidth != null && viewBandwidth > 0) {
      _viewBandwidth = viewBandwidth;
    }
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
    try {
      await _source?.dispose?.call();
    } catch (_) {}
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
    final (low, high) = computeRow(
      _fftRaw,
      fftSize,
      sr,
      _viewOffset,
      _viewBandwidth,
      _row,
    );
    _fftSeq++;
    emit(<String, Object?>{
      DspMsg.evt: DspEvt.fft,
      'data': TransferableTypedData.fromList(<TypedData>[_row]),
      'low': _centerFreq + low,
      'high': _centerFreq + high,
      'seq': _fftSeq,
      'center': _centerFreq,
      'epoch': _squelchEpoch,
    });
  }

  /// Decimates the visible part of a full-band dB row ([raw], [fftSize] bins covering
  /// [-sr/2, sr/2)) into [out]. Returns the covered (low, high) offsets from the LO.
  static (double, double) computeRow(
    Float32List raw,
    int fftSize,
    double sr,
    double viewOffset,
    double viewBandwidth,
    Float32List out,
  ) {
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
      'data': TransferableTypedData.fromList(<TypedData>[
        Float32List.sublistView(data, 0, 2 * count),
      ]),
      'frames': count,
    });
  }

  Map<String, Object?> statsMap() => <String, Object?>{
    'linkBeeps': _linkBeepCount,
    'samplesIn': core.iqFrontEnd.samplesIn,
    'audioFrames': radio.audioFrames,
    'fftRows': _fftSeq,
    'audioWritten': audio.framesWritten,
    'audioDropped': audio.framesDropped,
    'audioOutput': audio.name,
    'squelch': ?squelchStatus(),
    'squelchCenter': _centerFreq,
    'squelchModeId': radio.selectedDemodID,
    'squelchEpoch': _squelchEpoch,
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
      // App extension (auto squelch): the mode key of squelchModeKeys, the threshold offset
      // and whether the current demodulator has an automatic detector.
      'squelchMode': _squelchModeKey(radio.squelchMode),
      'squelchAutoOffset': radio.autoSquelchOffset,
      'squelchAutoAllowed': radio.autoSquelchAllowed,
      'volume': radio.stream.getVolume(),
      'muted': _muted,
      'fftSize': core.iqFrontEnd.fftSize,
      'fftRate': core.iqFrontEnd.fftRate,
      'demodOptions': <String, Object?>{
        for (final o in radio.selectedDemod?.options ?? const <DemodOption>[])
          o.key: o.value,
      },
      'sourceSettings': src == null
          ? const <Object?>[]
          : src.handler.settings.map(settingToMap).toList(),
      'gain': src?.controls.gainOf(src.handler),
      'agc': src?.controls.agcOf(src.handler),
    };
  }

  static String _squelchModeKey(SquelchMode m) =>
      squelchModeKeys.entries
          .where((e) => e.value == m)
          .map((e) => e.key)
          .firstOrNull ??
      'off';

  static Map<String, Object?> settingToMap(SourceSetting s) => switch (s) {
    ChoiceSetting c => <String, Object?>{
      'type': 'choice',
      'id': c.id,
      'label': c.label,
      'options': c.options,
      'selected': c.selected,
    },
    SliderSetting sl => <String, Object?>{
      'type': 'slider',
      'id': sl.id,
      'label': sl.label,
      'min': sl.min,
      'max': sl.max,
      'step': sl.step,
      'value': sl.value,
    },
    BoolSetting b => <String, Object?>{
      'type': 'bool',
      'id': b.id,
      'label': b.label,
      'value': b.value,
    },
  };

  void _sendState() {
    if (_closed || !_ready) return;
    emit(<String, Object?>{DspMsg.evt: DspEvt.state, ...stateMap()});
  }
}

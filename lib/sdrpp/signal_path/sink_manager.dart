// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/signal_path/sink.h (lines 1-131) and sink.cpp (lines 1-389) @8c9f5ee,
// without the ImGui menu/volume-slider code.
//
// `SinkManager::Stream` (one per radio instance):
//   _in ─► Splitter<stereo_t> ─► volumeInput ─► Volume(vol², mute) ─► sinkOut ─► Sink (provider)
//                           └─► extra bound streams (recorders, …)
// In the synchronous Dart graph the producer calls [SinkStream.process] once per audio block;
// the splitter becomes a list of bound callbacks and `sinkOut` becomes a call to
// [Sink.write]. Sinks must not block: an output device that is full drops the block
// (the C++ Android sink blocks for ≤ 100 ms instead, android_audio_sink/src/main.cpp).
import 'dart:typed_data';

import '../core/config.dart';
import '../core/event.dart';
import '../dsp/dsp.dart';

/// Receives stereo audio: [count] frames interleaved l/r in [data] (valid only during the call).
typedef StereoHandler = void Function(Float32List data, int count);

/// `SinkManager::Sink` (sink.h:17-23). [write] replaces reading `stream->sinkOut`.
abstract class Sink {
  void start();
  void stop();

  /// Audio produced by the stream (after volume). [count] stereo frames.
  void write(Float32List data, int count);

  /// Releases resources (C++ destructor).
  void dispose() {}
}

/// `SinkManager::SinkProvider` (sink.h:68-71): `create(stream, streamName, ctx)`.
typedef SinkProvider = Sink Function(SinkStream stream, String streamName);

/// `SinkManager::NullSink` (sink.h:73-89): discards audio, runs the stream at 48 kHz.
class NullSink extends Sink {
  NullSink(SinkStream stream);

  /// Frames discarded (diagnostics).
  int frames = 0;

  static Sink create(SinkStream stream, String streamName) {
    stream.setSampleRate(48000);
    return NullSink(stream);
  }

  @override
  void start() {}
  @override
  void stop() {}
  @override
  void write(Float32List data, int count) {
    frames += count;
  }
}

/// `SinkManager::Stream` (sink.h:25-66, sink.cpp:21-86).
class SinkStream {
  /// sink.cpp:17-19 / :21-29 `init(in, srChangeHandler, sampleRate)`.
  SinkStream([EventHandler<double>? srChangeHandler, double sampleRate = 48000]) {
    if (srChangeHandler != null) srChange.bindHandler(srChangeHandler);
    _sampleRate = sampleRate;
  }

  final Volume volumeAjust = Volume(1.0, false);
  Sink? _sink;
  late double _sampleRate;
  int providerId = 0;
  String providerName = '';
  bool running = false;
  double guiVolume = 1.0;

  final List<StereoHandler> _bound = <StereoHandler>[];
  Float32List _volBuf = Float32List(0);

  /// sink.h:51.
  final Event<double> srChange = Event<double>();

  Sink? get sink => _sink;

  /// sink.cpp:31-40.
  void start() {
    if (running) {
      return;
    }
    _sink?.start();
    running = true;
  }

  /// sink.cpp:42-50.
  void stop() {
    if (!running) {
      return;
    }
    _sink?.stop();
    running = false;
  }

  /// sink.cpp:52-55.
  void setVolume(double volume) {
    guiVolume = volume;
    volumeAjust.setVolume(volume);
  }

  /// sink.cpp:57.
  double getVolume() => guiVolume;

  void setMuted(bool muted) => volumeAjust.setMuted(muted);
  bool getMuted() => volumeAjust.getMuted();

  /// sink.cpp:61.
  double getSampleRate() => _sampleRate;

  /// sink.cpp:82-86: emits srChange (the radio reconfigures its AF chain).
  void setSampleRate(double sampleRate) {
    _sampleRate = sampleRate;
    srChange.emit(sampleRate);
  }

  /// sink.cpp:71 — binds an extra consumer of the pre-volume audio (splitter output).
  StereoHandler bindStream(StereoHandler stream) {
    _bound.add(stream);
    return stream;
  }

  /// sink.cpp:77.
  void unbindStream(StereoHandler stream) {
    _bound.remove(stream);
  }

  /// One block of stereo audio from the radio's AF chain (the C++ `_in` stream).
  void process(Float32List data, int count) {
    if (count <= 0) return;
    // Splitter
    for (int i = 0; i < _bound.length; i++) {
      _bound[i](data, count);
    }
    if (!running) return;
    final s = _sink;
    if (s == null) return;
    // Volume (out of place: `data` belongs to the producer and is shared with the splitter)
    if (_volBuf.length < 2 * count) _volBuf = growBuffer(_volBuf, 2 * count, 0);
    volumeAjust.process(count, data, _volBuf);
    s.write(_volBuf, count);
  }
}

/// `SinkManager` (sink.cpp:10-389).
class SinkManager {
  /// sink.cpp:10-15: registers the "None" provider. [config] is the core config
  /// (C++ `core::configManager`, key `streams`).
  SinkManager([this.config, void Function(String message)? log]) : _log = log ?? ((_) {}) {
    registerSinkProvider('None', NullSink.create);
  }

  final ConfigManager? config;
  final void Function(String message) _log;

  final Map<String, SinkProvider> _providers = <String, SinkProvider>{};
  final Map<String, SinkStream> _streams = <String, SinkStream>{};
  final List<String> providerNames = <String>[];
  final List<String> _streamNames = <String>[];

  final Event<String> onSinkProviderRegistered = Event<String>();
  final Event<String> onSinkProviderUnregister = Event<String>();
  final Event<String> onSinkProviderUnregistered = Event<String>();
  final Event<String> onStreamRegistered = Event<String>();
  final Event<String> onStreamUnregister = Event<String>();
  final Event<String> onStreamUnregistered = Event<String>();

  /// sink.cpp:88-107.
  void registerSinkProvider(String name, SinkProvider provider) {
    if (_providers.containsKey(name)) {
      _log("Cannot register sink provider '$name', this name is already taken");
      return;
    }
    _providers[name] = provider;
    providerNames.add(name);
    for (final stream in _streams.values) {
      stream.providerId = providerNames.indexOf(stream.providerName);
    }
    onSinkProviderRegistered.emit(name);
  }

  /// sink.cpp:109-136.
  void unregisterSinkProvider(String name) {
    if (!_providers.containsKey(name)) {
      _log("Cannot unregister sink provider '$name', no such provider exists.");
      return;
    }
    onSinkProviderUnregister.emit(name);
    for (final e in _streams.entries.toList()) {
      if (e.value.providerName != name) continue;
      setStreamSink(e.key, 'None');
    }
    _providers.remove(name);
    providerNames.remove(name);
    for (final stream in _streams.values) {
      stream.providerId = providerNames.indexOf(stream.providerName);
    }
    onSinkProviderUnregistered.emit(name);
  }

  /// sink.cpp:138-162.
  void registerStream(String name, SinkStream stream) {
    if (_streams.containsKey(name)) {
      _log("Cannot register stream '$name', this name is already taken");
      return;
    }
    final provider = _providers['None']!;
    stream._sink = provider(stream, name);
    stream.providerId = providerNames.indexOf('None');
    stream.providerName = 'None';

    _streams[name] = stream;
    _streamNames.add(name);

    // Load config
    final streamsConf = config?.conf['streams'];
    final available = streamsConf is Map && streamsConf.containsKey(name);
    if (available) {
      _loadStreamConfig(name);
    }
    onStreamRegistered.emit(name);
  }

  /// sink.cpp:164-176.
  void unregisterStream(String name) {
    final stream = _streams[name];
    if (stream == null) {
      _log("Cannot unregister stream '$name', this stream doesn't exist");
      return;
    }
    onStreamUnregister.emit(name);
    stream.stop();
    stream._sink?.dispose();
    stream._sink = null;
    _streams.remove(name);
    _streamNames.remove(name);
    onStreamUnregistered.emit(name);
  }

  /// sink.cpp:178.
  void startStream(String name) {
    final s = _streams[name];
    if (s == null) {
      _log("Cannot start stream '$name', this stream doesn't exist");
      return;
    }
    s.start();
  }

  /// sink.cpp:186.
  void stopStream(String name) {
    final s = _streams[name];
    if (s == null) {
      _log("Cannot stop stream '$name', this stream doesn't exist");
      return;
    }
    s.stop();
  }

  /// sink.cpp:194.
  double getStreamSampleRate(String name) {
    final s = _streams[name];
    if (s == null) {
      _log("Cannot get sample rate of stream '$name', this stream doesn't exist");
      return -1.0;
    }
    return s.getSampleRate();
  }

  SinkStream? getStream(String name) => _streams[name];

  /// sink.cpp:218-240.
  void setStreamSink(String name, String providerName) {
    final stream = _streams[name];
    if (stream == null) {
      _log("Cannot set sink for stream '$name'. Stream doesn't exist");
      return;
    }
    final prov = _providers[providerName];
    if (prov == null) {
      _log("Unknown sink provider '$providerName'");
      return;
    }
    if (stream.running) {
      stream._sink?.stop();
    }
    stream._sink?.dispose();
    stream.providerId = providerNames.indexOf(providerName);
    stream.providerName = providerName;
    stream._sink = prov(stream, name);
    if (stream.running) {
      stream._sink!.start();
    }
  }

  /// Volume setter + config save, the non-GUI part of showVolumeSlider (sink.cpp:242-303).
  void setStreamVolume(String name, double volume) {
    final s = _streams[name];
    if (s == null) return;
    s.setVolume(volume);
    config?.acquire();
    _saveStreamConfig(name);
    config?.release(true);
  }

  /// Mute button of showVolumeSlider.
  void setStreamMuted(String name, bool muted) {
    final s = _streams[name];
    if (s == null) return;
    s.setMuted(muted);
    config?.acquire();
    _saveStreamConfig(name);
    config?.release(true);
  }

  /// Sink selection + config save (showMenu, sink.cpp:344-378).
  void selectStreamSink(String name, String providerName) {
    setStreamSink(name, providerName);
    config?.acquire();
    _saveStreamConfig(name);
    config?.release(true);
  }

  /// sink.cpp:305-325.
  void _loadStreamConfig(String name) {
    final conf = (config!.conf['streams'] as Map)[name];
    if (conf is! Map) return;
    final stream = _streams[name]!;
    var provName = conf['sink'] is String ? conf['sink'] as String : '';
    if (!_providers.containsKey(provName)) {
      provName = providerNames[0];
    }
    if (stream.running) {
      stream._sink?.stop();
    }
    stream._sink?.dispose();
    final prov = _providers[provName]!;
    stream.providerId = providerNames.indexOf(provName);
    stream.providerName = provName;
    stream._sink = prov(stream, name);
    if (stream.running) {
      stream._sink!.start();
    }
    final vol = conf['volume'];
    if (vol is num) stream.setVolume(vol.toDouble());
    final muted = conf['muted'];
    if (muted is bool) stream.setMuted(muted);
  }

  /// sink.cpp:327-334.
  void _saveStreamConfig(String name) {
    final c = config;
    if (c == null) return;
    final stream = _streams[name]!;
    final streams = c.obj('streams');
    streams[name] = <String, dynamic>{
      'sink': providerNames[stream.providerId < 0 ? 0 : stream.providerId],
      'volume': stream.getVolume(),
      'muted': stream.getMuted(),
    };
  }

  /// sink.cpp:337-342 (acquire/release the config around it).
  void loadSinksFromConfig() {
    final streamsConf = config?.conf['streams'];
    if (streamsConf is! Map) return;
    for (final name in _streams.keys) {
      if (!streamsConf.containsKey(name)) continue;
      _loadStreamConfig(name);
    }
  }

  /// sink.cpp:380.
  List<String> getStreamNames() => List<String>.of(_streamNames);
}

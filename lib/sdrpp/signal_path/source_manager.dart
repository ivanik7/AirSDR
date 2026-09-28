// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/signal_path/source.h (lines 1-55) and source.cpp (lines 1-105) @8c9f5ee.
//
// The C++ `SourceHandler` struct of callbacks is the Dart [SourceHandler] contract
// (source_handler.dart). `iqFrontEnd.setInput(handler->stream)` becomes: the manager hands the
// handler a [SourceSink] in [start]; blocks pushed by a handler that is no longer selected are
// dropped (the C++ `nullSource`). No server mode.
import 'dart:typed_data';

import '../core/event.dart';
import 'iq_frontend.dart';
import 'source_handler.dart';

/// `SourceManager::TuningMode` (source.h:24-27).
enum TuningMode { normal, panadapter }

class SourceManager {
  SourceManager(this.iqFrontEnd, {void Function(String message)? log}) : _log = log ?? ((_) {});

  final IQFrontEnd iqFrontEnd;
  final void Function(String message) _log;

  final Map<String, SourceHandler> _sources = <String, SourceHandler>{};
  String _selectedName = '';
  SourceHandler? _selectedHandler;
  double tuneOffset = 0;
  double currentFreq = 0;
  double ifFreq = 0.0;
  TuningMode tuneMode = TuningMode.normal;

  /// Receives blocks before the frontend (e.g. to count or pace); null = direct.
  /// Called with the same arguments as [SourceSink].
  SourceSink? inputTap;

  final Event<String> onSourceRegistered = Event<String>();
  final Event<String> onSourceUnregister = Event<String>();
  final Event<String> onSourceUnregistered = Event<String>();
  final Event<double> onRetune = Event<double>();

  String get selectedName => _selectedName;
  SourceHandler? get selectedHandler => _selectedHandler;

  /// source.cpp:9-16.
  void registerSource(String name, SourceHandler handler) {
    if (_sources.containsKey(name)) {
      _log('Tried to register new source with existing name: $name');
      return;
    }
    _sources[name] = handler;
    onSourceRegistered.emit(name);
  }

  /// source.cpp:18-33.
  void unregisterSource(String name) {
    if (!_sources.containsKey(name)) {
      _log('Tried to unregister non existent source: $name');
      return;
    }
    onSourceUnregister.emit(name);
    if (name == _selectedName) {
      if (_selectedHandler != null) {
        _sources[_selectedName]!.deselect();
      }
      // sigpath::iqFrontEnd.setInput(&nullSource)
      _selectedHandler = null;
    }
    _sources.remove(name);
    onSourceUnregistered.emit(name);
  }

  /// source.cpp:35-39.
  List<String> getSourceNames() => _sources.keys.toList();

  SourceHandler? getSource(String name) => _sources[name];

  /// source.cpp:41-59.
  void selectSource(String name) {
    if (!_sources.containsKey(name)) {
      _log('Tried to select non existent source: $name');
      return;
    }
    if (_selectedHandler != null) {
      _sources[_selectedName]!.deselect();
    }
    _selectedHandler = _sources[name];
    _selectedHandler!.select();
    _selectedName = name;
    // sigpath::iqFrontEnd.setInput(selectedHandler->stream): see [_sinkFor].
  }

  /// source.cpp:68-73.
  Future<void> start() async {
    final h = _selectedHandler;
    if (h == null) {
      return;
    }
    await h.start(_sinkFor(h));
  }

  /// source.cpp:75-80.
  Future<void> stop() async {
    final h = _selectedHandler;
    if (h == null) {
      return;
    }
    await h.stop();
  }

  /// source.cpp:82-90.
  void tune(double freq) {
    final h = _selectedHandler;
    if (h == null) {
      return;
    }
    // TODO: No need to always retune the hardware in Panadapter mode
    h.tune(((tuneMode == TuningMode.normal) ? (freq + tuneOffset) : ifFreq).abs());
    onRetune.emit(freq + tuneOffset);
    currentFreq = freq;
  }

  /// source.cpp:92-95.
  void setTuningOffset(double offset) {
    tuneOffset = offset;
    tune(currentFreq);
  }

  /// source.cpp:97-100.
  void setTuningMode(TuningMode mode) {
    tuneMode = mode;
    tune(currentFreq);
  }

  /// source.cpp:102-105.
  void setPanadapterIF(double freq) {
    ifFreq = freq;
    tune(currentFreq);
  }

  SourceSink _sinkFor(SourceHandler h) {
    return (Float32List iq, int count) {
      // A handler that is no longer selected writes into the C++ nullSource.
      if (!identical(_selectedHandler, h)) return;
      final tap = inputTap;
      if (tap != null) tap(iq, count);
      iqFrontEnd.process(iq, count);
    };
  }
}

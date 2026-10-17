// SPDX-License-Identifier: GPL-3.0-or-later
// One shell-scoped selection over the single native receiver. Only real
// backend events enter the bounded UI log; no IQ or PCM enters Dart.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../radio_controller.dart';
import '../bands/bands.dart';
import '../legacy/centered_receiver.dart';
import 'decoder_contract.dart';
import 'adsb_snapshot.dart';
import 'rds_station.dart';
import 'sstv_image.dart';

class DecoderMessage {
  const DecoderMessage(
    this.sequence,
    this.streamGeneration,
    this.json, {
    required this.receivedAt,
  });
  final int sequence, streamGeneration;
  final Map<String, Object?> json;
  final DateTime receivedAt;

  String get summary {
    final model = json['model'] ?? json['type'] ?? 'rtl_433';
    final id = json['id'];
    final channel = json['channel'];
    final measurements = <String>[
      for (final entry in json.entries)
        if (entry.value != null &&
            (entry.key.startsWith('temperature') ||
                entry.key.startsWith('humidity') ||
                entry.key.startsWith('pressure') ||
                entry.key.startsWith('wind') ||
                entry.key.startsWith('rain') ||
                entry.key == 'battery_ok' ||
                entry.key == 'battery'))
          '${entry.key}: ${entry.value}',
    ];
    final identity = [
      model,
      if (id != null) 'ID $id',
      if (channel != null) 'CH $channel',
    ].join(' · ');
    return [identity, ...measurements].join(' · ');
  }

  String get formattedJson => const JsonEncoder.withIndent('  ').convert(json);
}

class DecoderSession extends ChangeNotifier {
  DecoderSession(this.radio, {CenteredReceiver? receiver})
    : _receiver = receiver ?? CenteredReceiver(radio) {
    _wasRunning = radio.running;
    _lastTunedFrequency = radio.tunedFrequency;
    _lastVfoOffset = radio.vfoOffset;
    _lastSampleRate = radio.sampleRate.round();
    _lastMode = radio.mode;
    radio.addListener(_radioChanged);
    _receiver.onBandEntered = _bandEntered;
    if (radio.running && radio.mode == DemodMode.wfm) {
      _applyRbds();
      _startPolling();
    }
  }
  final RadioController radio;
  final CenteredReceiver _receiver;
  late String _selectedId = decoderIdForMode(radio.mode);
  final Map<String, Map<String, Object>> _settings = {};
  final List<DecoderMessage> _messages = [];
  AdsbSnapshot? _adsbSnapshot;
  AdsbSnapshot? get adsbSnapshot => _adsbSnapshot;
  Timer? _pollTimer;
  bool _attached = false;
  bool _wasRunning = false;
  late double _lastTunedFrequency;
  late double _lastVfoOffset;
  late int _lastSampleRate;
  late DemodMode _lastMode;
  final RdsStation rds = RdsStation();

  /// SSTV picture in progress plus the bounded session gallery; fed only
  /// by real native image events of the selected `sstv` decoder.
  final SstvReceiver sstv = SstvReceiver();
  int _afterSequence = 0;
  int? _streamGeneration;
  int _droppedEvents = 0;
  String? _failure;

  String get selectedId => _selectedId;

  /// Label of the one selected decoder, as every screen shows it.
  String get selectedLabel =>
      decoderById(_selectedId)?.label ?? radio.mode.label;
  bool get active => _attached && radio.running;
  String? get failureReason => _failure;
  int get droppedEvents => _droppedEvents;
  bool get rbdsAvailable =>
      radio.decoderBackend is RbdsDecoderBackend &&
      (radio.decoderBackend! as RbdsDecoderBackend).rbdsAvailable;
  List<DecoderMessage> get messages => List.unmodifiable(_messages);
  int get inputRateHz => radio.sampleRate.round();
  bool get adsbInputReady =>
      inputRateHz >= 2400000 &&
      radio.vfoOffset.abs() + 1200000 <= radio.sampleRate / 2;
  int get decoderRateHz {
    final rate = inputRateHz;
    if (rate < 200000) return 0;
    final factor = (rate + 125000) ~/ 250000;
    final output = rate ~/ factor;
    return output >= 200000 && output <= 300000 ? output : 0;
  }

  Set<String> get availableIds => <String>{
    for (final mode in DemodMode.values) decoderIdForMode(mode),
    ...(radio.decoderBackend?.availableIds ?? const <String>{}),
  };
  bool isAvailable(String id) => availableIds.contains(id);
  bool canConfigure(String id) => _canAttach(id);

  /// A band with a data decoder selects it on entry; a voice-only band just
  /// sets the mode, which a voice selection follows (see [_radioChanged]).
  void _bandEntered(Band band) {
    final id = band.decoderId;
    if (id != null) selectPreview(id);
  }

  bool _canAttach(String id) {
    final descriptor = decoderById(id);
    return descriptor != null &&
        !descriptor.exclusiveReceiver &&
        radio.running &&
        (descriptor.requiredMode == null ||
            descriptor.requiredMode == radio.mode.id) &&
        (descriptor.underlyingModes == null ||
            descriptor.underlyingModes!.contains(radio.mode)) &&
        isAvailable(id);
  }

  /// Whether a decoder's own settings may be edited. Audio-tap decoders
  /// with selectable underlying demods stay editable in an incompatible
  /// mode: choosing the demod is how the user makes the receiver ready.
  bool canEditSettings(String id) {
    final descriptor = decoderById(id);
    if (descriptor?.underlyingModes != null) {
      return !descriptor!.exclusiveReceiver && isAvailable(id);
    }
    return _canAttach(id);
  }

  /// Stores the running demod as the `underlying` choice when it is one of
  /// the decoder's modes, so the config always names the applied mode.
  void _syncUnderlying(String id) {
    final modes = decoderById(id)?.underlyingModes;
    if (modes == null || !modes.contains(radio.mode)) return;
    _settings.putIfAbsent(id, () => <String, Object>{})['underlying'] =
        _underlyingName(radio.mode);
  }

  static String _underlyingName(DemodMode mode) => mode.name;

  static DemodMode? _underlyingMode(Object? name) {
    for (final mode in DemodMode.values) {
      if (mode.name == name) return mode;
    }
    return null;
  }

  void _radioChanged() {
    final running = radio.running;
    final frequency = radio.tunedFrequency;
    final rate = radio.sampleRate.round();
    final modeChanged = radio.mode != _lastMode;
    if (modeChanged) {
      _lastMode = radio.mode;
      rds.clear();
      sstv.abort('mode');
      if (_selectedId == 'adsb') _resetEvents();
    }
    if (frequency != _lastTunedFrequency ||
        rate != _lastSampleRate ||
        radio.vfoOffset != _lastVfoOffset) {
      sstv.abort(frequency != _lastTunedFrequency ? 'retune' : 'restart');
      _lastTunedFrequency = frequency;
      _lastVfoOffset = radio.vfoOffset;
      _lastSampleRate = rate;
      rds.clear();
      if (decoderById(_selectedId)?.voice != true) {
        _resetEvents();
        if ((rate != 0 && decoderRateHz == 0 && _selectedId == 'rtl_433') ||
            (_selectedId == 'adsb' && !adsbInputReady)) {
          _attached = false;
          _stopPolling();
          _failure = _selectedId == 'adsb'
              ? 'not ready: set sample rate 2.4 MS/s'
              : 'Недостаточная частота выборки IQ: выберите не менее 200 кГц';
          radio.decoderBackend?.select(null, const <String, Object>{});
        } else if (running && !_attached) {
          _attachSelected();
        }
      }
    }
    if (!running && _wasRunning) {
      _stopPolling();
      _attached = false;
      sstv.abort('stop');
      _resetEvents();
      rds.clear();
    }
    if (running && !_wasRunning) {
      _attachSelected();
    }
    _wasRunning = running;
    if (decoderById(_selectedId)?.voice == true) {
      final next = decoderIdForMode(radio.mode);
      if (_selectedId != next) _selectedId = next;
    }
    if (modeChanged &&
        running &&
        decoderById(_selectedId)?.underlyingModes != null) {
      // The audio tap follows one demod: reattach (or report not ready).
      _syncUnderlying(_selectedId);
      _attachSelected();
    } else if (modeChanged && running) {
      _stopPolling();
      if (radio.mode == DemodMode.wfm) {
        _applyRbds();
      }
      _startPolling();
    }
    notifyListeners();
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _resetEvents() {
    _afterSequence = 0;
    _streamGeneration = null;
    _droppedEvents = 0;
    _messages.clear();
    _adsbSnapshot = null;
  }

  void _startPolling() {
    if (!radio.running || (radio.mode != DemodMode.wfm && !active)) {
      return;
    }
    _pollTimer ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _drainEvents(),
    );
  }

  void _applyRbds() {
    if (rbdsAvailable && radio.running && radio.mode == DemodMode.wfm) {
      (radio.decoderBackend! as RbdsDecoderBackend).setRbds(
        settingsFor(decoderIdForMode(DemodMode.wfm))['rbds'] == true,
      );
    }
  }

  void _attachSelected() {
    _stopPolling();
    _attached = false;
    _failure = null;
    final id = _selectedId;
    final backend = radio.decoderBackend;
    if (decoderById(id)?.voice == true) {
      backend?.select(null, const <String, Object>{});
      if (radio.mode == DemodMode.wfm) {
        _applyRbds();
        _startPolling();
      }
      return;
    }
    if (!_canAttach(id) || backend == null) {
      if (isAvailable(id) && radio.running) {
        final modes = decoderById(id)?.underlyingModes;
        _failure = modes != null
            ? 'Не готов: нужен режим ${modes.map((m) => m.label).join(', ')} '
                  '(сейчас ${radio.mode.label})'
            : 'Несовместимый режим приёма';
      }
      backend?.select(null, const <String, Object>{});
      return;
    }
    if (id == 'rtl_433' && decoderRateHz == 0) {
      _failure = 'Недостаточная частота выборки IQ: выберите не менее 200 кГц';
      backend.select(null, const <String, Object>{});
      return;
    }
    if (id == 'adsb' && !adsbInputReady) {
      _failure = 'not ready: set sample rate 2.4 MS/s';
      backend.select(null, const <String, Object>{});
      return;
    }
    _syncUnderlying(id);
    final ok = backend.select(id, _config(id));
    if (!ok) {
      backend.select(null, const <String, Object>{});
      _failure = 'Нативный декодер отклонил выбор';
      return;
    }
    _attached = true;
    _resetEvents();
    _startPolling();
  }

  void _drainEvents() {
    if (!radio.running || (radio.mode != DemodMode.wfm && !active)) return;
    final backend = radio.decoderBackend;
    if (backend == null) return;
    var changed = false;
    final tunedHz = radio.tunedFrequency.round();
    // Bounded per tick: avoids holding the UI thread if a producer outruns it.
    for (var i = 0; i < 1024; i++) {
      final event = backend.poll(_afterSequence);
      if (event == null || event.sequence <= _afterSequence) break;
      _afterSequence = event.sequence;
      final lost = event.droppedEvents > _droppedEvents;
      if (_droppedEvents != event.droppedEvents) changed = true;
      _droppedEvents = event.droppedEvents;
      if (_streamGeneration != null &&
          event.streamGeneration != _streamGeneration) {
        _messages.clear();
        _adsbSnapshot = null;
        rds.clear();
        sstv.abort('restart');
        changed = true;
      }
      _streamGeneration = event.streamGeneration;
      if (event.kind == DecoderResult.aircraft) {
        if (!active || _selectedId != 'adsb' || event.payload.length > 65536) {
          continue;
        }
        try {
          final data = jsonDecode(utf8.decode(event.payload));
          if (data is Map<String, dynamic>) {
            final snapshot = AdsbSnapshot.parse(data);
            if (snapshot != null) {
              _adsbSnapshot = snapshot;
              changed = true;
            }
          }
        } on FormatException {
          // Keep the last complete snapshot until a valid replacement arrives.
        }
        continue;
      }
      if ((event.kind == DecoderResult.imageProgress ||
              event.kind == DecoderResult.imageComplete) &&
          event.payload.length <= 65536) {
        if (!active || _selectedId != 'sstv') continue;
        try {
          final data = jsonDecode(utf8.decode(event.payload));
          if (data is Map<String, dynamic> &&
              sstv.handle(
                event.kind,
                data,
                tunedFrequencyHz: tunedHz,
                eventsLost: lost,
              )) {
            changed = true;
          }
        } on FormatException {
          // A malformed native payload breaks the frame being assembled.
          if (sstv.abort('lost')) changed = true;
        }
        continue;
      }
      if (event.kind != DecoderResult.message || event.payload.length > 65536) {
        continue;
      }
      try {
        final data = jsonDecode(utf8.decode(event.payload));
        if (data is! Map<String, dynamic>) continue;
        if (data['source'] == 'rds') {
          if (radio.mode == DemodMode.wfm &&
              data['frequency_hz'] == radio.tunedFrequency.round() &&
              rds.apply(data)) {
            changed = true;
          }
          continue;
        }
        if (!active || _selectedId != 'rtl_433') continue;
        _messages.insert(
          0,
          DecoderMessage(
            event.sequence,
            event.streamGeneration,
            data,
            receivedAt: DateTime.now(),
          ),
        );
        if (_messages.length > 500) _messages.removeLast();
        changed = true;
      } on FormatException {
        // A malformed native payload is not a message.
      }
    }
    if (changed) notifyListeners();
  }

  void clearMessages() {
    _messages.clear();
    notifyListeners();
  }

  void clearSstvGallery() {
    sstv.clearGallery();
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPolling();
    sstv.clear();
    radio.removeListener(_radioChanged);
    if (_receiver.onBandEntered == _bandEntered) {
      _receiver.onBandEntered = null;
    }
    super.dispose();
  }

  Map<String, Object> _config(String id) => {
    'version': 1,
    'settings': settingsFor(id),
  };

  Map<String, Object> settingsFor(String id) {
    final descriptor = decoderById(id);
    if (descriptor == null) return const <String, Object>{};
    final stored = _settings[id];
    return <String, Object>{
      for (final spec in descriptor.settings)
        spec.key: stored?[spec.key] ?? spec.defaultValue,
    };
  }

  Map<String, Object> get currentSettings => settingsFor(_selectedId);

  void selectPreview(String id) {
    final descriptor = decoderById(id);
    if (descriptor == null || id == _selectedId) return;
    sstv.abort('deselect');
    _selectedId = id;
    _resetEvents();
    if (descriptor.demodMode != null) {
      _receiver.changeMode(descriptor.demodMode!);
    }
    _attachSelected();
    notifyListeners();
  }

  void setSetting(String id, String key, Object value) {
    final descriptor = decoderById(id);
    final spec = descriptor?.settings.where((s) => s.key == key).firstOrNull;
    if (spec == null ||
        (spec.allowed.isNotEmpty && !spec.allowed.contains(value))) {
      return;
    }
    _settings.putIfAbsent(id, () => <String, Object>{})[key] = value;
    if (key == 'underlying' &&
        id == _selectedId &&
        descriptor?.underlyingModes != null) {
      // An explicit demod choice uses the normal centered mode control;
      // the mode listener then reattaches the decoder in that mode.
      final mode = _underlyingMode(value);
      if (mode != null && mode != radio.mode) {
        _receiver.changeMode(mode);
        notifyListeners();
        return;
      }
    }
    if (id == decoderIdForMode(DemodMode.wfm) && key == 'rbds') {
      if (rbdsAvailable &&
          radio.running &&
          radio.mode == DemodMode.wfm &&
          !(radio.decoderBackend! as RbdsDecoderBackend).setRbds(
            value == true,
          )) {
        _settings[id]![key] = value != true;
        return;
      }
      rds.clear();
    }
    if (id == _selectedId && descriptor?.voice != true && _canAttach(id)) {
      _attachSelected();
    }
    notifyListeners();
  }

  void applyStored(
    String? id,
    Map<String, Object> settings, {
    DemodMode? mode,
  }) {
    final resolvedId = (id != null && decoderById(id) != null)
        ? id
        : decoderIdForMode(mode ?? radio.mode);
    final descriptor = decoderById(resolvedId);
    _settings[resolvedId] = <String, Object>{
      for (final spec in descriptor?.settings ?? const <DecoderSetting>[])
        spec.key:
            (settings[spec.key] != null &&
                (spec.allowed.isEmpty ||
                    spec.allowed.contains(settings[spec.key])))
            ? settings[spec.key]!
            : spec.defaultValue,
    };
    if (resolvedId != _selectedId) sstv.abort('deselect');
    _selectedId = resolvedId;
    // A preset's own mode wins over a stored underlying demod.
    _syncUnderlying(resolvedId);
    _resetEvents();
    _attachSelected();
    _applyRbds();
    notifyListeners();
  }
}

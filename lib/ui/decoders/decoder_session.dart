// SPDX-License-Identifier: GPL-3.0-or-later
// One shell-scoped selection over the single native receiver. Only real
// backend events enter the bounded UI log; no IQ or PCM enters Dart.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../radio_controller.dart';
import '../legacy/centered_receiver.dart';
import 'decoder_contract.dart';

class DecoderMessage {
  const DecoderMessage(this.sequence, this.streamGeneration, this.json);
  final int sequence, streamGeneration;
  final Map<String, Object?> json;

  String get summary {
    final model = json['model'] ?? json['type'] ?? 'rtl_433';
    final id = json['id'];
    return id == null ? '$model' : '$model · $id';
  }

  String get formattedJson => const JsonEncoder.withIndent('  ').convert(json);
}

class DecoderSession extends ChangeNotifier {
  DecoderSession(this.radio, {CenteredReceiver? receiver})
    : _receiver = receiver ?? CenteredReceiver(radio) {
    _wasRunning = radio.running;
    radio.addListener(_radioChanged);
  }
  final RadioController radio;
  final CenteredReceiver _receiver;
  late String _selectedId = decoderIdForMode(radio.mode);
  final Map<String, Map<String, Object>> _settings = {};
  final List<DecoderMessage> _messages = [];
  Timer? _pollTimer;
  bool _attached = false;
  bool _wasRunning = false;
  int _afterSequence = 0;
  int? _streamGeneration;
  int _droppedEvents = 0;
  String? _failure;

  String get selectedId => _selectedId;
  bool get active => _attached && radio.running;
  String? get failureReason => _failure;
  int get droppedEvents => _droppedEvents;
  List<DecoderMessage> get messages => List.unmodifiable(_messages);
  int get inputRateHz => radio.sampleRate.round();

  Set<String> get availableIds => <String>{
    for (final mode in DemodMode.values) decoderIdForMode(mode),
    ...(radio.decoderBackend?.availableIds ?? const <String>{}),
  };
  bool isAvailable(String id) => availableIds.contains(id);
  bool canConfigure(String id) => _canAttach(id);

  bool _canAttach(String id) {
    final descriptor = decoderById(id);
    return descriptor != null &&
        !descriptor.exclusiveReceiver &&
        radio.running &&
        (descriptor.requiredMode == null ||
            descriptor.requiredMode == radio.mode.id) &&
        isAvailable(id);
  }

  void _radioChanged() {
    final running = radio.running;
    if (!running && _wasRunning) {
      _stopPolling();
      _attached = false;
      _resetEvents();
    }
    if (running && !_wasRunning && decoderById(_selectedId)?.voice != true) {
      _attachSelected();
    }
    _wasRunning = running;
    if (decoderById(_selectedId)?.voice == true) {
      final next = decoderIdForMode(radio.mode);
      if (_selectedId != next) _selectedId = next;
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
  }

  void _attachSelected() {
    _stopPolling();
    _attached = false;
    _failure = null;
    final id = _selectedId;
    final backend = radio.decoderBackend;
    if (decoderById(id)?.voice == true) {
      backend?.select(null, const <String, Object>{});
      return;
    }
    if (!_canAttach(id) || backend == null) {
      if (isAvailable(id) && radio.running) {
        _failure = 'Несовместимый режим приёма';
      }
      backend?.select(null, const <String, Object>{});
      return;
    }
    final ok = backend.select(id, _config(id));
    if (!ok) {
      backend.select(null, const <String, Object>{});
      _failure = 'Нативный декодер отклонил выбор';
      return;
    }
    _attached = true;
    _resetEvents();
    if (id == 'rtl_433') {
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _drainEvents(),
      );
    }
  }

  void _drainEvents() {
    if (!active || _selectedId != 'rtl_433') return;
    final backend = radio.decoderBackend;
    if (backend == null) return;
    var changed = false;
    // Bounded per tick: avoids holding the UI thread if a producer outruns it.
    for (var i = 0; i < 1024; i++) {
      final event = backend.poll(_afterSequence);
      if (event == null || event.sequence <= _afterSequence) break;
      _afterSequence = event.sequence;
      if (_droppedEvents != event.droppedEvents) changed = true;
      _droppedEvents = event.droppedEvents;
      if (_streamGeneration != null &&
          event.streamGeneration != _streamGeneration) {
        _messages.clear();
        changed = true;
      }
      _streamGeneration = event.streamGeneration;
      if (event.kind != DecoderResult.message || event.payload.length > 65536) {
        continue;
      }
      try {
        final data = jsonDecode(utf8.decode(event.payload));
        if (data is! Map<String, dynamic>) continue;
        _messages.insert(
          0,
          DecoderMessage(event.sequence, event.streamGeneration, data),
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

  @override
  void dispose() {
    _stopPolling();
    radio.removeListener(_radioChanged);
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
    _selectedId = resolvedId;
    _resetEvents();
    _attachSelected();
    notifyListeners();
  }
}

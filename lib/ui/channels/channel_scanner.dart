// SPDX-License-Identifier: GPL-3.0-or-later
// Sequential scanning of stored channels using the one existing receiver.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../radio_controller.dart';
import 'channel_controller.dart';
import 'channels.dart';

class ChannelScanner extends ChangeNotifier {
  ChannelScanner({
    required this.controller,
    this.noiseDwell = const Duration(milliseconds: 180),
    this.levelDwell = const Duration(milliseconds: 850),
    this.resumeDelay = const Duration(seconds: 2),
  }) {
    controller.cancelScan = () => stop(restore: false);
    controller.receiver.onManualChange = controller.manualChange;
    radio.addListener(_onRadio);
    channels.addListener(_onChannels);
  }

  final ChannelController controller;
  RadioController get radio => controller.radio;
  ChannelsRepository get channels => controller.channels;
  final Duration noiseDwell;
  final Duration levelDwell;
  final Duration resumeDelay;
  static const _tick = Duration(milliseconds: 25);
  static const _maxNoStatus = Duration(seconds: 3);

  Timer? _timer;
  final Stopwatch _visitClock = Stopwatch();
  final Stopwatch _hangClock = Stopwatch();
  bool _active = false;
  bool _visiting = false;
  bool _wasMuted = true;
  int _index = -1;
  String? _tunedId;
  String? _receivingId;
  bool _everOpened = false;
  bool _hanging = false;
  DemodMode? _expectedMode;
  double? _expectedFrequency;
  String? _selectedId;

  bool get active => _active;
  bool get userMuted => _active ? _wasMuted : radio.muted;

  void setUserMuted(bool muted) {
    if (!_active) return;
    _wasMuted = muted;
    radio.setMuted(muted || _receivingId == null);
    notifyListeners();
  }

  String? get tunedChannelId => _tunedId;
  String? get receivingChannelId => _receivingId;

  bool get canStart =>
      radio.running &&
      channels.channels.where(_eligible).length >= 2 &&
      channels.active != null &&
      _eligible(channels.active!);

  bool _eligible(ReceiverChannel c) {
    final device = radio.selectedDevice;
    return c.mode.params.autoSquelch != null &&
        c.frequencyHz > 0 &&
        c.frequencyHz >= (device?.minFrequency ?? 1) &&
        c.frequencyHz <= (device?.maxFrequency ?? 999999999999);
  }

  bool start() {
    if (_active) return true;
    if (!canStart) return false;
    _wasMuted = radio.muted;
    _active = true;
    _selectedId = channels.activeId;
    controller.setScanning(true);
    _index = channels.indexOf(channels.activeId!);
    _visit(channels.channels[_index]);
    _timer = Timer.periodic(_tick, (_) => _poll());
    notifyListeners();
    return true;
  }

  void _visit(ReceiverChannel c) {
    _visiting = true;
    _receivingId = null;
    _everOpened = false;
    _hanging = false;
    _hangClock.stop();
    radio.setMuted(true);
    // The ChannelController guards both the selected slot and manual callbacks.
    if (!controller.scanTo(c)) {
      _visiting = false;
      _next();
      return;
    }
    if (radio.squelchType != SquelchType.auto) {
      radio.setSquelchType(SquelchType.auto);
    }
    _expectedFrequency = radio.tunedFrequency;
    _expectedMode = radio.mode;
    _tunedId = c.id;
    _visitClock
      ..reset()
      ..start();
    _visiting = false;
    notifyListeners();
  }

  void _next() {
    if (!_active) return;
    final all = channels.channels;
    final previous = all.indexWhere((c) => c.id == _tunedId);
    if (previous < 0) {
      stop();
      return;
    }
    _index = previous;
    for (var i = 0; i < all.length; i++) {
      _index = (_index + 1) % all.length;
      if (_eligible(all[_index])) {
        _visit(all[_index]);
        return;
      }
    }
    stop();
  }

  void _poll() {
    if (!_active || !radio.running) {
      stop();
      return;
    }
    final c = channels.channels.where((c) => c.id == _tunedId).firstOrNull;
    if (c == null) {
      stop();
      return;
    }
    if (radio.squelchType != SquelchType.auto) {
      radio.setSquelchType(SquelchType.auto);
    }
    final elapsed = _visitClock.elapsed;
    final status = radio.autoSquelchStatus;
    final dwell = c.mode.params.autoSquelch == AutoSquelchKind.noise
        ? noiseDwell
        : levelDwell;
    // No decision on a buffered status from the old frequency or while the
    // channel filter and the auto-level floor are still settling.
    if (elapsed < dwell) return;
    if (status == null || status.thresholdDb == null) {
      if (elapsed >= _maxNoStatus) _next();
      return;
    }
    if (status.open) {
      _everOpened = true;
      _hanging = false;
      _hangClock.stop();
      if (_receivingId != c.id) {
        _receivingId = c.id;
        if (!_wasMuted) radio.setMuted(false);
        notifyListeners();
      }
    } else if (_everOpened) {
      // The DSP applies its own 250 ms squelch hang and 5 ms audio fade.
      // Continue scanning only after an additional conversational pause.
      if (!_hanging) {
        _hanging = true;
        _hangClock
          ..reset()
          ..start();
        _receivingId = null;
        radio.setMuted(true);
        notifyListeners();
      } else if (_hangClock.elapsed >= resumeDelay) {
        _next();
      }
    } else {
      _next();
    }
  }

  void _onRadio() {
    if (!_active || _visiting) return;
    if (!radio.running ||
        radio.mode != _expectedMode ||
        radio.tunedFrequency != _expectedFrequency) {
      stop(restore: radio.running);
    }
  }

  void _onChannels() {
    if (!_active) return;
    if (channels.activeId != _selectedId ||
        channels.active == null ||
        !canStart ||
        !channels.channels.any((c) => c.id == _tunedId)) {
      stop();
    }
  }

  /// Stop scanning; restore the selected slot unless a manual tune is already
  /// in progress. User mute is restored, never overridden by the scan.
  void stop({bool restore = true}) {
    if (!_active) return;
    _active = false;
    _timer?.cancel();
    _timer = null;
    _visitClock.stop();
    _hangClock.stop();
    _receivingId = null;
    _tunedId = null;
    _selectedId = null;
    _expectedFrequency = null;
    _expectedMode = null;
    if (restore && channels.active != null) controller.scanTo(channels.active!);
    radio.setMuted(_wasMuted);
    controller.setScanning(false);
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    radio.removeListener(_onRadio);
    channels.removeListener(_onChannels);
    if (controller.cancelScan != null) controller.cancelScan = null;
    controller.receiver.onManualChange = null;
    super.dispose();
  }
}

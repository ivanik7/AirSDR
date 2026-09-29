// SPDX-License-Identifier: GPL-3.0-or-later
// Reception foreground-service bridge. The Dart controller remains the sole owner of DSP,
// audio and USB; the Android service owns only the notification and CPU wake lock.
import 'dart:async';

import 'package:flutter/services.dart';

import '../ui/radio_controller.dart';
import 'sdr_radio_controller.dart';

class BackgroundReception {
  BackgroundReception(
    this.radio, {
    this.channel = const MethodChannel('sdr/background'),
    this.updateInterval = const Duration(seconds: 1),
    this.onOpenReceive,
  }) {
    channel.setMethodCallHandler(_fromNative);
    radio.addListener(_changed);
    _changed(); // auto-connect can finish before the bridge is attached
  }

  final RadioController radio;
  final MethodChannel channel;
  final Duration updateInterval;
  final VoidCallback? onOpenReceive;
  Future<void> _serial = Future<void>.value();
  Timer? _updateTimer;
  bool _active = false;
  bool _disposed = false;
  String? _lastDetails;

  Map<String, Object> get _details => <String, Object>{
    'frequency': radio.tunedFrequency.round(),
    'mode': radio.mode.label,
  };

  void _enqueue(String method, [Map<String, Object>? args]) {
    _serial = _serial.then((_) async {
      if (_disposed) return;
      try {
        if (method == 'stop' && radio is SdrRadioController) {
          await (radio as SdrRadioController).whenStopped;
        }
        if (method == 'stop' && radio.running) return; // rapid re-plug won
        await channel.invokeMethod<void>(method, args);
      } on PlatformException {
        // Never leave a receiving DSP without a foreground service (e.g. FGS start
        // rejected by Android). A denied notification permission isn't a failure here.
        if (method == 'start' && radio.running) {
          unawaited(radio.stop());
        }
      } on MissingPluginException {
        // Widget/host tests and other platforms have no Android service.
      }
    });
  }

  void _changed() {
    if (_disposed) return;
    if (!radio.running) {
      _updateTimer?.cancel();
      _updateTimer = null;
      _lastDetails = null;
      if (_active) {
        _active = false;
        _enqueue('stop');
      }
      return;
    }
    final details = _details;
    final key = '${details['frequency']}:${details['mode']}';
    if (!_active) {
      _active = true;
      _lastDetails = key;
      _enqueue('start', details);
    } else if (key != _lastDetails && _updateTimer == null) {
      _updateTimer = Timer(updateInterval, () {
        _updateTimer = null;
        if (!radio.running || _disposed) return;
        final latest = _details;
        _lastDetails = '${latest['frequency']}:${latest['mode']}';
        _enqueue('update', latest);
      });
    }
  }

  Future<void> _fromNative(MethodCall call) async {
    if (call.method == 'serviceFailed') {
      await radio.stop();
      return;
    }
    if (call.method == 'openReceive') {
      onOpenReceive?.call();
      return;
    }
    if (call.method != 'stopReception') throw MissingPluginException();
    // Same stop() invoked by the UI. The service stays alive until the controller has
    // released the DSP audio/USB stream and the state listener has queued service stop.
    await radio.stop();
    await _serial;
  }

  void dispose() {
    radio.removeListener(_changed);
    _updateTimer?.cancel();
    channel.setMethodCallHandler(null);
    if (_active) unawaited(channel.invokeMethod<void>('stop'));
    _disposed = true;
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Reception foreground-service bridge. NativeRadioController promotes before
// DSP start and releases the service after native USB/audio teardown.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ui/radio_controller.dart';

class BackgroundReception {
  BackgroundReception(
    this.radio, {
    this.channel = const MethodChannel('sdr/background'),
    this.updateInterval = const Duration(seconds: 1),
    this.onOpenReceive,
    this.decoderLabel,
  }) {
    channel.setMethodCallHandler(_fromNative);
    radio.addListener(_changed);
    decoderLabel?.addListener(_changed);
    _changed(); // auto-connect can finish before the bridge is attached
  }

  final RadioController radio;
  final MethodChannel channel;
  final Duration updateInterval;
  final VoidCallback? onOpenReceive;

  /// Label of the one selected decoder (DecoderSession, published by the
  /// shell). The notification shows it instead of the raw demod mode, so a
  /// data decoder reads e.g. `rtl_433`, same as the Receive screen.
  final ValueListenable<String?>? decoderLabel;
  Future<void> _serial = Future<void>.value();
  Timer? _updateTimer;
  bool _active = false;
  bool _disposed = false;
  String? _lastDetails;

  Map<String, Object> get _details => <String, Object>{
    'frequency': radio.tunedFrequency.round(),
    'mode': decoderLabel?.value ?? radio.mode.label,
  };

  void _enqueue(String method, [Map<String, Object>? args]) {
    _serial = _serial.then((_) async {
      if (_disposed) return;
      try {
        await channel.invokeMethod<void>(method, args);
      } on PlatformException {
        // A failed notification update does not own the receiver lifecycle.
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
      _active = false;
      return;
    }
    final details = _details;
    final key = '${details['frequency']}:${details['mode']}';
    if (!_active) {
      _active = true;
      // The native promotion carried the raw demod label.
      _lastDetails = '${details['frequency']}:${radio.mode.label}';
    }
    if (key != _lastDetails && _updateTimer == null) {
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
    // released native DSP/audio/USB and its afterStop hook has released the service.
    await radio.stop();
    await _serial;
  }

  void dispose() {
    radio.removeListener(_changed);
    decoderLabel?.removeListener(_changed);
    _updateTimer?.cancel();
    channel.setMethodCallHandler(null);

    _disposed = true;
  }
}

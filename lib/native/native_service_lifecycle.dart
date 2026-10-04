// SPDX-License-Identifier: GPL-3.0-or-later
// Android foreground/focus handshake for the native radio. No IQ/audio crosses
// the channel; the native controller releases its handle and fd before release.
import 'package:flutter/services.dart';

import 'native_radio_controller.dart';

class NativeServiceLifecycle {
  const NativeServiceLifecycle({
    this.channel = const MethodChannel('sdr/background'),
  });

  final MethodChannel channel;

  Future<void> promote(NativeRadioController radio) =>
      channel.invokeMethod<void>('promote', <String, Object>{
        'frequency': radio.tunedFrequency.round(),
        'mode': radio.mode.label,
      });

  Future<void> release() => channel.invokeMethod<void>('release');
}

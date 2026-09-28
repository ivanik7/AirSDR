// SPDX-License-Identifier: GPL-3.0-or-later
// Test double for the 'usb' source in the DSP isolate: a SynthSource wearing the USB source id,
// with generic gain/AGC/sample-rate controls and a `simulateLoss` setting that behaves like a
// hot-unplugged dongle (the source stops itself and reports a fatal error).
//
// Used by controller tests (auto-connect, hot re-plug) that drive the real DSP isolate with a
// mocked Android USB plugin — no usbfs fd is ever touched.
import 'dart:async';

import 'package:sdr_flutter/runtime/device_sources.dart' show usbSourceId;
import 'package:sdr_flutter/runtime/source_registry.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/synth_source.dart';
import 'package:sdr_flutter/sdrpp/signal_path/source_handler.dart';

/// Registry hook (top-level: sent to the DSP isolate).
void registerFakeUsbSources(SourceRegistry r) {
  r.register(usbSourceId, createFakeUsbSource);
}

SourceInstance createFakeUsbSource(
  Map<Object?, Object?> params,
  SourceContext ctx,
) {
  final synth = SourceRegistry.createSynth(<Object?, Object?>{
    'sampleRate': 2400000.0,
    'pump': 'realTime',
  }, ctx);
  final h = FakeUsbHandler(
    synth.handler as SynthSource,
    ctx,
    (params['deviceName'] as String?) ?? '?',
  );
  return SourceInstance(
    h,
    controls: const FakeUsbControls(),
    dispose: synth.dispose,
    stats: () => <String, Object?>{'fakeDevice': h.deviceName},
  );
}

class FakeUsbHandler implements SourceHandler {
  FakeUsbHandler(this.synth, this.ctx, this.deviceName);

  final SynthSource synth;
  final SourceContext ctx;
  final String deviceName;
  double gain = 0;
  bool agc = false;

  @override
  void select() => synth.select();
  @override
  void deselect() => synth.deselect();
  @override
  Future<void> start(SourceSink sink) async {
    // Slow USB initialization (e.g. tuner register setup) for Stop-during-Start coverage.
    if (deviceName.endsWith('/011')) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    await synth.start(sink);
  }

  @override
  Future<void> stop() => synth.stop();
  @override
  void tune(double frequencyHz) => synth.tune(frequencyHz);

  @override
  List<SourceSetting> get settings => <SourceSetting>[
    BoolSetting('agc', 'AGC', agc),
  ];

  @override
  void applySetting(String id, Object value) {
    if (id == 'simulateLoss') {
      unawaited(synth.stop());
      ctx.reportError('Fake USB device disconnected', fatal: true);
    }
  }
}

class FakeUsbControls extends SourceControls {
  const FakeUsbControls();

  @override
  bool setSampleRate(SourceHandler h, double sampleRate) {
    (h as FakeUsbHandler).synth.setSampleRate(sampleRate);
    return true;
  }

  @override
  bool setGain(SourceHandler h, double gain) {
    (h as FakeUsbHandler).gain = gain;
    return true;
  }

  @override
  bool setAgc(SourceHandler h, bool enabled) {
    (h as FakeUsbHandler).agc = enabled;
    return true;
  }

  @override
  double? gainOf(SourceHandler h) => (h as FakeUsbHandler).gain;
  @override
  bool? agcOf(SourceHandler h) => (h as FakeUsbHandler).agc;
}

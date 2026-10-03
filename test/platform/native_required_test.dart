// SPDX-License-Identifier: GPL-3.0-or-later
// L1: the Linux fallback must never pretend to receive, and the compact stats
// line must label the native host engine as IQ-only (no audio before N2).
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/platform/linux/native_required_radio_controller.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/receive_screen.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _StatsRadio extends DemoRadioController {
  _StatsRadio(this._stats);
  final Map<String, Object?> _stats;
  @override
  Map<String, Object?> get stats => _stats;
}

void main() {
  test('native-required controller reports failure and never runs', () async {
    final r = NativeRequiredRadioController(reason: 'dlopen failed');
    addTearDown(r.dispose);
    await r.start();
    expect(r.running, isFalse);
    expect(r.devices, isEmpty);
    expect(r.linkState, DeviceLinkState.failed);
    expect(r.lastError, contains('Native core required'));
    expect(r.lastError, contains('dlopen failed'));
    r.setTuning(centerFrequency: 100e6, vfoOffset: 25e3);
    expect(r.centerFrequency, 100.025e6);
    expect(r.vfoOffset, 0);
  });

  test('compact stats line labels the native host engine honestly', () {
    final r = _StatsRadio(<String, Object?>{
      'engine': 'native IQ (Linux host)',
      'ringDrops': 0,
    });
    addTearDown(r.dispose);
    final line = compactStatsLine(r);
    expect(line, contains('ring drops 0'));
    expect(line, contains('no audio'));
    expect(line, isNot(contains('USB drops')));
  });
}

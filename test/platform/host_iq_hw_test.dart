// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real-hardware harness for HostIqRadioController. Skipped unless
// SDR_HW_TEST=1. Requires a built libsdrcore.so (native/ CMake) referenced
// by SDRCORE_HOST_LIBRARY, and one supported USB SDR attached with
// permissions already granted (udev rule / plugdev).
//
// Run:
//   cmake -S native -B <build> -G Ninja -DCMAKE_BUILD_TYPE=Debug
//   cmake --build <build> --target sdrcore
//   SDR_HW_TEST=1 SDR_HW_SECONDS=20 \
//     SDRCORE_HOST_LIBRARY=<build>/libsdrcore.so \
//     SDR_HW_JSON=/tmp/host_iq_hw.json \
//     flutter test test/platform/host_iq_hw_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/platform/linux/host_iq_radio_controller.dart';

Future<void> _waitUntil(
  bool Function() cond,
  Duration timeout,
  String what,
) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) {
      fail('timed out after ${sw.elapsed} waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final enabled = Platform.environment['SDR_HW_TEST'] == '1';
  final seconds =
      int.tryParse(Platform.environment['SDR_HW_SECONDS'] ?? '') ?? 20;

  test(
    'streams real IQ from an attached USB SDR, retunes, and restarts cleanly',
    () async {
      final snapshots = <Map<String, Object?>>[];
      final controller = HostIqRadioController(
        core: SdrCore.open(
          libraryPath: Platform.environment['SDRCORE_HOST_LIBRARY'],
        ),
        pollInterval: const Duration(seconds: 1),
        statsInterval: const Duration(milliseconds: 500),
        retuneDebounce: const Duration(milliseconds: 120),
      );
      addTearDown(controller.dispose);

      await _waitUntil(
        () => controller.running,
        const Duration(seconds: 10),
        'auto-start',
      );
      expect(controller.lastError, isNull);

      // Phase 1: steady state at the default tuning.
      for (var i = 0; i < seconds; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(controller.running, isTrue);
        snapshots.add({
          'phase': 'default',
          ...controller.diagnosticsSnapshot(),
        });
      }

      // Phase 2: retune + gain change (stop -> configure -> start).
      controller.setTuning(centerFrequency: 99500000, vfoOffset: 0);
      controller.setGain(38);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _waitUntil(
        () => controller.running,
        const Duration(seconds: 5),
        'restart after retune',
      );
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(controller.running, isTrue);
        snapshots.add({
          'phase': 'retuned',
          ...controller.diagnosticsSnapshot(),
        });
      }
      expect(controller.centerFrequency, 99500000);
      expect(controller.gain, 38);

      // Phase 3: stop, then start again, then stop for good.
      await controller.stop();
      expect(controller.running, isFalse);
      await controller.start();
      await _waitUntil(
        () => controller.running,
        const Duration(seconds: 5),
        'restart after manual stop/start',
      );
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(controller.running, isTrue);
        snapshots.add({
          'phase': 'restarted',
          ...controller.diagnosticsSnapshot(),
        });
      }
      await controller.stop();
      expect(controller.running, isFalse);
      expect(controller.lastError, isNull);

      // Steady-state throughput check: default-phase samples near the end of
      // that phase, once the ring has filled and the rate has settled.
      final steady = snapshots
          .where((s) => s['phase'] == 'default')
          .skip(seconds > 4 ? seconds - 4 : 0)
          .toList();
      expect(steady, isNotEmpty);
      final avgRate =
          steady
              .map((s) => (s['inputRate'] as num).toDouble())
              .reduce((a, b) => a + b) /
          steady.length;
      const expectedRate = 2400000.0;
      final errorFrac = (avgRate - expectedRate).abs() / expectedRate;

      final summary = <String, Object?>{
        'snapshotCount': snapshots.length,
        'avgInputRateSteady': avgRate,
        'expectedRate': expectedRate,
        'rateErrorFraction': errorFrac,
        'finalRunning': controller.running,
        'finalLinkState': controller.linkState.name,
        'finalLastError': controller.lastError,
        'lastSnapshot': snapshots.last,
      };
      // ignore: avoid_print
      print('HOST_IQ_HW_SUMMARY ${jsonEncode(summary)}');

      final jsonPath = Platform.environment['SDR_HW_JSON'];
      if (jsonPath != null && jsonPath.isNotEmpty) {
        File(jsonPath).writeAsStringSync(
          jsonEncode(<String, Object?>{
            'summary': summary,
            'snapshots': snapshots,
          }),
        );
      }

      expect(
        errorFrac,
        lessThan(0.01),
        reason:
            'steady-state inputRate $avgRate not within 1% of $expectedRate',
      );
      expect(controller.running, isFalse);
      expect(controller.lastError, isNull);
    },
    skip: enabled ? false : 'Set SDR_HW_TEST=1 (and SDRCORE_HOST_LIBRARY) to run against real hardware',
    timeout: Timeout(Duration(seconds: 60 + seconds)),
  );
}

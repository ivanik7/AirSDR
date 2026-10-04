// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real-hardware retune latency on the production Dart call path
// (kanban t_c364ac15). Drives NativeRadioController.setTuning with the real
// FFI library and an attached RTL-SDR, exactly as CenteredReceiver does
// (step retunes and a 250 ms drag recenter cadence), and measures on the
// calling isolate:
//   call_ms   synchronous wall time of setTuning (the UI isolate is blocked
//             for this long; >8.3 ms drops a 120 Hz frame);
//   lag_ms    worst event-loop lag seen by a 4 ms periodic probe timer;
//   row_ms    time from setTuning to the first FFT row whose span is
//             centered on the new LO (tune-to-first-valid-FFT latency).
//
// Run (skipped otherwise):
//   SDR_HW_TEST=1 SDRCORE_V3_PROBE_LIBRARY=<build>/libsdrcore.so \
//     flutter test test/native/retune_ui_latency_hw_test.dart
// SDR_HW_RETUNE_MAX_CALL_MS (default 2) bounds the p95 call time.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/native_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

double _pct(List<double> v, double p) {
  final s = [...v]..sort();
  return s[((s.length - 1) * p).round()];
}

String _summary(String label, List<double> v) =>
    '$label n=${v.length} p50=${_pct(v, .5).toStringAsFixed(2)} '
    'p95=${_pct(v, .95).toStringAsFixed(2)} '
    'max=${_pct(v, 1).toStringAsFixed(2)}';

void main() {
  final library = Platform.environment['SDRCORE_V3_PROBE_LIBRARY'];
  final hw = Platform.environment['SDR_HW_TEST'] == '1';
  test(
    'setTuning on a running RTL session does not block the calling isolate',
    () async {
      final maxCallMs =
          double.tryParse(
            Platform.environment['SDR_HW_RETUNE_MAX_CALL_MS'] ?? '',
          ) ??
          2.0;
      final dir = await Directory.systemTemp.createTemp('retune_hw');
      final api = FfiNativeRadioApi.open(libraryPath: library);
      final radio = NativeRadioController(
        api: api,
        source: HostNativeDeviceSource(api),
        configDir: dir.path,
      );
      try {
        for (var i = 0; i < 200 && !radio.running; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(radio.running, isTrue, reason: '${radio.lastError}');
        radio.setSampleRate(2400000);
        radio.setMode(DemodMode.wfm);
        radio.setTuning(centerFrequency: 100000000, vfoOffset: 0);
        await Future<void>.delayed(const Duration(seconds: 2));

        double? pendingCenter;
        Stopwatch? sinceTune;
        final rowMs = <double>[];
        final sub = radio.fftRows.listen((row) {
          final want = pendingCenter;
          if (want == null) return;
          final mid = (row.lowFreq + row.highFreq) / 2;
          if ((mid - want).abs() < 1) {
            rowMs.add(sinceTune!.elapsedMicroseconds / 1000);
            pendingCenter = null;
          }
        });

        // Event-loop probe: a UI isolate stall shows up as timer lag.
        var maxLag = 0.0;
        var last = Stopwatch()..start();
        final probe = Timer.periodic(const Duration(milliseconds: 4), (_) {
          final lag = last.elapsedMicroseconds / 1000 - 4;
          if (lag > maxLag) maxLag = lag;
          last = Stopwatch()..start();
        });

        final callMs = <double>[];
        final lagMs = <double>[];
        var hz = 100000000.0;
        for (var i = 0; i < 40; i++) {
          // Alternate step (100 kHz) and preset-sized (1.7 MHz) LO jumps.
          hz += i.isEven ? 100000 : (i % 4 == 1 ? 1700000 : -1700000);
          maxLag = 0;
          final call = Stopwatch()..start();
          radio.setTuning(centerFrequency: hz, vfoOffset: 0);
          call.stop();
          pendingCenter = hz;
          sinceTune = Stopwatch()..start();
          callMs.add(call.elapsedMicroseconds / 1000);
          // Drag recenter cadence (CenteredReceiver.dragTunePeriod).
          await Future<void>.delayed(const Duration(milliseconds: 250));
          lagMs.add(maxLag);
          expect(radio.running, isTrue, reason: '${radio.lastError}');
        }
        // Rapid burst: latest wins, final state must be the last request.
        for (var i = 0; i < 10; i++) {
          hz += 25000;
          radio.setTuning(centerFrequency: hz, vfoOffset: 0);
        }
        pendingCenter = hz;
        sinceTune = Stopwatch()..start();
        final burstRows = rowMs.length;
        await Future<void>.delayed(const Duration(seconds: 1));
        probe.cancel();
        await sub.cancel();
        final burstRowSeen = rowMs.length > burstRows;
        if (burstRowSeen) rowMs.removeLast();
        final stats = radio.stats;
        stdout.writeln(_summary('call_ms', callMs));
        stdout.writeln(_summary('lag_ms', lagMs));
        if (rowMs.isNotEmpty) stdout.writeln(_summary('row_ms', rowMs));
        stdout.writeln(
          'burst final row centered on ${hz.round()}: $burstRowSeen; '
          'ringDrops ${stats['ringDrops']} audioFrames ${stats['audioFrames']}',
        );
        expect(burstRowSeen, isTrue);
        expect(radio.centerFrequency, hz);
        expect(radio.vfoOffset, 0);
        expect(_pct(callMs, .95), lessThan(maxCallMs));
      } finally {
        await radio.stop();
        radio.dispose();
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: library == null || !hw
        ? 'Set SDR_HW_TEST=1 and SDRCORE_V3_PROBE_LIBRARY with a host RTL-SDR'
        : null,
  );
}

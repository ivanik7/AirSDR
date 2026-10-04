// Comparative CPU/memory oracle: Dart receiver vs native ABI v3 at 2.4 MS/s WFM.
//
// Opt-in (N2_PERF=1) because it is a measurement, not a unit test. It needs
// `build/n2-oracle/` from `native/tests/n2/run_n2_oracles.sh` for the
// fixture generator and the native perf figures (`suite.json`,
// case `perf_2400k_wfm`: real-time paced 2.4 MS/s WFM with 30 Hz FFT polling,
// CPU of the whole native process including the producer thread).
//
// The Dart side replays a 2.4 MS/s CU8 fixture through the existing Dart
// SDR++ port (FileSource -> IQFrontEnd -> RadioModule, 8192-bin FFT at 20 Hz,
// same as the app) as fast as possible on this isolate and measures this
// process's CPU time from /proc/self/stat. CPU seconds per IQ second is the
// number of cores the Dart DSP needs to keep up in real time, comparable to
// the native `cpu_cores` metric. Results: build/n2-oracle/perf_compare.json.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/modules/radio/demod.dart';

import 'dart_reference.dart';

const int kRate = 2400000;
const double kSeconds = 4.0;

/// utime+stime of this process in seconds (Linux /proc, USER_HZ = 100).
double processCpuSeconds() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  // fields[0] is state (field 3); utime is field 14, stime field 15.
  return (int.parse(fields[11]) + int.parse(fields[12])) / 100.0;
}

int rssKib() {
  for (final line in File('/proc/self/status').readAsLinesSync()) {
    if (line.startsWith('VmRSS:')) {
      return int.parse(line.split(RegExp(r'\s+'))[1]);
    }
  }
  return -1;
}

void main() {
  final enabled = Platform.environment['N2_PERF'] == '1';
  final oracle = NativeOracle.locate();
  final suite = File('build/n2-oracle/suite.json');
  final skip = !enabled
      ? 'set N2_PERF=1 to run the Dart vs native CPU comparison'
      : oracle == null || !suite.existsSync()
      ? 'run native/tests/n2/run_n2_oracles.sh first (build/n2-oracle/)'
      : false;

  test(
    'Dart vs native: CPU per real-time second at 2.4 MS/s WFM',
    skip: skip,
    () async {
      final dir = await Directory.systemTemp.createTemp('n2_perf');
      try {
        final file = '${dir.path}/modes_2400k.cu8';
        final gen = await oracle!.gen('modes', kRate, kSeconds, file);
        expect(gen.exitCode, 0, reason: '${gen.stderr}');

        final rss0 = rssKib();
        final cpu0 = processCpuSeconds();
        final wall = Stopwatch()..start();
        final run = await runDartReference(
          path: file,
          sampleRate: kRate.toDouble(),
          center: 100e6,
          vfoOffset: 250000,
          mode: DemodID.wfm,
          bandwidth: 150000,
        );
        wall.stop();
        final dartCpu = processCpuSeconds() - cpu0;
        final dartRssGrowth = rssKib() - rss0;
        expect(run.left, isNotEmpty);

        final cases =
            (jsonDecode(suite.readAsStringSync()) as Map)['cases'] as List;
        final perf = cases.cast<Map>().firstWhere(
          (c) => c['name'] == 'perf_2400k_wfm',
        );
        final m = (perf['metrics'] as Map).cast<String, num>();
        final nativeCores = m['cpu_cores']!.toDouble();
        final dartCores = dartCpu / kSeconds;
        final report = <String, Object>{
          'iq_seconds': kSeconds,
          'sample_rate': kRate,
          'dart_cpu_seconds': dartCpu,
          'dart_wall_seconds': wall.elapsedMicroseconds / 1e6,
          'dart_cores_for_realtime': dartCores,
          'dart_rss_growth_kib': dartRssGrowth,
          'dart_audio_frames': run.left.length,
          'native_cores_realtime': nativeCores,
          'native_rss_kib': m['rss_kib'] ?? -1,
          'native_rss_growth_kib': m['rss_growth_kib'] ?? -1,
          'native_dropped_samples': m['dropped_samples'] ?? -1,
          'native_audio_dropped_frames': m['audio_dropped_frames'] ?? -1,
          'speedup': dartCores / nativeCores,
        };
        File(
          'build/n2-oracle/perf_compare.json',
        ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
        // ignore: avoid_print
        print('perf: $report');
        // Native must not be costlier than the engine it replaces.
        expect(nativeCores, lessThanOrEqualTo(dartCores));
        // ADR perf budget for the native engine.
        expect(nativeCores, lessThanOrEqualTo(0.5));
      } finally {
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

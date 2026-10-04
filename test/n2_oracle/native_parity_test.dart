// N2 parity oracles: the existing Dart receiver (SDR++ port) is the golden
// reference; the native ABI-v3 library must match it on the same CU8 bytes.
//
// Group 1 ("Dart golden") always runs: it pins the Dart reference against the
// analytic fixture (tone frequency, 48 kHz rate, FFT peak column) so that a
// drifting reference cannot hide a native regression.
//
// Group 2 ("native parity") needs `build/n2-oracle/{n2_oracle,libsdrcore.so}`
// from `native/tests/n2/run_n2_oracles.sh` (or N2_ORACLE_BIN / N2_LIB). When
// they are absent the tests are skipped with the build command; when the
// library lacks ABI v3 the oracle exits 2 and the test is skipped as MISSING
// with the hook list. Expected values are never relaxed for a missing hook.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/modules/radio/demod.dart';

import '../sdrpp/signal_path/harness.dart' show peakOf;
import 'dart_reference.dart';

const int kRate = 1024000;
const double kLo = 100e6;
const double kSeconds = 1.0;

/// Tone tolerance shared with test/sdrpp/modules/radio/radio_module_test.dart.
const double kToneTolHz = 3;

/// Loudness parity: native and Dart audio RMS within ±6 dB (one "twice as
/// loud" step). Larger differences are user-audible level jumps when the
/// adapter switches backends.
const double kLevelTolDb = 6;

/// 48 kHz audio clock parity: frames per IQ second within 0.5 %.
const double kRateTol = 0.005;

class ModeCase {
  const ModeCase(this.name, this.id, this.offset, this.bw, this.tone);
  final String name;
  final DemodID id;
  final double offset; // VFO reference (dial) offset from LO
  final double bw; // RadioController demodParams default bandwidth
  final double tone;
}

// CW: SDR++ / Dart beat tone default 800 Hz (demodulators/cw.dart `tone`).
const List<ModeCase> kModes = [
  ModeCase('wfm', DemodID.wfm, 250000, 150000, 1000),
  ModeCase('nfm', DemodID.nfm, -150000, 12500, 1250),
  ModeCase('am', DemodID.am, 400000, 10000, 700),
  ModeCase('usb', DemodID.usb, 60000, 2800, 1500),
  ModeCase('lsb', DemodID.lsb, -60000, 2800, 1200),
  ModeCase('cw', DemodID.cw, -300000, 200, 800),
];

double rmsOf(List<double> x, {int n = 16384}) {
  final s = x.length - n;
  double a = 0;
  for (int i = s; i < x.length; i++) {
    a += x[i] * x[i];
  }
  return math.sqrt(a / n);
}

double db(double ratio) => 20 * math.log(ratio) / math.ln10;

int argMax(List<double> row) {
  int best = 0;
  for (int i = 1; i < row.length; i++) {
    if (row[i] > row[best]) best = i;
  }
  return best;
}

double median(List<double> row) {
  final s = List<double>.of(row)..sort();
  return s[s.length ~/ 2];
}

void main() {
  late Directory dir;
  late String modesFile;
  late String carrierFile;
  final dart = <String, DartReferenceRun>{};

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('n2_parity_');
    modesFile = '${dir.path}/modes_1024k.cu8';
    carrierFile = '${dir.path}/carrier_1024k.cu8';
    writeCu8Fixture(modesFile, kRate, kSeconds, modeFixture);
    writeCu8Fixture(carrierFile, kRate, 0.5, const [FixtureCarrier('carrier', 200500, 0.25)], noiseRms: 0.01);
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  Future<DartReferenceRun> dartRun(ModeCase m) async => dart[m.name] ??= await runDartReference(
    path: modesFile,
    sampleRate: kRate.toDouble(),
    center: kLo,
    vfoOffset: m.offset,
    mode: m.id,
    bandwidth: m.bw,
  );

  group('Dart golden reference on the shared CU8 fixture', () {
    for (final m in kModes) {
      test('${m.name}: ${m.tone} Hz tone at 48 kHz', () async {
        final r = await dartRun(m);
        final p = peakOf(r.left, 48000);
        expect(p.freq, closeTo(m.tone, kToneTolHz), reason: '$p');
        expect(p.rms, inExclusiveRange(0.02, 1.5));
        expect(r.left.length / kSeconds, closeTo(48000, 48000 * kRateTol + 64));
      });
    }

    test('FFT: 200.5 kHz carrier peak column and peak-to-floor', () async {
      final r = await runDartReference(
        path: carrierFile,
        sampleRate: kRate.toDouble(),
        center: kLo,
        vfoOffset: 0,
        mode: DemodID.nfm,
        bandwidth: 12500,
      );
      expect(r.fftRows.length, inInclusiveRange(9, 11)); // 20 rows/s over 0.5 s
      final row = r.zoomedLatest(1024).toList();
      final colW = kRate / 1024;
      final peakHz = -kRate / 2 + (argMax(row) + 0.5) * colW;
      expect(peakHz, closeTo(200500, colW));
      expect(row[argMax(row)] - median(row), greaterThan(25));
    });
  });

  group('native parity (ABI v3 vs Dart)', () {
    final oracle = NativeOracle.locate();
    final skip = oracle == null
        ? 'n2_oracle not built: run native/tests/n2/run_n2_oracles.sh (or set N2_ORACLE_BIN/N2_LIB)'
        : null;

    /// Runs `n2_oracle demod-file`; returns parsed metrics or null when the
    /// oracle reports MISSING hooks (exit 2), which marks the test skipped.
    Future<Map<String, dynamic>?> native(String fixture, String tag, List<String> args) async {
      final json = '${dir.path}/$tag.json';
      final res = await oracle!.run([
        'demod-file', '--file', fixture, '--rate', '$kRate', '--lo', '${kLo.toInt()}', //
        '--wav', '${dir.path}/$tag.wav', '--json', json, ...args,
      ]);
      if (res.exitCode == 2) {
        markTestSkipped('MISSING native hook(s):\n${res.stdout}');
        return null;
      }
      expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
      final report = jsonDecode(File(json).readAsStringSync()) as Map<String, dynamic>;
      final metrics = (report['cases'] as List).first['metrics'] as Map<String, dynamic>;
      final fft = File('$json.fft.json');
      if (fft.existsSync()) metrics['fft'] = jsonDecode(fft.readAsStringSync());
      return metrics;
    }

    for (final m in kModes) {
      test('${m.name}: tone, level and 48 kHz rate match Dart', skip: skip, () async {
        final ref = await dartRun(m);
        final n = await native(modesFile, 'mode_${m.name}', [
          '--offset', '${m.offset.toInt()}', '--mode', '${m.id.id}', '--bw', '${m.bw.toInt()}', //
        ]);
        if (n == null) return;
        final wav = readStereoWav('${dir.path}/mode_${m.name}.wav');
        expect(wav.rate, 48000);
        final pn = peakOf(wav.left, 48000), pd = peakOf(ref.left, 48000);
        final levelDb = db(rmsOf(wav.left) / rmsOf(ref.left));
        // ignore: avoid_print
        print('${m.name}: native $pn, dart $pd, level ${levelDb.toStringAsFixed(2)} dB');
        expect(pn.freq, closeTo(m.tone, kToneTolHz), reason: 'native tone (analytic)');
        expect(pn.freq, closeTo(pd.freq, kToneTolHz), reason: 'native vs Dart tone');
        expect(
          levelDb.abs(),
          lessThanOrEqualTo(kLevelTolDb),
          reason: 'native/Dart RMS ${levelDb.toStringAsFixed(2)} dB',
        );
        final framesPerIqSecond = wav.left.length / ((n['processed_samples'] as num) / kRate);
        final dartPerIqSecond = ref.left.length / kSeconds;
        expect(framesPerIqSecond, closeTo(dartPerIqSecond, dartPerIqSecond * kRateTol + 64));
        expect(n['dropped_samples'], 0);
      });
    }

    test('FFT row: peak column, level and floor match Dart doZoom', skip: skip, () async {
      final ref = await runDartReference(
        path: carrierFile,
        sampleRate: kRate.toDouble(),
        center: kLo,
        vfoOffset: 0,
        mode: DemodID.nfm,
        bandwidth: 12500,
      );
      final n = await native(carrierFile, 'fft', [
        '--offset',
        '0',
        '--mode',
        '0',
        '--bw',
        '12500',
        '--fft-width',
        '1024',
      ]);
      if (n == null) return;
      final fft = n['fft'] as Map<String, dynamic>;
      final bins = (fft['bins'] as List).map((v) => (v as num).toDouble()).toList();
      final dartRow = ref.zoomedLatest(1024).toList();
      expect(fft['width'], 1024);
      expect(fft['low_hz'], kLo.toInt() - kRate ~/ 2);
      expect(fft['high_hz'], kLo.toInt() + kRate ~/ 2);
      final peakN = argMax(bins), peakD = argMax(dartRow);
      // ignore: avoid_print
      print(
        'fft: native peak $peakN ${bins[peakN]} floor ${median(bins)}; '
        'dart peak $peakD ${dartRow[peakD]} floor ${median(dartRow)}',
      );
      expect((peakN - peakD).abs(), lessThanOrEqualTo(1), reason: 'peak column');
      // Same dBFS convention (RadioController.FftRow): carrier level within 3 dB.
      expect((bins[peakN] - dartRow[peakD]).abs(), lessThanOrEqualTo(3), reason: 'carrier dBFS');
      // Max-decimated noise floor depends on FFT size; 8192-bin Dart vs native
      // size must agree within 6 dB so the waterfall colour map does not jump.
      expect((median(bins) - median(dartRow)).abs(), lessThanOrEqualTo(6), reason: 'noise floor dBFS');
    });
  });
}

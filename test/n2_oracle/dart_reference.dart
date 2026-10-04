// Dart reference receiver for the N2 native parity oracles.
//
// Replays a CU8 IQ file through the existing Dart SDR++ port (FileSource ->
// IQFrontEnd -> RadioModule) with a manual pump, so the native library
// (native/tests/n2/n2_oracle.cpp `demod-file`) and the Dart path consume
// byte-identical IQ. Only test code; production files are untouched.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sdr_flutter/sdrpp/core/core.dart';
import 'package:sdr_flutter/sdrpp/modules/radio/radio_module.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/file_source.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/source_pump.dart';
import 'package:sdr_flutter/ui/waterfall_math.dart' show doZoom;

/// Output of one Dart reference run.
class DartReferenceRun {
  DartReferenceRun(this.left, this.right, this.fftRows, this.fftSize);

  /// Stereo audio at the radio's 48 kHz audio sample rate.
  final List<double> left;
  final List<double> right;

  /// Full-band power rows (dBFS, DC-centred, [fftSize] bins each).
  final List<Float32List> fftRows;
  final int fftSize;

  /// Latest FFT row MAX-decimated (SDR++ doZoom) to [width] columns over the
  /// full band, matching `SdrV3Display(view_offset=0, view_bw=rate, width)`.
  Float32List zoomedLatest(int width) {
    final out = Float32List(width);
    doZoom(0, fftSize, fftSize, width, fftRows.last, out);
    return out;
  }
}

/// Runs [path] (CU8, [sampleRate] complex pairs/s, LO [center] Hz) through the
/// Dart receiver with the VFO reference at [vfoOffset] from LO.
Future<DartReferenceRun> runDartReference({
  required String path,
  required double sampleRate,
  required double center,
  required double vfoOffset,
  required DemodID mode,
  required double bandwidth,
  SquelchMode squelch = SquelchMode.off,
  double squelchLevel = -50,
  int fftSize = 8192,
  double fftRate = 20,
}) async {
  final core = Core();
  core.iqFrontEnd.setFFTSize(fftSize);
  core.iqFrontEnd.setFFTRate(fftRate);
  final rows = <Float32List>[];
  final buf = Float32List(fftSize);
  core.iqFrontEnd.acquireFFTBuffer = (n) => buf;
  core.iqFrontEnd.releaseFFTBuffer = (n) => rows.add(Float32List.fromList(buf));
  final source = FileSource(
    core,
    path: path,
    format: IQFileFormat.cu8,
    sampleRate: sampleRate,
    centerFreq: center,
    mode: PumpMode.manual,
  );
  core.sigpath.sourceManager.registerSource('File', source);
  core.sigpath.sourceManager.selectSource('File');
  core.sigpath.sourceManager.tune(center);
  final factory = RadioModuleFactory(core);
  core.moduleManager.loadModule(factory);
  core.moduleManager.createInstance('Radio', 'radio');
  final radio = core.moduleManager.instances['Radio']!.instance as RadioModule;
  final left = <double>[], right = <double>[];
  radio.stream.bindStream((Float32List d, int n) {
    for (int i = 0; i < n; i++) {
      left.add(d[2 * i]);
      right.add(d[2 * i + 1]);
    }
  });
  radio.selectDemodByID(mode);
  radio.setBandwidth(bandwidth);
  radio.vfo!.setOffset(vfoOffset);
  if (squelch != SquelchMode.off) {
    radio.setSquelchMode(squelch);
    radio.setSquelchLevel(squelchLevel);
  }
  await core.sigpath.sourceManager.start();
  // Exactly one pass over the file (FileSource loops at EOF).
  final blocks = (source.sampleCount / source.pump.blockSize).floor();
  source.pump.pump(blocks);
  source.close();
  return DartReferenceRun(left, right, rows, fftSize);
}

/// One synthetic emitter of the CU8 fixtures (offsets from LO).
class FixtureCarrier {
  const FixtureCarrier(
    this.kind,
    this.offset,
    this.amplitude, {
    this.toneHz = 1000,
    this.deviation = 0,
    this.modIndex = 0.5,
  });
  final String kind; // carrier | fm | am | usb | lsb
  final double offset;
  final double amplitude;
  final double toneHz;
  final double deviation;
  final double modIndex;
}

/// The multi-mode fixture shared with n2_oracle.cpp `mode_carriers()`.
const List<FixtureCarrier> modeFixture = [
  FixtureCarrier('fm', 250000, 0.25, toneHz: 1000, deviation: 75000),
  FixtureCarrier('fm', -150000, 0.2, toneHz: 1250, deviation: 3000),
  FixtureCarrier('am', 400000, 0.2, toneHz: 700, modIndex: 0.6),
  FixtureCarrier('usb', 60000, 0.05, toneHz: 1500),
  FixtureCarrier('lsb', -60000, 0.05, toneHz: 1200),
  FixtureCarrier('carrier', -300000, 0.05),
];

/// Writes a deterministic CU8 file (127.5 ± 127.5·x, xorshift64 Gaussian noise).
/// Same signal model as n2_oracle.cpp `make_cu8`; byte identity with the C++
/// generator is not required because both receivers read this one file.
void writeCu8Fixture(
  String path,
  int rate,
  double seconds,
  List<FixtureCarrier> carriers, {
  double noiseRms = 0.003,
  int seed = 7,
}) {
  final pairs = (seconds * rate).floor();
  final out = Uint8List(2 * pairs);
  final phase = List<double>.filled(carriers.length, 0);
  // xorshift64 (64-bit int on the Dart VM), same recurrence as the C++ generator.
  int s = seed == 0 ? 1 : seed;
  double uniform() {
    s ^= s << 13;
    s ^= s >>> 7;
    s ^= s << 17;
    return ((s >>> 11) + 0.5) / 9007199254740992.0;
  }

  final sigma = noiseRms / math.sqrt2;
  for (int n = 0; n < pairs; n++) {
    final t = n / rate;
    double i = 0, q = 0;
    for (int k = 0; k < carriers.length; k++) {
      final c = carriers[k];
      final tone = math.sin(2 * math.pi * c.toneHz * t);
      double amp = c.amplitude, f = c.offset;
      switch (c.kind) {
        case 'fm':
          f += c.deviation * tone;
        case 'am':
          amp *= 1 + c.modIndex * tone;
        case 'usb':
          f += c.toneHz;
        case 'lsb':
          f -= c.toneHz;
      }
      phase[k] += 2 * math.pi * f / rate;
      if (phase[k] > math.pi) phase[k] -= 2 * math.pi;
      if (phase[k] < -math.pi) phase[k] += 2 * math.pi;
      i += amp * math.cos(phase[k]);
      q += amp * math.sin(phase[k]);
    }
    if (noiseRms > 0) {
      final r = math.sqrt(-2 * math.log(uniform())), th = 2 * math.pi * uniform();
      i += sigma * r * math.cos(th);
      q += sigma * r * math.sin(th);
    }
    out[2 * n] = (127.5 + 127.5 * i).round().clamp(0, 255);
    out[2 * n + 1] = (127.5 + 127.5 * q).round().clamp(0, 255);
  }
  File(path).writeAsBytesSync(out);
}

/// Locates the n2_oracle binary and an ABI-v3 library for the parity tests.
///
/// `N2_ORACLE_BIN` and `N2_LIB` override the defaults written by
/// `native/tests/n2/run_n2_oracles.sh` (`build/n2-oracle/`).
class NativeOracle {
  NativeOracle._(this.binary, this.library);
  final String binary;
  final String library;

  static NativeOracle? locate() {
    final env = Platform.environment;
    final bin = env['N2_ORACLE_BIN'] ?? 'build/n2-oracle/n2_oracle';
    final lib = env['N2_LIB'] ?? 'build/n2-oracle/libsdrcore.so';
    if (!File(bin).existsSync() || !File(lib).existsSync()) return null;
    return NativeOracle._(bin, lib);
  }

  /// Extra flags (e.g. `--allow-version-2` to probe a worker branch).
  List<String> get extraArgs {
    final v = Platform.environment['N2_ORACLE_ARGS'];
    return v == null || v.isEmpty ? const [] : v.split(' ');
  }

  Future<ProcessResult> run(List<String> args) =>
      Process.run(binary, [...args.take(1), '--lib', library, ...extraArgs, ...args.skip(1)]);

  Future<ProcessResult> gen(String fixture, int rate, double seconds, String file) =>
      Process.run(binary, ['gen', '--fixture', fixture, '--rate', '$rate', '--seconds', '$seconds', '--file', file]);
}

/// Reads a 16-bit stereo WAV written by the native `wav:` sink.
({int rate, List<double> left, List<double> right}) readStereoWav(String path) {
  final b = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(b);
  if (String.fromCharCodes(b.sublist(0, 4)) != 'RIFF' || String.fromCharCodes(b.sublist(8, 12)) != 'WAVE') {
    throw FormatException('not a WAV: $path');
  }
  int rate = 0, channels = 0, bits = 0;
  int p = 12;
  while (p + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(p, p + 4));
    final size = bd.getUint32(p + 4, Endian.little);
    if (id == 'fmt ') {
      channels = bd.getUint16(p + 10, Endian.little);
      rate = bd.getUint32(p + 12, Endian.little);
      bits = bd.getUint16(p + 22, Endian.little);
    } else if (id == 'data') {
      if (channels != 2 || bits != 16) throw FormatException('expected 16-bit stereo, got $channels ch $bits bit');
      final left = <double>[], right = <double>[];
      final end = (p + 8 + size).clamp(0, b.length);
      for (int q = p + 8; q + 4 <= end; q += 4) {
        left.add(bd.getInt16(q, Endian.little) / 32768.0);
        right.add(bd.getInt16(q + 2, Endian.little) / 32768.0);
      }
      return (rate: rate, left: left, right: right);
    }
    p += 8 + size + (size & 1);
  }
  throw FormatException('no data chunk: $path');
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/dsp/audio/volume.dart';
import 'package:sdr_flutter/sdrpp/dsp/buffer/packer.dart';
import 'package:sdr_flutter/sdrpp/dsp/buffer/reshaper.dart';
import 'package:sdr_flutter/sdrpp/dsp/buffer/ring_buffer.dart';
import 'package:sdr_flutter/sdrpp/dsp/chain.dart';
import 'package:sdr_flutter/sdrpp/dsp/math/math.dart';
import 'package:sdr_flutter/sdrpp/dsp/math/ops.dart';
import 'package:sdr_flutter/sdrpp/dsp/multirate/rational_resampler.dart';
import 'package:sdr_flutter/sdrpp/dsp/processor.dart';
import 'package:sdr_flutter/sdrpp/dsp/stream.dart';

Float32List ramp(int n, {int stride = 1}) => Float32List.fromList(List.generate(n * stride, (i) => i.toDouble()));

void main() {
  group('math', () {
    test('hzToRads / normalizePhase / sinc / fastAtan2 / step', () {
      expect(hzToRads(1000, 4000), closeTo(dbMPi / 2, 1e-12));
      expect(normalizePhase(4.0), closeTo(4.0 - 2 * flMPi, 1e-9));
      expect(normalizePhase(-4.0), closeTo(-4.0 + 2 * flMPi, 1e-9));
      expect(normalizePhase(flMPi), flMPi);
      expect(sinc(0), 1.0);
      expect(sinc(dbMPi), closeTo(0, 1e-12));
      expect(fastAtan2(1, 1), closeTo(dbMPi / 4, 1e-6));
      expect(fastAtan2(0, 0), 0.0);
      expect(fastAtan2(-1, -1), closeTo(-3 * dbMPi / 4, 1e-6));
      expect(step(0.1), 1.0);
      expect(step(0), -1.0);
    });
  });

  group('ops', () {
    test('conversions', () {
      final c = Float32List.fromList([1, 2, 3, 4]);
      final r = Float32List(2);
      complexToReal(2, c, r);
      expect(r.toList(), [1, 3]);
      final s = Float32List(4);
      monoToStereo(2, r, s);
      expect(s.toList(), [1, 1, 3, 3]);
      // in place mono -> stereo
      final ip = Float32List.fromList([5, 6, 0, 0]);
      monoToStereo(2, ip, ip);
      expect(ip.toList(), [5, 5, 6, 6]);
      realToComplex(2, r, s);
      expect(s.toList(), [1, 0, 3, 0]);
      stereoToMono(2, c, r);
      expect(r.toList(), [1.5, 3.5]);
      lrToStereo(2, Float32List.fromList([1, 2]), Float32List.fromList([3, 4]), s);
      expect(s.toList(), [1, 3, 2, 4]);
      conjugate(2, c, s);
      expect(s.toList(), [1, -2, 3, -4]);
      multiplyC(1, Float32List.fromList([1, 2]), Float32List.fromList([3, 4]), s);
      expect(s.sublist(0, 2).toList(), [-5, 10]);
      magnitude(1, Float32List.fromList([3, 4]), r);
      expect(r[0], 5);
    });

    test('Delay (complex) with arbitrary chunks', () {
      final d = Delay(SampleType.complex, 5);
      final x = ramp(100, stride: 2);
      final out = <double>[];
      int pos = 0;
      for (final c in [3, 1, 17, 40, 39]) {
        final o = Float32List(2 * c);
        d.process(c, Float32List.sublistView(x, 2 * pos, 2 * (pos + c)), o);
        out.addAll(o);
        pos += c;
      }
      expect(out.sublist(0, 10), everyElement(0.0));
      expect(out.sublist(10, 200), x.sublist(0, 190));
    });
  });

  group('stream / chain', () {
    test('DspStream swap/read/flush', () {
      final s = DspStream(SampleType.complex, 16);
      expect(s.read(), 0);
      s.swap(8);
      expect(s.read(), 8);
      s.flush();
      expect(s.read(), 0);
      s.ensureCapacity(100);
      expect(s.capacity, 100);
    });

    test('Chain runs enabled blocks in order, multirate count propagates', () {
      final ch = Chain(SampleType.stereo);
      final vol = Volume(0.5, false); // gain 0.25
      final resamp = RationalResampler(SampleType.stereo, 24000, 48000);
      final vol2 = Volume(2.0, false); // gain 4
      ch.addBlock(vol, true);
      ch.addBlock(resamp, false);
      ch.addBlock(vol2, true);
      final buf = Float32List(4096);
      buf.fillRange(0, 200, 1.0);
      expect(ch.process(100, buf), 100);
      expect(buf[0], 1.0);
      ch.disableBlock(vol2);
      expect(ch.process(100, buf), 100);
      expect(buf[0], 0.25);
      ch.enableBlock(resamp);
      expect(ch.process(100, buf), closeTo(200, 1));
      expect(() => ch.addBlock(vol, true), throwsStateError);
      ch.removeBlock(resamp);
      expect(ch.blockExists(resamp), isFalse);
    });
  });

  group('buffers', () {
    test('RingBuffer maxLatency, wrap-around, readAndSkip', () {
      final rb = RingBuffer(SampleType.real, 10);
      final x = ramp(30);
      expect(rb.write(x, 15), 10); // limited by maxLatency
      final o = Float32List(30);
      expect(rb.read(o, 4), 4);
      expect(o.sublist(0, 4).toList(), [0, 1, 2, 3]);
      expect(rb.write(x, 4, offset: 10), 4);
      expect(rb.readAndSkip(o, 5, 2), 5);
      expect(o.sublist(0, 5).toList(), [4, 5, 6, 7, 8]);
      expect(rb.getReadable(), 3);
      expect(rb.readAndSkip(o, 5, 0), 0);
      expect(rb.read(o, 10), 3);
      expect(o.sublist(0, 3).toList(), [11, 12, 13]);
    });

    List<List<double>> reshape(int keep, int skip, SampleType t, List<int> chunks, int total) {
      final blocks = <List<double>>[];
      final r = Reshaper(t, keep, skip, (d, n) => blocks.add(d.sublist(0, n * t.stride).toList()));
      final x = ramp(total, stride: t.stride);
      int pos = 0, ci = 0;
      while (pos < total) {
        final c = chunks[ci++ % chunks.length].clamp(1, total - pos);
        r.process(c, Float32List.sublistView(x, pos * t.stride, (pos + c) * t.stride));
        pos += c;
      }
      return blocks;
    }

    test('Reshaper keep/skip (positive skip)', () {
      final b = reshape(4, 3, SampleType.real, [5, 1, 9], 30);
      expect(b[0], [0, 1, 2, 3]);
      expect(b[1], [7, 8, 9, 10]);
      expect(b[2], [14, 15, 16, 17]);
      expect(b[3], [21, 22, 23, 24]);
      expect(b.length, 4);
      expect(reshape(4, 3, SampleType.real, [30], 30), b, reason: 'chunk invariance');
    });

    test('Reshaper skip 0 and negative skip (overlap /10 for complex)', () {
      expect(reshape(3, 0, SampleType.real, [2], 9), [
        [0, 1, 2],
        [3, 4, 5],
        [6, 7, 8]
      ]);
      final b = reshape(4, -2, SampleType.complex, [3], 12);
      // first block: 2 zero (delay) samples + 2 new
      expect(b[0], [0, 0, 0, 0, 0, 1, 2, 3]);
      // second block: last 2 samples of previous block /10 + 2 new
      Matcher near(List<double> l) => pairwiseCompare(l, (double e, double a) => (e - a).abs() < 1e-6, 'near');
      expect(b[1], near([0, 0.1, 0.2, 0.3, 4, 5, 6, 7]));
      expect(b[2], near([0.4, 0.5, 0.6, 0.7, 8, 9, 10, 11]));
    });

    test('Packer emits exact blocks', () {
      final blocks = <List<double>>[];
      final p = Packer(SampleType.stereo, 3, (d, n) => blocks.add(d.sublist(0, 2 * n).toList()));
      final x = ramp(8, stride: 2);
      p.process(2, Float32List.sublistView(x, 0, 4));
      p.process(5, Float32List.sublistView(x, 4, 14));
      expect(blocks.length, 2);
      expect(blocks[0], [0, 1, 2, 3, 4, 5]);
      expect(blocks[1], [6, 7, 8, 9, 10, 11]);
      p.process(1, Float32List.sublistView(x, 14, 16));
      expect(blocks.length, 2, reason: '2 of 3 samples buffered');
      p.process(1, Float32List.fromList([100, 101]));
      expect(blocks.length, 3);
      expect(blocks[2], [12, 13, 14, 15, 100, 101]);
    });

    test('Volume = vol², mute', () {
      final v = Volume(0.5, false);
      final x = Float32List.fromList([1, -2]);
      final o = Float32List(2);
      v.process(1, x, o);
      expect(o.toList(), [0.25, -0.5]);
      v.setMuted(true);
      v.process(1, x, o);
      expect(o.toList(), [0, 0]);
      expect(v.getMuted(), isTrue);
    });
  });
}

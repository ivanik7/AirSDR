// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';

void main() {
  test('background skips FFT but keeps the demodulator alive, resumes on return', () async {
    final engine = DspEngine((_) {}, options: const DspEngineOptions(audio: 'null'));
    try {
      await engine.selectSource('synth', <Object?, Object?>{
        'sampleRate': 1024000,
        'pump': 'realTime',
      });
      await engine.start();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(engine.core.iqFrontEnd.fftFrames, greaterThan(0));
      engine.setFft(enabled: false);
      final fft = engine.core.iqFrontEnd.fftFrames;
      final audio = engine.radio.audioFrames;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(engine.core.iqFrontEnd.fftFrames, fft);
      expect(engine.radio.audioFrames, greaterThan(audio));
      engine.setFft(enabled: true);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(engine.core.iqFrontEnd.fftFrames, greaterThan(fft));
    } finally {
      await engine.shutdown();
    }
  });
}

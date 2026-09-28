import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';

void main() {
  test(
    'offset-only tuning updates the DSP frequency translator immediately',
    () {
      final engine = DspEngine(
        (_) {},
        options: const DspEngineOptions(audio: 'null'),
      );
      engine.coreConfig.disableAutoSave();
      engine.radioConfig.disableAutoSave();
      final vfo = engine.radio.vfo!;
      final center = engine.centerFrequency;
      engine.tune(offset: 25000);
      expect(engine.centerFrequency, center);
      expect(vfo.getOffset(), 25000);
      expect(vfo.dspVFO.offset, 25000);
      engine.tune(center: center + 25000, offset: 0);
      expect(vfo.dspVFO.offset, 0);
    },
  );
}

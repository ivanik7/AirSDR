import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/sdrpp/modules/radio/radio_module.dart';

void main() {
  test('radio config (demod mode) is file-backed under configDir', () {
    // Regression: DspEngine set the radio config path, but RadioModuleFactory
    // .init() reset it to null, so mode/bandwidth/squelch were never saved
    // (Android force-stop relaunched in WFM). Autosave writes this same file.
    final dir = Directory.systemTemp.createTempSync('dsp_engine_cfg');
    try {
      final engine = DspEngine(
        (_) {},
        options: DspEngineOptions(configDir: dir.path, audio: 'null'),
      );
      final path = '${dir.path}${Platform.pathSeparator}radio_config.json';
      expect(engine.radioConfig.path, File(path).absolute.path);
      engine.radioConfig.disableAutoSave(); // deterministic: no timers
      engine.setMode(DemodID.nfm.id);
      engine.radioConfig.flush();
      final saved = jsonDecode(File(path).readAsStringSync()) as Map;
      expect((saved['Radio'] as Map)['selectedDemodId'], DemodID.nfm.id);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}

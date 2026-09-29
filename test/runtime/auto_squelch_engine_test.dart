// DspEngine ↔ auto squelch (app extension): protocol, state/stats, resets on retune/gain.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/runtime/dsp_protocol.dart';
import 'package:sdr_flutter/sdrpp/modules/radio/radio_module.dart';

void main() {
  DspEngine engine() {
    final e = DspEngine((_) {}, options: const DspEngineOptions(audio: 'null'));
    e.coreConfig.disableAutoSave();
    e.radioConfig.disableAutoSave();
    return e;
  }

  test('setSquelch mode/autoOffset → radio; state reports mode, offset, availability', () async {
    final e = engine();
    e.setMode(DemodID.nfm.id);
    await e.handle(<String, Object?>{
      DspMsg.cmd: DspCmd.setSquelch,
      'mode': 'auto',
      'autoOffset': 3.0,
    });
    expect(e.radio.squelchMode, SquelchMode.auto);
    expect(e.radio.autoSquelch.offsetDb, 3);
    var s = e.stateMap();
    expect(s['squelchMode'], 'auto');
    expect(s['squelchAutoOffset'], 3);
    expect(s['squelchAutoAllowed'], isTrue);
    expect(
      s['squelchEnabled'],
      isFalse,
      reason: 'legacy flag = power squelch only',
    );
    expect(e.statsMap()['squelch'], isA<Map<String, Object?>>());

    // Legacy form still works and switches to the manual power squelch.
    await e.handle(<String, Object?>{
      DspMsg.cmd: DspCmd.setSquelch,
      'enabled': true,
      'level': -45.0,
    });
    expect(e.radio.squelchMode, SquelchMode.power);
    expect(e.radio.squelchLevel, -45);
    s = e.stateMap();
    expect(s['squelchMode'], 'power');
    expect(s['squelchEnabled'], isTrue);
    expect(e.statsMap().containsKey('squelch'), isFalse);

    e.setMode(DemodID.wfm.id);
    expect(e.stateMap()['squelchAutoAllowed'], isFalse);
    await e.shutdown();
  });

  test(
    'retune / gain change reset the auto squelch (the learnt floor is dropped)',
    () async {
      final e = engine();
      e.setMode(DemodID.am.id);
      e.setSquelch(mode: 'auto');
      final a = e.radio.autoSquelch;
      // 1 s of deterministic pseudo-noise at the AM IF rate (15 kHz).
      void learn() {
        const n = 1500;
        final x = Float32List(2 * n);
        for (var b = 0; b < 10; b++) {
          for (var k = 0; k < 2 * n; k++) {
            x[k] = ((k * 7919 + b * 131) % 101 - 50) / 5000.0;
          }
          a.analyze(n, x);
        }
      }

      learn();
      expect(a.floorDb, isNotNull);
      e.tune(offset: 5000);
      expect(a.floorDb, isNull, reason: 'retune resets');
      learn();
      await e.handle(<String, Object?>{
        DspMsg.cmd: DspCmd.setGain,
        'value': 20.0,
      });
      // No source selected: setGain is a no-op on the device but still resets (harmless).
      expect(a.floorDb, isNull, reason: 'gain change resets');
      learn();
      e.tune(offset: 5000); // same offset: not a retune, keeps the floor
      expect(a.floorDb, isNotNull);
      await e.shutdown();
    },
  );

  test(
    'AM noise floors stay separate per tuned channel and gain invalidates both',
    () async {
      final e = engine();
      e.setMode(DemodID.am.id);
      e.setSquelch(mode: 'auto');
      final a = e.radio.autoSquelch;
      void learn(double amplitude) {
        const n = 1500;
        final x = Float32List(2 * n);
        for (var b = 0; b < 10; b++) {
          for (var k = 0; k < x.length; k++) {
            x[k] = amplitude * ((k * 7919 + b * 131) % 101 - 50) / 5000;
          }
          a.analyze(n, x);
        }
      }

      e.tune(center: 118100000);
      learn(1);
      final first = a.floorDb;
      expect(first, isNotNull);
      e.tune(center: 118125000);
      expect(a.floorDb, isNull);
      learn(3);
      final second = a.floorDb;
      expect(second, isNotNull);
      expect(second, greaterThan(first!));
      e.tune(center: 118100000);
      expect(a.floorDb, closeTo(first, 0.01));
      e.tune(center: 118125000);
      expect(a.floorDb, closeTo(second!, 0.01));
      await e.handle(<String, Object?>{
        DspMsg.cmd: DspCmd.setGain,
        'value': 20.0,
      });
      expect(a.floorDb, isNull);
      e.tune(center: 118100000);
      expect(a.floorDb, isNull);
      await e.shutdown();
    },
  );
}

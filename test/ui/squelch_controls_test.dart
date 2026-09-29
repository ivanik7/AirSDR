// SPDX-License-Identifier: GPL-3.0-or-later
// Squelch controls of the legacy UI: Выкл / Ручной / Авто (app extension).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/squelch_controls.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _StatusRadio extends DemoRadioController {
  AutoSquelchStatus? status;
  @override
  AutoSquelchStatus? get autoSquelchStatus => squelchType == SquelchType.auto ? status : null;
}

Future<void> _pump(WidgetTester t, RadioController r) => t.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: ListenableBuilder(
        listenable: r,
        builder: (_, _) => SquelchControls(controller: r),
      ),
    ),
  ),
);

String _status(WidgetTester t) => t.widget<Text>(find.byKey(const ValueKey('squelchStatus'))).data!;

void main() {
  testWidgets('Выкл → Ручной → Авто in NFM; slider switches level ↔ offset', (t) async {
    final r = _StatusRadio()..setMode(DemodMode.nfm);
    await _pump(t, r);
    expect(_status(t), 'Выкл.');
    expect(find.byKey(const ValueKey('squelchLevelSlider')), findsNothing);
    expect(find.byKey(const ValueKey('squelchAutoOffsetSlider')), findsNothing);

    await t.tap(find.text('Ручной'));
    await t.pump();
    expect(r.squelchType, SquelchType.manual);
    expect(r.squelchEnabled, isTrue);
    expect(find.byKey(const ValueKey('squelchLevelSlider')), findsOneWidget);
    expect(_status(t), startsWith('Ручной · порог'));

    await t.tap(find.text('Авто'));
    await t.pump();
    expect(r.squelchType, SquelchType.auto);
    expect(r.squelchEnabled, isFalse);
    expect(find.byKey(const ValueKey('squelchLevelSlider')), findsNothing);
    expect(find.byKey(const ValueKey('squelchAutoOffsetSlider')), findsOneWidget);
    expect(_status(t), 'Авто по шуму ЧМ · ждёт приём');

    // Live status from the DSP.
    r.status = const AutoSquelchStatus(open: true, metricDb: 18, thresholdDb: 6);
    r.setAutoSquelchOffset(0); // notify
    await t.pump();
    expect(_status(t), 'Авто по шуму ЧМ · ОТКРЫТ · тишина 18 / порог 6 dB');
    expect(find.byKey(const ValueKey('squelchOpenIcon')), findsOneWidget);

    // Offset slider drag → controller (clamped to the contract range).
    await t.drag(find.byKey(const ValueKey('squelchAutoOffsetSlider')), const Offset(2000, 0));
    await t.pump();
    expect(r.autoSquelchOffset, RadioController.maxAutoSquelchOffset);
    expect(find.text('+20 dB'), findsOneWidget);

    await t.tap(find.text('Выкл'));
    await t.pump();
    expect(r.squelchType, SquelchType.off);
    expect(_status(t), 'Выкл.');
  });

  testWidgets('AM: level squelch; WFM: Авто disabled and auto falls back to Выкл', (t) async {
    final r = _StatusRadio()..setMode(DemodMode.am);
    await _pump(t, r);
    await t.tap(find.text('Авто'));
    await t.pump();
    expect(r.squelchType, SquelchType.auto);
    r.status = const AutoSquelchStatus(open: false, metricDb: -70, thresholdDb: null);
    r.setAutoSquelchOffset(0);
    await t.pump();
    expect(_status(t), 'Авто по уровню · закрыт · учит шумовой пол…');

    r.setMode(DemodMode.wfm);
    await t.pump();
    expect(r.squelchType, SquelchType.off);
    await t.tap(find.text('Авто'));
    await t.pump();
    expect(r.squelchType, SquelchType.off, reason: 'segment disabled: no detector for WFM');
  });

  testWidgets('CW: no SDR++ power squelch, but Авто (level) is available', (t) async {
    final r = _StatusRadio()..setMode(DemodMode.cw);
    await _pump(t, r);
    await t.tap(find.text('Ручной'));
    await t.pump();
    expect(r.squelchType, SquelchType.off);
    await t.tap(find.text('Авто'));
    await t.pump();
    expect(r.squelchType, SquelchType.auto);
  });
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Squelch controls of the legacy UI: Off / Manual / Auto (app extension).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/squelch_controls.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _StatusRadio extends DemoRadioController {
  AutoSquelchStatus? status;
  @override
  AutoSquelchStatus? get autoSquelchStatus =>
      squelchType == SquelchType.auto ? status : null;
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

String _status(WidgetTester t) =>
    t.widget<Text>(find.byKey(const ValueKey('squelchStatus'))).data!;

void main() {
  testWidgets('Off → Manual → Auto in NFM; slider switches level ↔ offset', (
    t,
  ) async {
    final r = _StatusRadio()..setMode(DemodMode.nfm);
    await _pump(t, r);
    expect(_status(t), 'Disabled');
    expect(find.byKey(const ValueKey('squelchLevelSlider')), findsNothing);
    expect(find.byKey(const ValueKey('squelchAutoOffsetSlider')), findsNothing);

    await t.tap(find.text('Manual'));
    await t.pump();
    expect(r.squelchType, SquelchType.manual);
    expect(r.squelchEnabled, isTrue);
    expect(find.byKey(const ValueKey('squelchLevelSlider')), findsOneWidget);
    expect(_status(t), startsWith('Manual · threshold'));

    await t.tap(find.text('Auto'));
    await t.pump();
    expect(r.squelchType, SquelchType.auto);
    expect(r.squelchEnabled, isFalse);
    expect(find.byKey(const ValueKey('squelchLevelSlider')), findsNothing);
    expect(
      find.byKey(const ValueKey('squelchAutoOffsetSlider')),
      findsOneWidget,
    );
    expect(_status(t), 'Auto noise (NFM) · waiting for signal');

    // Live status from the DSP.
    r.status = const AutoSquelchStatus(
      open: true,
      metricDb: 18,
      thresholdDb: 6,
    );
    r.setAutoSquelchOffset(0); // notify
    await t.pump();
    expect(_status(t), 'Auto noise (NFM) · OPEN · silence 18 / threshold 6 dB');
    expect(find.byKey(const ValueKey('squelchOpenIcon')), findsOneWidget);

    // Offset slider drag → controller (clamped to the contract range).
    await t.drag(
      find.byKey(const ValueKey('squelchAutoOffsetSlider')),
      const Offset(2000, 0),
    );
    await t.pump();
    expect(r.autoSquelchOffset, RadioController.maxAutoSquelchOffset);
    expect(find.text('+20 dB'), findsOneWidget);

    await t.tap(find.text('Off'));
    await t.pump();
    expect(r.squelchType, SquelchType.off);
    expect(_status(t), 'Disabled');
  });

  testWidgets(
    'AM: level squelch; WFM: Auto disabled and auto falls back to Off',
    (t) async {
      final r = _StatusRadio()..setMode(DemodMode.am);
      await _pump(t, r);
      await t.tap(find.text('Auto'));
      await t.pump();
      expect(r.squelchType, SquelchType.auto);
      r.status = const AutoSquelchStatus(
        open: false,
        metricDb: -70,
        thresholdDb: null,
      );
      r.setAutoSquelchOffset(0);
      await t.pump();
      expect(_status(t), 'Auto level · closed · learning noise floor…');

      r.setMode(DemodMode.wfm);
      await t.pump();
      expect(r.squelchType, SquelchType.off);
      await t.tap(find.text('Auto'));
      await t.pump();
      expect(
        r.squelchType,
        SquelchType.off,
        reason: 'segment disabled: no detector for WFM',
      );
    },
  );

  testWidgets('CW: no SDR++ power squelch, but Auto (level) is available', (
    t,
  ) async {
    final r = _StatusRadio()..setMode(DemodMode.cw);
    await _pump(t, r);
    await t.tap(find.text('Manual'));
    await t.pump();
    expect(r.squelchType, SquelchType.off);
    await t.tap(find.text('Auto'));
    await t.pump();
    expect(r.squelchType, SquelchType.auto);
  });

  testWidgets(
    'fits a 294 px card (Fold cover screen) without overflow in every mode',
    (t) async {
      final r = _StatusRadio()..setMode(DemodMode.nfm);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 294,
                child: ListenableBuilder(
                  listenable: r,
                  builder: (_, _) => SquelchControls(controller: r),
                ),
              ),
            ),
          ),
        ),
      );
      for (final type in SquelchType.values) {
        r.status = const AutoSquelchStatus(
          open: true,
          metricDb: -120,
          thresholdDb: -130,
        );
        r.setSquelchType(type);
        await t.pump();
        expect(t.takeException(), isNull, reason: '$type');
      }
    },
  );
}

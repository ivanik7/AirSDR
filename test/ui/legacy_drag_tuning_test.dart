import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/legacy/step_grid.dart';
import 'package:sdr_flutter/ui/sdr_ui_state.dart';
import 'package:sdr_flutter/ui/waterfall_model.dart';
import 'package:sdr_flutter/ui/colormaps.dart';

import 'dart:typed_data';

class CountingRadio extends DemoRadioController {
  final centers = <double>[];
  @override
  void setTuning({required double centerFrequency, required double vfoOffset}) {
    if (centerFrequency != this.centerFrequency) centers.add(centerFrequency);
    super.setTuning(centerFrequency: centerFrequency, vfoOffset: vfoOffset);
  }
}

void main() {
  testWidgets('continuous drag throttles LO, trails and cancels pending work', (
    tester,
  ) async {
    final radio = CountingRadio();
    final receiver = CenteredReceiver(radio);
    receiver.beginDrag();
    for (var i = 0; i < 10; i++) {
      receiver.dragBy(12500); // one node of the default 12.5 kHz grid
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(radio.centers, hasLength(4));
    receiver.dragBy(12500); // one node of the default 12.5 kHz grid
    receiver.endDrag();
    expect(radio.centers, hasLength(5));
    expect(radio.vfoOffset, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(radio.centers, hasLength(5));
    receiver.beginDrag();
    await tester.pump(const Duration(seconds: 1));
    expect(radio.centers, hasLength(5));
    receiver.endDrag();
    receiver.dispose();
    radio.dispose();
  });

  testWidgets(
    'edge shift restarts throttle and cancel suppresses trailing tune',
    (tester) async {
      final radio = CountingRadio();
      final receiver = CenteredReceiver(radio);
      receiver.beginDrag();
      receiver.dragBy(radio.sampleRate / 2);
      expect(radio.centers, hasLength(1));
      receiver.dragBy(1000);
      await tester.pump(const Duration(milliseconds: 249));
      expect(radio.centers, hasLength(1));
      receiver.endDrag();
      expect(radio.centers, hasLength(2));
      await tester.pump(const Duration(seconds: 1));
      expect(radio.centers, hasLength(2));
      receiver.dispose();
      radio.dispose();
    },
  );

  test(
    'legacy display reprojects FFT and old waterfall rows in absolute Hz',
    () {
      final radio = CountingRadio();
      final wf = WaterfallModel(width: 8, height: 2, autoSchedule: false);
      final ui = SdrUiState(radio, waterfall: wf, centerDisplayOnVfo: true);
      final center = radio.centerFrequency;
      final span = radio.sampleRate;
      wf.pushRow(
        Float32List.fromList([-100, -100, -100, -100, 0, -100, -100, -100]),
        center - span / 2,
        center + span / 2,
      );
      wf.flush();
      radio.setTuning(centerFrequency: center, vfoOffset: span / 4);
      wf.flush();
      expect(ui.displayViewport.freqToX(radio.tunedFrequency, 800), 400);
      expect(ui.displayVfo.pixels(span, 800, 0).line, 400);
      expect(wf.lowerFreq, radio.tunedFrequency - span / 2);
      expect(
        wf.latestFFT[2],
        0,
      ); // old peak at the original centre now moves left
      expect(
        wf.rgba[wf.head * 8 + 7],
        kOpaqueBlack,
      ); // outside the physical IQ band
      expect(wf.rgba[wf.head * 8 + 2], wf.palette.last);
      radio.setTuning(centerFrequency: center + span / 4, vfoOffset: 0);
      wf.flush();
      expect(wf.latestFFT[2], 0); // same RF peak after the LO catches up
      ui.dispose();
      radio.dispose();
    },
  );
  test(
    'drag moves DSP VFO without LO tuning; edge shifts half the IQ span',
    () {
      final radio = CountingRadio();
      final receiver = CenteredReceiver(radio);
      final initial = radio.centerFrequency;
      final span = radio.sampleRate;
      receiver.beginDrag();
      receiver.dragBy(25000);
      expect(radio.centers, isEmpty);
      expect(radio.tunedFrequency, initial + 25000);
      expect(radio.vfoOffset, 25000);
      receiver.dragBy(span / 2);
      expect(radio.centers, [initial + span / 2]);
      // The VFO stays on the 12.5 kHz step grid (task t_33f07c06).
      final onGrid = snapToStep((initial + span / 2 + 25000).round(), 12500);
      expect(radio.tunedFrequency, onGrid);
      receiver.endDrag();
      expect(radio.centerFrequency, radio.tunedFrequency);
      expect(radio.vfoOffset, 0);
      expect(radio.centers.last, onGrid);
      radio.dispose();
    },
  );

  test(
    'negative edge shift and cancel recenter once; direct nudge stays centered',
    () {
      final radio = CountingRadio();
      final receiver = CenteredReceiver(radio);
      final initial = radio.centerFrequency;
      receiver.beginDrag();
      receiver.dragBy(-radio.sampleRate / 2);
      expect(radio.centers, [initial - radio.sampleRate / 2]);
      receiver
          .endDrag(); // onHorizontalDragCancel uses the same completion path.
      expect(radio.vfoOffset, 0);
      expect(radio.centerFrequency, radio.tunedFrequency);
      radio.centers.clear();
      receiver.nudge(1);
      expect(radio.centers, hasLength(1));
      expect(radio.vfoOffset, 0);
      radio.dispose();
    },
  );

  testWidgets(
    'ruler drag keeps offset until finger release, including shell listener',
    (tester) async {
      final radio = CountingRadio();
      final favorites = FavoritesRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );
      final start = tester.getCenter(find.byKey(const ValueKey('tuningRuler')));
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(-40, 0));
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(radio.centers, isEmpty);
      expect(radio.vfoOffset, isNot(0));
      await gesture.up();
      await tester.pump();
      expect(radio.centers, hasLength(1));
      expect(radio.vfoOffset, 0);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );

  testWidgets('spectrum drag offsets VFO; cancellation recenters', (
    tester,
  ) async {
    final radio = CountingRadio();
    final favorites = FavoritesRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    final start = tester.getCenter(
      find.byKey(const ValueKey('legacySpectrumDrag')),
    );
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(radio.centers, isEmpty);
    expect(radio.vfoOffset, isNot(0));
    await gesture.cancel();
    await tester.pump();
    expect(radio.centers, hasLength(1));
    expect(radio.vfoOffset, 0);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Receive frequency is bound to the selected step grid (task t_33f07c06):
// after any finished retune the tuned frequency is a multiple of the step
// (relative to 0 Hz), in integer Hz, inside the device range.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/channels/channel_controller.dart';
import 'package:sdr_flutter/ui/channels/channels.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/legacy/step_grid.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

/// Records every LO the "tuner" receives.
class TunerRadio extends DemoRadioController {
  final centers = <double>[];
  @override
  void setTuning({required double centerFrequency, required double vfoOffset}) {
    if (centerFrequency != this.centerFrequency) centers.add(centerFrequency);
    super.setTuning(centerFrequency: centerFrequency, vfoOffset: vfoOffset);
  }
}

class NoDeviceRadio extends TunerRadio {
  @override
  SdrDeviceInfo? get selectedDevice => null;
}

String shownFrequency(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('legacyFrequency'))).data!;

int stepIndexOf(int hz) =>
    CenteredReceiver.steps.indexWhere((s) => s.round() == hz);

CenteredReceiver receiverWithStep(RadioController radio, int hz) {
  final r = CenteredReceiver(radio);
  r.setStepHz(hz);
  expect(r.stepHz, hz);
  return r;
}

void expectOnGrid(RadioController radio, int step, int hz) {
  expect(radio.tunedFrequency, hz.toDouble());
  expect(radio.centerFrequency, hz.toDouble());
  expect(radio.vfoOffset, 0);
  expect(radio.tunedFrequency.round() % step, 0);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('snapToStep (integer Hz, 0-based grid)', () {
    test('nearest node; 180 kHz → 200 kHz, 118.180 → 118.200 MHz', () {
      expect(snapToStep(180000, 100000), 200000);
      expect(snapToStep(118180000, 100000), 118200000);
      expect(snapToStep(118120000, 100000), 118100000);
      expect(snapToStep(118200000, 100000), 118200000);
      expect(snapToStep(145506249, 12500), 145500000);
      expect(snapToStep(145506251, 12500), 145512500);
      expect(snapToStep(118203124, 6250), 118200000);
    });

    test('tie (exactly half a step) rounds up, toward higher frequency', () {
      expect(snapToStep(150000, 100000), 200000);
      expect(snapToStep(118150000, 100000), 118200000);
      expect(snapToStep(118203125, 6250), 118206250);
      expect(snapToStep(2500, 5000), 5000);
    });

    test('never rounds out of the device range', () {
      // Upper bound not on the grid: nearest in-range node is below.
      expect(snapToStep(1766000000, 100000, max: 1765950000), 1765900000);
      expect(snapToStep(1765960000, 100000, max: 1765950000), 1765900000);
      // Lower bound not on the grid: nearest in-range node is above.
      expect(snapToStep(24010000, 100000, min: 24050000), 24100000);
      // Bounds on the grid: the bound itself.
      expect(snapToStep(24000000, 100000, min: 24000000), 24000000);
      expect(snapToStep(2200000000, 100000, max: 2200000000), 2200000000);
      // Zero is never a receive frequency.
      expect(snapToStep(20000, 100000, min: 1), 100000);
    });

    test('stepFrom moves to the neighbour node, not current+step', () {
      expect(stepFrom(118180000, 100000, 1), 118200000);
      expect(stepFrom(118180000, 100000, -1), 118100000);
      expect(stepFrom(118200000, 100000, 1), 118300000);
      expect(stepFrom(118200000, 100000, -1), 118100000);
      expect(stepFrom(180000, 100000, 1), 200000);
      expect(stepFrom(180000, 100000, -1), 100000);
      // At the range edge: stays on the last in-range node.
      expect(stepFrom(2200000000, 100000, 1, max: 2200000000), 2200000000);
      expect(stepFrom(24000000, 100000, -1, min: 24000000), 24000000);
    });

    test('no float drift over many steps (6.25 kHz)', () {
      var f = 100000000;
      for (var i = 0; i < 100000; i++) {
        f = stepFrom(f, 6250, 1);
      }
      expect(f, 100000000 + 100000 * 6250);
    });
  });

  group('CenteredReceiver on a 100 kHz grid', () {
    test('keypad 0.180 → 200 kHz; 118.180 → 118.200 MHz', () {
      final radio = TunerRadio();
      radio.selectDevice(radio.devices[1]); // HackRF demo: 1 MHz..6 GHz
      final r = receiverWithStep(radio, 100000);
      r.tune(1180000);
      expectOnGrid(radio, 100000, 1200000);
      for (final k in ['1', '1', '8', '.', '1', '8', 'OK']) {
        r.pressKey(k);
      }
      expectOnGrid(radio, 100000, 118200000);
      radio.dispose();
    });

    test('180 kHz input snaps to 200 kHz when the device allows it', () {
      final radio = NoDeviceRadio(); // no device: 1 Hz .. 999 GHz
      final r = receiverWithStep(radio, 100000);
      r.tune(180000);
      expectOnGrid(radio, 100000, 200000);
      radio.dispose();
    });

    test('◀ ▶ from an off-grid state go to the neighbour nodes', () {
      final radio = TunerRadio();
      final r = receiverWithStep(radio, 100000);
      radio.setTuning(centerFrequency: 118180000, vfoOffset: 0);
      r.nudge(1);
      expectOnGrid(radio, 100000, 118200000);
      radio.setTuning(centerFrequency: 118180000, vfoOffset: 0);
      r.nudge(-1);
      expectOnGrid(radio, 100000, 118100000);
      r.nudge(-1);
      expectOnGrid(radio, 100000, 118000000);
      r.nudge(1);
      r.nudge(1);
      expectOnGrid(radio, 100000, 118200000);
      radio.dispose();
    });

    test('changing the step immediately snaps the current frequency', () {
      final radio = TunerRadio();
      final r = receiverWithStep(radio, 12500);
      r.tune(118187500);
      expectOnGrid(radio, 12500, 118187500);
      radio.centers.clear();
      r.setStepHz(100000);
      expectOnGrid(radio, 100000, 118200000);
      expect(radio.centers, [118200000], reason: 'one LO retune');
      // cycleStep (the ШАГ button) does the same.
      r.setStepHz(25000);
      r.tune(118175000);
      r.cycleStep(); // 25 kHz → 100 kHz
      expect(r.stepHz, 100000);
      expectOnGrid(radio, 100000, 118200000);
      radio.dispose();
    });

    test('drag: no LO per step, release lands on the grid and centers', () {
      final radio = TunerRadio();
      final r = receiverWithStep(radio, 100000);
      r.tune(118200000);
      radio.centers.clear();
      r.beginDrag();
      r.dragBy(-20000); // raw 118.180
      expect(radio.centers, isEmpty);
      expect(radio.tunedFrequency, 118200000);
      r.dragBy(-40000); // raw 118.140 → 118.100
      expect(radio.centers, isEmpty);
      expect(radio.tunedFrequency, 118100000);
      expect(radio.vfoOffset, -100000);
      r.dragBy(-3000); // raw 118.137
      r.endDrag();
      expectOnGrid(radio, 100000, 118100000);
      expect(radio.centers, [118100000]);
      radio.dispose();
    });

    test('channel slot and preset apply the current grid, keep entries', () {
      final radio = TunerRadio();
      final r = receiverWithStep(radio, 100000);
      final repo = ChannelsRepository();
      final favorites = FavoritesRepository();
      final ctl = ChannelController(
        radio: radio,
        receiver: r,
        channels: repo,
        favorites: favorites,
      );
      ctl.attach();
      final a = repo.add(frequencyHz: 118180000, mode: DemodMode.am);
      final b = repo.add(frequencyHz: 101200000, mode: DemodMode.wfm);
      expect(ctl.select(b.id), isTrue);
      expect(ctl.select(a.id), isTrue);
      expectOnGrid(radio, 100000, 118200000);
      // Preset with an off-grid frequency (stored entry is not modified).
      r.apply(145512500, DemodMode.nfm);
      expectOnGrid(radio, 100000, 145500000);
      ctl.select(a.id);
      expectOnGrid(radio, 100000, 118200000);
      favorites.dispose();
      repo.dispose();
      radio.dispose();
    });

    test('restored off-grid frequency is snapped on recenter', () {
      final radio = TunerRadio();
      radio.setTuning(centerFrequency: 118130000, vfoOffset: 50000);
      final r = receiverWithStep(radio, 100000);
      r.resetOffset();
      expectOnGrid(radio, 100000, 118200000);
      radio.dispose();
    });

    test('range bounds: nudge and input never leave the device range', () {
      final radio = TunerRadio();
      radio.selectDevice(radio.devices.first); // 24 MHz .. 1766 MHz
      final r = receiverWithStep(radio, 100000);
      r.tune(24000000);
      r.nudge(-1);
      expectOnGrid(radio, 100000, 24000000);
      r.tune(1766000000);
      r.nudge(1);
      expectOnGrid(radio, 100000, 1766000000);
      expect(() => r.tune(23000000), throwsArgumentError);
      expect(() => r.tune(1767000000), throwsArgumentError);
      radio.dispose();
    });
  });

  testWidgets('shell: step persists, UI text = controller = tuner', (
    tester,
  ) async {
    final radio = TunerRadio();
    final favorites = FavoritesRepository();
    await favorites.load();
    // Tall enough that the frequency text and the keypad are both built.
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    radio.setTuning(centerFrequency: 118187500, vfoOffset: 0);
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    await tester.pump();
    // Default step 12.5 kHz: 118.1875 is on its grid.
    expect(radio.tunedFrequency, 118187500);
    // ШАГ 12.5 → 25 → 100 kHz.
    await tester.tap(find.textContaining('ШАГ'));
    await tester.pump();
    await tester.tap(find.textContaining('ШАГ'));
    await tester.pump();
    expect(find.text('ШАГ 100.00 кГц'), findsOneWidget);
    expectOnGrid(radio, 100000, 118200000);
    expect(radio.centers.last, 118200000);
    expect(shownFrequency(tester), '118.200');
    // The ▶ nudge is gone with the tuning ruler: retune from the keypad.
    for (final k in ['1', '1', '8', '.', '3', 'OK']) {
      await tester.tap(find.byKey(ValueKey('key-$k')));
      await tester.pump();
    }
    expectOnGrid(radio, 100000, 118300000);
    expect(shownFrequency(tester), '118.300');
    for (final k in ['1', '1', '8', '.', '1', '8', 'OK']) {
      await tester.tap(find.byKey(ValueKey('key-$k')));
      await tester.pump();
    }
    expectOnGrid(radio, 100000, 118200000);
    expect(shownFrequency(tester), '118.200');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(CenteredReceiver.stepStorageKey), 100000);
    await tester.pumpWidget(const SizedBox());

    // A new shell restores the step and keeps the grid. (Forget the channel
    // slots, or the active slot would retune to its own 118.200 MHz.)
    await prefs.remove(ChannelsRepository.storageKey);
    final radio2 = TunerRadio();
    radio2.setTuning(centerFrequency: 145512500, vfoOffset: 0);
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio2, favorites: favorites),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('ШАГ 100.00 кГц'), findsOneWidget);
    expectOnGrid(radio2, 100000, 145500000);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    radio2.dispose();
    favorites.dispose();
  });

  test('stepIndexOf helper sanity', () {
    expect(stepIndexOf(100000), CenteredReceiver.steps.indexOf(100000));
  });

  group('formatMhz', () {
    test('kHz precision by default, more only when needed', () {
      expect(formatMhz(118200000), '118.200');
      expect(formatMhz(118206250), '118.20625');
      expect(formatMhz(145512500), '145.5125');
    });
  });

  testWidgets(
    '6.25 kHz grid: main text and channel tile show the exact value',
    (tester) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final radio = TunerRadio();
      final favorites = FavoritesRepository();
      await favorites.load();
      radio.setTuning(centerFrequency: 118206250, vfoOffset: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );
      await tester.pump();
      // Default 12.5 kHz: 118.20625 is a tie → 118.2125. Cycling through
      // 25, 100, 200, 5 and 6.25 kHz lands on 118.200.
      expect(radio.tunedFrequency, 118212500);
      await tester.tap(find.textContaining('ШАГ'));
      await tester.pump();
      await tester.tap(find.textContaining('ШАГ'));
      await tester.pump();
      await tester.tap(find.textContaining('ШАГ'));
      await tester.pump();
      await tester.tap(find.textContaining('ШАГ'));
      await tester.pump();
      await tester.tap(find.textContaining('ШАГ'));
      await tester.pump();
      expect(find.text('ШАГ 6.25 кГц'), findsOneWidget);
      expectOnGrid(radio, 6250, 118200000);
      // 118.20625 typed on the 6.25 kHz grid stays exact.
      for (final k in ['1', '1', '8', '.', '2', '0', '6', '2', '5', 'OK']) {
        await tester.tap(find.byKey(ValueKey('key-$k')));
        await tester.pump();
      }
      expectOnGrid(radio, 6250, 118206250);
      expect(shownFrequency(tester), '118.20625');
      // The first-run channel slot follows the receiver.
      expect(find.text('118.20625'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );
}

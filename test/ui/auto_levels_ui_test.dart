// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/auto_levels.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/main_screen.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';
import 'package:sdr_flutter/ui/sdr_ui_state.dart';
import 'package:sdr_flutter/ui/waterfall_model.dart';

/// Demo radio whose FFT rows are pushed by the test.
class _RowRadio extends DemoRadioController {
  final _ctrl = StreamController<FftRow>.broadcast(sync: true);
  @override
  Stream<FftRow> get fftRows => _ctrl.stream;

  void push(Float32List db) {
    final low = tunedFrequency - sampleRate / 2;
    _ctrl.add(FftRow(db: db, lowFreq: low, highFreq: low + sampleRate));
  }

  @override
  void dispose() {
    _ctrl.close();
    super.dispose();
  }
}

Float32List _noise(math.Random rng, double floorDb, {double? carrier}) {
  final out = Float32List(256);
  for (var i = 0; i < out.length; i++) {
    final p = -math.log(1 - rng.nextDouble() * 0.999);
    out[i] = floorDb + 10 * math.log(p) / math.ln10;
  }
  if (carrier != null) out[60] = out[61] = carrier;
  return out;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SdrUiState auto levels', () {
    late _RowRadio radio;
    late SdrUiState ui;
    var now = Duration.zero;
    final rng = math.Random(11);

    void rows(int n, double floor, {double? carrier}) {
      for (var i = 0; i < n; i++) {
        now += const Duration(milliseconds: 50);
        radio.push(_noise(rng, floor, carrier: carrier));
      }
    }

    setUp(() {
      now = Duration.zero;
      radio = _RowRadio();
      ui = SdrUiState(
        radio,
        waterfall: WaterfallModel(autoSchedule: false),
        clock: () => now,
      );
    });
    tearDown(() {
      ui.dispose();
      radio.dispose();
    });

    test('off by default: rows do not touch the manual levels', () {
      rows(20, -90);
      expect(ui.fftMin, -120);
      expect(ui.fftMax, 0);
      expect(ui.autoNoiseFloor, isNull);
    });

    test('on: levels follow noise floor and peaks, waterfall too', () {
      ui.setAutoLevels(true);
      rows(40, -90);
      final floor = ui.autoNoiseFloor!;
      expect(ui.fftMin, closeTo(floor - AutoLevelTuning.marginBelowDb, 0.6));
      expect(ui.fftMax, closeTo(floor + AutoLevelTuning.minRangeDb, 0.6));
      expect(ui.waterfall.minDb, ui.fftMin);
      expect(ui.waterfall.maxDb, ui.fftMax);
      rows(20, -90, carrier: -25);
      expect(ui.fftMax, closeTo(-25 + AutoLevelTuning.marginAboveDb, 1.5));
      expect(ui.fftMax - ui.fftMin, greaterThanOrEqualTo(10));
    });

    test('retune restarts the window', () {
      ui.setAutoLevels(true);
      rows(20, -90, carrier: -25);
      expect(ui.autoPeak, -25);
      ui.tuneTo(145.5e6);
      expect(ui.autoPeak, isNull);
      rows(40, -95);
      expect(ui.autoPeak, lessThan(-75));
      expect(
        ui.fftMax,
        closeTo(ui.autoNoiseFloor! + AutoLevelTuning.minRangeDb, 0.6),
      );
    });

    test('gain change restarts the window', () {
      ui.setAutoLevels(true);
      rows(20, -90, carrier: -25);
      radio.setGain(radio.gain + 5);
      expect(ui.autoPeak, isNull);
    });

    test('switching Auto off keeps the current levels for manual use', () {
      ui.setAutoLevels(true);
      rows(40, -90);
      final min = ui.fftMin, max = ui.fftMax;
      ui.setAutoLevels(false);
      rows(20, -60, carrier: -10);
      expect(ui.fftMin, min);
      expect(ui.fftMax, max);
    });

    test('Auto is persisted and restored', () async {
      ui.setAutoLevels(true);
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SdrUiState.autoLevelsStorageKey), isTrue);
      final other = SdrUiState(
        radio,
        waterfall: WaterfallModel(autoSchedule: false),
      );
      expect(other.autoLevels, isFalse);
      await other.loadSettings();
      expect(other.autoLevels, isTrue);
      other.dispose();
    });
  });

  testWidgets('MainScreen: Auto removes Max/Min sliders', (tester) async {
    final radio = DemoRadioController();
    await tester.pumpWidget(MaterialApp(home: MainScreen(controller: radio)));
    await tester.pump();
    // Portrait: level controls are inside the "more" expansion tile.
    if (find.byKey(const ValueKey<String>('autoLevels')).evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey<String>('moreControls')));
      await tester.pumpAndSettle();
    }
    Slider slider(String key) => tester.widget<Slider>(
      find.descendant(
        of: find.byKey(ValueKey<String>(key)),
        matching: find.byType(Slider),
      ),
    );
    expect(slider('fftMaxSlider').onChanged, isNotNull);
    await tester.tap(find.byKey(const ValueKey<String>('autoLevels')));
    await tester.pump();
    expect(find.byKey(const ValueKey('fftMaxSlider')), findsNothing);
    expect(find.byKey(const ValueKey('fftMinSlider')), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('autoLevels')));
    await tester.pump();
    expect(slider('fftMaxSlider').onChanged, isNotNull);
    expect(slider('fftMinSlider').onChanged, isNotNull);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });

  testWidgets('legacy Settings: waterfall Auto hides Max/Min', (tester) async {
    final radio = DemoRadioController();
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump();
    final sw = find.byKey(const ValueKey('legacyAutoLevels'));
    final minSlider = find.byKey(const ValueKey('legacyFftMin'));
    await tester.scrollUntilVisible(
      minSlider,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump();
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('legacyFftMax')))
          .onChanged,
      isNotNull,
    );
    await tester.ensureVisible(sw);
    await tester.pump();
    await tester.tap(sw);
    await tester.pump();
    expect(tester.widget<Switch>(sw).value, isTrue);
    expect(find.byKey(const ValueKey('legacyFftMax')), findsNothing);
    expect(find.byKey(const ValueKey('legacyFftMin')), findsNothing);
    await tester.tap(sw);
    await tester.pump();
    // The removed promo rows shorten the lazy list: scroll the recreated
    // Min slider into view after turning Auto off.
    await tester.scrollUntilVisible(
      minSlider,
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump();
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('legacyFftMax')))
          .onChanged,
      isNotNull,
    );
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('legacyFftMin')))
          .onChanged,
      isNotNull,
    );
    tester.widget<Slider>(find.byKey(const ValueKey('legacyFftMin')))
        .onChanged!(-90);
    await tester.pump();
    expect(tester.widget<Slider>(find.byKey(const ValueKey('legacyFftMin'))).value, -90);
    expect(
      tester.widget<Slider>(find.byKey(const ValueKey('legacyFftMax'))).value,
      greaterThanOrEqualTo(-80),
    );
    await tester.tap(sw);
    await tester.pump();
    expect(find.byKey(const ValueKey('legacyFftMin')), findsNothing);
    await tester.tap(sw);
    await tester.pump();
    await tester.scrollUntilVisible(
      minSlider,
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump();
    expect(tester.widget<Slider>(find.byKey(const ValueKey('legacyFftMin'))).value, -90);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(SdrUiState.autoLevelsStorageKey), isFalse);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });
}

// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/decoder_screen.dart';
import 'package:sdr_flutter/ui/legacy/receive_screen.dart';
import 'package:sdr_flutter/ui/legacy/settings_screen.dart';
import 'package:sdr_flutter/ui/legacy/squelch_controls.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _DemodRadio extends DemoRadioController {
  final options = <String, Object?>{'stereo': false, 'lowPass': true};
  @override
  Map<String, Object?> get demodOptions =>
      mode == DemodMode.wfm ? options : const <String, Object?>{};
  @override
  void setDemodOption(String key, Object value) {
    options[key] = value;
    notifyListeners();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Decoder is the sole demod control surface and retains reception',
    (tester) async {
      final radio = _DemodRadio();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.pump();
      await radio.start();
      final hz = radio.tunedFrequency;
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pump();
      expect(find.text('Decoder'), findsNWidgets(2));
      expect(find.byType(SquelchControls), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ReceiveScreen),
          matching: find.byKey(const ValueKey('legacyModeSelect')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(SquelchControls),
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('demod:stereo')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('demod:stereo')));
      await tester.pump();
      expect(radio.options['stereo'], isTrue);
      await tester.drag(
        find.byKey(const ValueKey('decoderBandwidth')),
        const Offset(90, 0),
      );
      await tester.pump();
      expect(radio.bandwidth, isNot(DemodMode.wfm.params.defaultBandwidth));
      await tester.tap(find.byKey(const ValueKey('legacyModeSelect')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('legacyMode-NFM')));
      await tester.pump();
      expect(radio.mode, DemodMode.nfm);
      expect(radio.bandwidth, DemodMode.nfm.params.defaultBandwidth);
      await tester.ensureVisible(find.byKey(const ValueKey('squelchType')));
      await tester.pump();
      await tester.tap(find.text('Ручной'));
      await tester.pump();
      expect(radio.squelchType, SquelchType.manual);
      await tester.drag(
        find.byKey(const ValueKey('squelchLevelSlider')),
        const Offset(60, 0),
      );
      await tester.pump();
      expect(radio.squelchLevel, isNot(-50));
      await tester.tap(find.text('Авто'));
      await tester.pump();
      expect(radio.squelchType, SquelchType.auto);
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.pump();
      expect(find.byType(DecoderScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('squelchType')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tab-0')));
      await tester.pump();
      expect(find.byKey(const ValueKey('legacyMute')), findsOneWidget);
      expect(radio.tunedFrequency, hz);
      expect(radio.running, isTrue);
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pump();
      expect(find.text('Настройки приёмника'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pump();
      expect(radio.mode, DemodMode.nfm);
      expect(radio.squelchType, SquelchType.auto);
      expect(radio.running, isTrue);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );

  testWidgets('Decoder results are honest empty states without controls', (
    tester,
  ) async {
    final radio = DemoRadioController();
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.tap(find.byKey(const ValueKey('tab-3')));
    await tester.pump();
    for (final id in ['rtl433', 'sstvFax', 'adsb', 'textPacket']) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('decoder-$id')),
        150,
        scrollable: find.descendant(
          of: find.byType(DecoderScreen),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.byKey(ValueKey('decoder-$id')), findsOneWidget);
    }
    expect(find.textContaining('RDS'), findsWidgets);
    expect(find.textContaining('недоступ'), findsWidgets);
    expect(find.textContaining('один приёмник'), findsWidgets);
    expect(find.text('Start'), findsNothing);
    expect(find.byKey(const ValueKey('demod:stereo')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });

  testWidgets('RAW channel bandwidth is locked and squelch unavailable', (
    tester,
  ) async {
    final radio = DemoRadioController()..setMode(DemodMode.raw);
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.tap(find.byKey(const ValueKey('tab-3')));
    await tester.pump();
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('decoderBandwidth')))
          .onChanged,
      isNull,
    );
    expect(radio.bandwidth, DemodMode.raw.params.defaultBandwidth);
    final squelch = tester.widget<SegmentedButton<SquelchType>>(
      find.byKey(const ValueKey('squelchType')),
    );
    expect(
      squelch.segments.firstWhere((s) => s.value == SquelchType.manual).enabled,
      isFalse,
    );
    expect(
      squelch.segments.firstWhere((s) => s.value == SquelchType.auto).enabled,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });

  for (final size in [const Size(344, 690), const Size(690, 344)]) {
    testWidgets('Decoder scrolls without overflow at $size', (tester) async {
      tester.view.physicalSize = size * 2.625;
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final radio = _DemodRadio();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pump();
      expect(find.byType(DecoderScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(DecoderScreen), const Offset(0, -900));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    });
  }
}

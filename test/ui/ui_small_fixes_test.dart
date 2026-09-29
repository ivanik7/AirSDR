import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/legacy/theme.dart';

import 'package:sdr_flutter/ui/sdr_ui_state.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('keypad resets 10 seconds after last key and notifies the view', (
    tester,
  ) async {
    final radio = DemoRadioController();
    final r = CenteredReceiver(radio);
    var repaints = 0;
    r.onEntryExpired = () => repaints++;
    r.pressKey('1');
    r.pressKey('4');
    final before = radio.tunedFrequency;
    await tester.pump(const Duration(milliseconds: 9900));
    expect(r.entry, '14');
    r.pressKey('5');
    await tester.pump(const Duration(milliseconds: 9900));
    expect(r.entry, '145');
    await tester.pump(const Duration(milliseconds: 101));
    expect(r.entry, isEmpty);
    expect(repaints, 1);
    expect(radio.tunedFrequency, before);
    r.pressKey('1');
    r.pressKey('CLR');
    await tester.pump(const Duration(seconds: 11));
    expect(repaints, 1);
    r.dispose();
    radio.dispose();
  });

  testWidgets(
    'keypad autocompletes at step precision, rounds early OK, rejects range',
    (tester) async {
      final radio = DemoRadioController();
      final r = CenteredReceiver(radio);
      r.setStepHz(100000);
      for (final k in ['1', '4', '5', '.', '5']) {
        expect(r.pressKey(k), isTrue);
      }
      expect(r.entry, isEmpty);
      expect(radio.tunedFrequency, 145500000);
      r.setStepHz(12500);
      for (final k in ['1', '4', '5', '.', '5', '1', '2', '5']) {
        r.pressKey(k);
      }
      expect(radio.tunedFrequency, 145512500);
      r.setStepHz(25000);
      for (final k in ['1', '4', '5', '.', '5', '1', '2']) {
        r.pressKey(k);
      }
      expect(radio.tunedFrequency, 145500000);
      r.setStepHz(1000000);
      for (final k in ['1', '4', '5', '.']) {
        r.pressKey(k);
      }
      expect(radio.tunedFrequency, 145000000);
      r.setStepHz(25000);
      for (final k in ['1', '4', '5', '.', '5', '1', '3']) {
        r.pressKey(k);
      }
      expect(radio.tunedFrequency, 145525000);
      for (final k in ['1', '4', '5', '.', '5', '1', 'OK']) {
        r.pressKey(k);
      }
      expect(radio.tunedFrequency, 145500000);
      r.pressKey('0');
      expect(r.pressKey('OK'), isFalse);
      expect(radio.tunedFrequency, 145500000);
      r.dispose();
      radio.dispose();
    },
  );

  testWidgets('waterfall speed persists independently of height', (
    tester,
  ) async {
    final radio = DemoRadioController();
    final ui = SdrUiState(radio);
    ui.setWaterfallRowHeight(4);
    await tester.pump();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(SdrUiState.waterfallSpeedStorageKey), 4);
    ui.setLayout(columns: 100, historyRows: 512);
    final rows = ui.waterfall.height;
    ui.setLayout(columns: 100, historyRows: 512);
    expect(ui.waterfall.height, rows);
    final reopened = SdrUiState(radio);
    await reopened.loadSettings();
    expect(reopened.waterfallRowHeight, 4);
    expect(reopened.waterfall.height, 256);
    reopened.dispose();
    ui.dispose();
    radio.dispose();
  });

  for (final size in [const Size(344, 690), const Size(690, 829)]) {
    testWidgets('two-row channels and keyboard fit $size', (tester) async {
      tester.view.devicePixelRatio = 2.625;
      tester.view.physicalSize = size * 2.625;
      addTearDown(tester.view.reset);
      final radio = DemoRadioController();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const ValueKey('channelAdd')));
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('channelsRow')), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('key-5'))).height,
        greaterThanOrEqualTo(size.height < 750 ? 38 : 44),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    });
  }

  testWidgets(
    'step popup, preset check, mute and stopped SDR use correct colors',
    (tester) async {
      final radio = DemoRadioController();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.pump();
      final mutedIcon = find.descendant(
        of: find.byKey(const ValueKey('legacyMute')),
        matching: find.byIcon(Icons.volume_off),
      );
      expect(tester.widget<Icon>(mutedIcon).color, LegacyColors.danger);
      final status = find.byKey(const ValueKey('legacyStats'));
      expect(tester.widget<Text>(status).style!.color, LegacyColors.danger);
      await tester.tap(find.byKey(const ValueKey('legacyMute')));
      await tester.pump();
      final unmutedIcon = find.descendant(
        of: find.byKey(const ValueKey('legacyMute')),
        matching: find.byIcon(Icons.volume_up),
      );
      expect(
        tester.widget<Icon>(unmutedIcon).color,
        isNot(LegacyColors.danger),
      );
      await tester.tap(find.byKey(const ValueKey('legacyStep')));
      await tester.pumpAndSettle();
      for (final hz in CenteredReceiver.steps) {
        expect(find.byKey(ValueKey('legacyStep-$hz')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(2, 200));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      expect(find.text('Применить'), findsNothing);
      expect(find.byIcon(Icons.check), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );
}

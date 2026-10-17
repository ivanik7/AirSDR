// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';

void main() {
  testWidgets('Meshtastic preview labels unavailable and quick tunes one VFO',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(344, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final radio = DemoRadioController();
    await tester.pumpWidget(MaterialApp(home: LegacyAppShell(controller: radio)));
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('decoderSelector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('decoderSelect-meshtastic')));
    await tester.pump();
    expect(find.byKey(const ValueKey('decoderPanel-meshtastic')),
        findsOneWidget);
    expect(find.textContaining('Decoder unavailable'), findsOneWidget);
    expect(find.textContaining('Unverified frequency'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('meshtasticTune-EU_868')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('meshtasticTune-EU_868')));
    await tester.pump();
    expect(radio.tunedFrequency, 869525000);
    expect(radio.centerFrequency, radio.tunedFrequency);
    expect(radio.vfoOffset, 0);
    expect(radio.running, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });
}

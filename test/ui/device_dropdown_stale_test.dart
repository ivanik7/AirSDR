// SPDX-License-Identifier: GPL-3.0-or-later
// A native USB detach may arrive before the selected device is cleared.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/main_screen.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _StaleSelectionRadio extends DemoRadioController {
  SdrDeviceInfo? stale;
  List<SdrDeviceInfo>? list;

  @override
  SdrDeviceInfo? get selectedDevice => stale ?? super.selectedDevice;
  @override
  List<SdrDeviceInfo> get devices => list ?? super.devices;

  void unplug() {
    stale = super.selectedDevice;
    list = super.devices.where((d) => d != stale).toList();
    notifyListeners();
  }

  void duplicate() {
    stale = super.selectedDevice;
    list = [stale!, stale!];
    notifyListeners();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Legacy device dropdown tolerates detach and duplicate notifications',
    (tester) async {
      tester.view.devicePixelRatio = 2.625;
      tester.view.physicalSize = const Size(344, 882) * 2.625;
      addTearDown(tester.view.reset);
      final radio = _StaleSelectionRadio();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.pump();
      final dd = find.byKey(
        const ValueKey('legacyDevice'),
        skipOffstage: false,
      );
      expect(tester.widget<DropdownButton<SdrDeviceInfo>>(dd).value, isNotNull);
      radio.unplug();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.widget<DropdownButton<SdrDeviceInfo>>(dd).value, isNull);
      radio.duplicate();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );

  testWidgets('Secondary UI device dropdown tolerates native USB detach', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    final radio = _StaleSelectionRadio();
    await tester.pumpWidget(MaterialApp(home: MainScreen(controller: radio)));
    await tester.pump();
    radio.unplug();
    await tester.pump();
    expect(tester.takeException(), isNull);
    final dd = find.byKey(const ValueKey<String>('deviceDropdown'));
    expect(tester.widget<DropdownButton<SdrDeviceInfo>>(dd).value, isNull);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });
}

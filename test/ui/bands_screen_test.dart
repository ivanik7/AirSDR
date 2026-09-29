// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/bands/bands.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'bands in Settings: create, validate, edit, delete, persist at 344 dp',
    (tester) async {
      tester.view.physicalSize = const Size(903, 2315);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final radio = DemoRadioController();
      final bands = BandsRepository();
      await bands.load();
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, bands: bands),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settingsBands')),
        200,
      );
      await tester.tap(find.byKey(const ValueKey('settingsBands')));
      await tester.pumpAndSettle();
      expect(find.text('Диапазоны'), findsWidgets);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('bandAdd')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bandSave')));
      await tester.pumpAndSettle();
      expect(find.textContaining('введите начало'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('bandName')),
        'Своя полоса',
      );
      await tester.enterText(find.byKey(const ValueKey('bandStart')), '100');
      await tester.enterText(find.byKey(const ValueKey('bandEnd')), '101');
      await tester.tap(find.byKey(const ValueKey('bandSave')));
      await tester.pumpAndSettle();
      expect(find.textContaining('пересечение с «FM»'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('bandStart')), '300');
      await tester.enterText(find.byKey(const ValueKey('bandEnd')), '301');
      await tester.tap(find.byKey(const ValueKey('bandSave')));
      await tester.pumpAndSettle();
      final created = bands.entries.singleWhere((b) => b.name == 'Своя полоса');
      expect(created.startHz, 300000000);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byKey(ValueKey('band-${created.id}')));
      await tester.tap(find.byKey(ValueKey('band-${created.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('bandEnd')), '302');
      await tester.tap(find.byKey(const ValueKey('bandSave')));
      await tester.pumpAndSettle();
      expect(bands.byId(created.id)!.endHz, 302000000);
      await tester.ensureVisible(
        find.byKey(ValueKey('bandDelete-${created.id}')),
      );
      await tester.tap(find.byKey(ValueKey('bandDelete-${created.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Удалить диапазон?'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(bands.byId(created.id), isNotNull);
      await tester.tap(find.byKey(ValueKey('bandDelete-${created.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bandDeleteConfirm')));
      await tester.pumpAndSettle();
      expect(bands.byId(created.id), isNull);
      expect(tester.takeException(), isNull);
      await bands.flush();
      final restored = BandsRepository();
      await restored.load();
      expect(restored.byId(created.id), isNull);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      bands.dispose();
      restored.dispose();
    },
  );

  testWidgets(
    'receive status and preset sections react to band edits/deletion',
    (tester) async {
      final radio = DemoRadioController();
      final bands = BandsRepository();
      await bands.load();
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, bands: bands),
        ),
      );
      await tester.pump();
      // Tune from outside a band with the on-screen keypad.

      for (final key in ['1', '0', '1', '.', '0']) {
        await tester.tap(find.byKey(ValueKey('key-$key')));
      }
      await tester.tap(find.byKey(const ValueKey('key-OK')));
      await tester.pump();
      expect(find.byKey(const ValueKey('legacyBandName')), findsOneWidget);
      expect(find.text('FM'), findsOneWidget);
      expect(radio.mode.label, 'WFM');
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('presetSection-band-fm')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('presetSection-band-air')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('category-FM')), findsNothing);
      bands.delete('band-fm');
      await tester.pump();
      expect(find.byKey(const ValueKey('presetSection-band-fm')), findsNothing);
      expect(find.byKey(const ValueKey('presetSection-none')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tab-0')));
      await tester.pump();
      expect(find.byKey(const ValueKey('legacyBandName')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      bands.dispose();
    },
  );
}

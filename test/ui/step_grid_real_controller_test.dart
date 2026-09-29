// SPDX-License-Identifier: GPL-3.0-or-later
// Step grid with the real controller and DSP isolate (task t_33f07c06): a frequency persisted
// off the grid (older build) is snapped to the stored step on start, and the UI text, the
// controller and the DSP tuner (sourceManager.tune → state 'centerFreq') agree. ◀ ▶ and a
// step change keep all three on the grid.
@Timeout(
  Duration(minutes: 3),
) // real DSP isolate: slow to spawn under full-suite load
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/runtime/sdr_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/usb/android_usb.dart';
import 'package:sdr_flutter/usb/usb_device_provider.dart';

import '../runtime/fake_usb_plugin.dart';
import '../runtime/fake_usb_source.dart';

void main() {
  testWidgets(
    'persisted off-grid frequency: UI = controller = DSP tuner on the grid',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 2400);
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        CenteredReceiver.stepStorageKey: 100000,
      });
      const methods = MethodChannel('test/stepgrid');
      const events = EventChannel('test/stepgrid/events');
      final plugin = FakeUsbPlugin(methods, events)..install();
      plugin.devices.add(fakeRtl);
      final tmp = Directory.systemTemp.createTempSync('step_grid_real');
      final favorites = FavoritesRepository();
      await favorites.load();
      late SdrRadioController c;

      Future<void> until(bool Function() cond, String what) async {
        final sw = Stopwatch()..start();
        while (!cond() && sw.elapsed < const Duration(seconds: 60)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(
          cond(),
          isTrue,
          reason:
              'timeout: $what (center=${c.centerFrequency} offset=${c.vfoOffset} '
              'dsp=${c.lastState['centerFreq']} running=${c.running})',
        );
      }

      String shown() => tester
          .widget<Text>(find.byKey(const ValueKey('legacyFrequency')))
          .data!;

      bool allAt(double hz) =>
          c.centerFrequency == hz &&
          c.vfoOffset == 0 &&
          c.lastState['centerFreq'] == hz &&
          c.lastState['vfoOffset'] == 0;

      await tester.runAsync(() async {
        // An older build saved 118.180 MHz (off the 100 kHz grid).
        final old = DspEngine(
          (_) {},
          options: DspEngineOptions(configDir: tmp.path, audio: 'null'),
        );
        old.tune(center: 118180000, offset: 0);
        await old.shutdown();
        c = SdrRadioController(
          providers: <DeviceProvider>[
            UsbDeviceProvider(
              usb: AndroidUsb(methods: methods, events: events),
              enabled: true,
              abiSupported: true,
            ),
            SynthDeviceProvider(),
          ],
          options: DspEngineOptions(configDir: tmp.path, audio: 'null'),
          registerSources: registerFakeUsbSources,
          spawnTimeout: const Duration(seconds: 90),
        );
        await c.ready;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: c, favorites: favorites),
        ),
      );
      await until(() => c.running && allAt(118200000), 'snapped restore');
      expect(find.text('ШАГ 100 кГц'), findsOneWidget);
      expect(shown(), '118.200');

      // ◀/▶ left with the tuning ruler: type the neighbouring grid value.
      for (final k in ['1', '1', '8', '.', '1', 'OK']) {
        await tester.tap(find.byKey(ValueKey('key-$k')));
        await tester.pump();
      }
      await until(() => allAt(118100000), 'keypad 118.1');
      expect(shown(), '118.100');

      // Choose 5 kHz explicitly; the third fractional digit completes input.
      await tester.tap(find.byKey(const ValueKey('legacyStep')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('legacyStep-5000')));
      await tester.pumpAndSettle();
      expect(find.text('ШАГ 5 кГц'), findsOneWidget);
      for (final k in ['1', '1', '8', '.', '1', '8', '3']) {
        await tester.tap(find.byKey(ValueKey('key-$k')));
        await tester.pump();
      }
      await until(() => allAt(118185000), 'keypad on 5 kHz grid');
      expect(shown(), '118.185');

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        c.dispose();
        favorites.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        plugin.uninstall();
        tmp.deleteSync(recursive: true);
      });
    },
  );
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Phone QA regression (task t_3cfa7a1d): unplugging the RTL-SDR turned the Receive screen into
// a red "There should be exactly one item with [DropdownButton]'s value" error — the device
// dropdown got the vanished dongle as value while the device list no longer contained it.
@Timeout(Duration(minutes: 3)) // real DSP isolate: slow to spawn under full-suite load
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/runtime/sdr_radio_controller.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/main_screen.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';
import 'package:sdr_flutter/usb/android_usb.dart';
import 'package:sdr_flutter/usb/usb_device_provider.dart';

import '../runtime/fake_usb_plugin.dart';
import '../runtime/fake_usb_source.dart';

/// Reproduces the notification seen on the phone: the list already lost the dongle, the
/// selection still points at it.
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
    list = <SdrDeviceInfo>[stale!, stale!];
    notifyListeners();
  }
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = const Size(344, 882) * 2.625;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'legacy Receive: selection missing from the device list is not an error',
    (tester) async {
      _phone(tester);
      final radio = _StaleSelectionRadio();
      final favorites = FavoritesRepository();
      await favorites.load();
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );
      await tester.pump();
      final dd = find.byKey(const ValueKey('legacyDevice'));
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
      favorites.dispose();
    },
  );

  testWidgets(
    'SDR++ main screen: selection missing from the device list is not an error',
    (tester) async {
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
    },
  );

  testWidgets(
    'legacy Receive with the real controller: unplug -> re-plug, no FlutterError, auto reconnect',
    (tester) async {
      _phone(tester);
      const methods = MethodChannel('test/hotreplug');
      const events = EventChannel('test/hotreplug/events');
      final plugin = FakeUsbPlugin(methods, events)..install();
      plugin.devices.add(fakeRtl);
      final tmp = Directory.systemTemp.createTempSync('hotreplug_ui');
      late SdrRadioController c;
      final favorites = FavoritesRepository();
      await favorites.load();
      final clock = Stopwatch()..start();
      final trace = <String>[];

      Future<void> until(bool Function() cond, String what) async {
        final sw = Stopwatch()..start();
        while (!cond() && sw.elapsed < const Duration(seconds: 60)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: 'while waiting for $what',
          );
        }
        expect(
          cond(),
          isTrue,
          reason:
              'timeout: $what (link=${c.linkState} running=${c.running} '
              'device=${c.selectedDevice?.id} devices=${c.devices.map((d) => d.id).toList()} '
              'error=${c.lastError} opens=${plugin.opens} closes=${plugin.closes})\n'
              '${trace.join('\n')}',
        );
      }

      await tester.runAsync(() async {
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
        // Spawning the DSP isolate takes seconds when the whole suite runs in parallel: wait
        // for it in real time (not in the fake-async polling loop below).
        await c.ready;
      });
      expect(c.lastError ?? '', isNot(startsWith('DSP start failed')));
      // Frames are built only at pump(); the stale window on the phone was between two
      // awaits of the controller. Check the same invariant at every notification too.
      final violations = <String>[];
      String? lastLine;
      c.addListener(() {
        final d = c.selectedDevice;
        if (d != null && !c.devices.contains(d)) violations.add(d.id);
        final line =
            '${c.linkState.name} run=${c.running} dev=${d?.id} err=${c.lastError} '
            'opens=${plugin.opens.length} closes=${plugin.closes.length}';
        if (line != lastLine) trace.add('${clock.elapsedMilliseconds} $line');
        lastLine = line;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: c, favorites: favorites),
        ),
      );
      final dd = find.byKey(const ValueKey('legacyDevice'));
      await until(() => c.running, 'auto start');
      expect(
        tester.widget<DropdownButton<SdrDeviceInfo>>(dd).value?.id,
        'usb:${fakeRtl['deviceName']}',
      );

      // Cable pulled: ENODEV from the stream, then Android's detach broadcast.
      trace.add('${clock.elapsedMilliseconds} >> simulateLoss + detach 002');
      c.setSourceSetting('simulateLoss', true);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      plugin.detach(fakeRtl);
      await until(
        () =>
            c.linkState == DeviceLinkState.disconnected &&
            c.selectedDevice == null,
        'disconnected',
      );
      expect(find.text('устройство отключено, ожидание'), findsOneWidget);
      expect(tester.widget<DropdownButton<SdrDeviceInfo>>(dd).value, isNull);

      // Re-plugged on a new bus address: resumes by itself.
      trace.add('${clock.elapsedMilliseconds} >> attach 009');
      plugin.attach(fakeRtlReplugged);
      await until(() => c.running, 're-plug');
      expect(
        tester.widget<DropdownButton<SdrDeviceInfo>>(dd).value?.id,
        'usb:${fakeRtlReplugged['deviceName']}',
      );
      expect(c.muted, isTrue);
      expect(tester.takeException(), isNull);

      // Detach broadcast before any ENODEV (the other order seen on the phone).
      trace.add('${clock.elapsedMilliseconds} >> detach 009');
      plugin.detach(fakeRtlReplugged);
      await until(
        () =>
            c.linkState == DeviceLinkState.disconnected &&
            c.selectedDevice == null,
        'disconnected 2',
      );
      trace.add('${clock.elapsedMilliseconds} >> attach 002');
      plugin.attach(fakeRtl);
      await until(() => c.running, 're-plug 2');
      expect(violations, isEmpty);

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

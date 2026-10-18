// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';
import 'package:sdr_flutter/native/native_radio_controller.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/legacy/settings_screen.dart';

import '../native/native_radio_controller_rtltcp_test.dart' as fixture;

class _Radio extends DemoRadioController {
  Map<String, Object?> values = {'droppedBuffers': 3, 'audioDropped': 0};
  DeviceLinkState link = DeviceLinkState.idle;
  String? error;
  int retries = 0;

  @override
  Map<String, Object?> get stats => values;
  @override
  DeviceLinkState get linkState => link;
  @override
  String? get lastError => error;
  @override
  Future<void> retryDevice() async => retries++;
  @override
  void clearError() {
    error = null;
    notifyListeners();
  }

  void updateStats(Map<String, Object?> next) {
    values = next;
    notifyListeners();
  }

  void fail() {
    link = DeviceLinkState.failed;
    error = 'No device';
    notifyListeners();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'network form validates, selects offline endpoint, and survives USB hotplug at 344 dp',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(344, 690);
      addTearDown(tester.view.reset);
      final api = fixture.FakeApi();
      final source = fixture.FakeSource();
      final radio = NativeRadioController(
        api: api,
        source: source,
        autoStart: false,
        pollInterval: const Duration(milliseconds: 20),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: const ValueKey('settingsScreenshot'),
            child: Scaffold(
              body: SettingsScreen(
                controller: radio,
                receiver: CenteredReceiver(radio),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final selector = find.byKey(const ValueKey('networkSource'));
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Network (rtl_tcp)').last);
      await tester.pumpAndSettle();
      expect(radio.networkSelected, isTrue);
      expect(find.byKey(const ValueKey('networkHostField')), findsOneWidget);
      expect(find.byKey(const ValueKey('networkPortField')), findsOneWidget);
      final screenshot = Platform.environment['SDR_UI_SCREENSHOT'];
      if (screenshot != null) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('settingsScreenshot')),
          );
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(screenshot).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.enterText(
        find.byKey(const ValueKey('networkHostField')),
        '   ',
      );
      await tester.enterText(
        find.byKey(const ValueKey('networkPortField')),
        '65536',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('legacyStartStop')));
      await tester.tap(find.byKey(const ValueKey('legacyStartStop')));
      await tester.pump();
      expect(find.text('Enter a host or IP address'), findsOneWidget);
      expect(find.text('Enter a port from 1 to 65535'), findsOneWidget);
      expect(api.calls, isNot(contains('start')));
      await tester.enterText(
        find.byKey(const ValueKey('networkHostField')),
        'localhost',
      );
      await tester.enterText(
        find.byKey(const ValueKey('networkPortField')),
        '4567',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('networkApply')));
      await tester.tap(find.byKey(const ValueKey('networkApply')));
      await tester.pump();
      expect(radio.networkSource?.host, 'localhost');
      expect(radio.networkSource?.port, 4567);
      source.devices = [fixture.usbDevice];
      await radio.refreshDevices();
      await tester.pump();
      expect(radio.networkSelected, isTrue);
      expect(find.byKey(const ValueKey('legacyDevice')), findsNothing);
      expect(tester.takeException(), isNull);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.scrollUntilVisible(
        selector,
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local USB SDR').last);
      await tester.pumpAndSettle();
      expect(radio.networkSelected, isFalse);
      expect(find.byKey(const ValueKey('legacyDevice')), findsOneWidget);
      expect(find.byKey(const ValueKey('networkHostField')), findsNothing);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Network (rtl_tcp)').last);
      await tester.pumpAndSettle();
      expect(radio.savedNetworkHost, 'localhost');
      expect(radio.savedNetworkPort, 4567);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('legacyStartStop')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('legacyStartStop')));
      await tester.pump(const Duration(milliseconds: 80));
      expect(radio.linkState, DeviceLinkState.connecting);
      api.rtlTcpLinkValue = 1;
      await tester.pump(const Duration(milliseconds: 80));
      expect(radio.linkState, DeviceLinkState.receiving);
      expect(find.text('Connected to rtl_tcp'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('legacyStartStop')));
      await tester.pump();
      expect(radio.linkState, DeviceLinkState.stoppedByUser);
      await radio.refreshDevices();
      expect(radio.running, isFalse);
      await tester.tap(find.byKey(const ValueKey('legacyStartStop')));
      await tester.pump(const Duration(milliseconds: 80));
      api.state = SdrState.error;
      api.error = SdrResult.tcpRefused;
      api.errorSequence++;
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump();
      expect(radio.linkState, DeviceLinkState.failed);
      expect(radio.lastError, contains('refused'));
      expect(find.byKey(const ValueKey('networkRetry')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('networkRetry')));
      await tester.tap(find.byKey(const ValueKey('networkRetry')));
      await tester.pump();
      expect(radio.running, isTrue);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      await source.changesController.close();
    },
  );

  testWidgets(
    'Settings connection contains start/stop and live status sheet at 344 dp',
    (tester) async {
      tester.view.devicePixelRatio = 2.625;
      tester.view.physicalSize = const Size(903, 1811.25); // 344 × 690 dp
      addTearDown(tester.view.reset);
      final radio = _Radio();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pump();
      expect(find.text('SDR CONNECTION'), findsOneWidget);
      expect(find.text('USB options'), findsNothing);
      expect(find.text('Device settings'), findsOneWidget);
      expect(find.text('Volume'), findsNothing);
      expect(find.text('STATE'), findsNothing);
      expect(find.text('droppedBuffers'), findsNothing);
      final start = find.byKey(const ValueKey('legacyStartStop'));
      expect(start, findsOneWidget);
      await tester.tap(start);
      await tester.pump();
      expect(radio.running, isTrue);
      expect(find.text('Stop'), findsOneWidget);
      await tester.tap(start);
      await tester.pump();
      expect(radio.running, isFalse);

      await tester.scrollUntilVisible(
        find.text('RECEIVER OPTIONS'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.getTopLeft(start).dy,
        lessThan(tester.getTopLeft(find.text('RECEIVER OPTIONS')).dy),
      );
      expect(tester.takeException(), isNull);

      final show = find.byKey(const ValueKey('legacyShowStatus'));
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.text('droppedBuffers'), findsOneWidget);
      expect(find.text('audioDropped'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      radio.updateStats({'droppedBuffers': 9, 'audioDropped': 1});
      await tester.pump();
      expect(find.text('9'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('legacyCloseStatus')));
      await tester.pumpAndSettle();
      expect(find.text('droppedBuffers'), findsNothing);
      radio.fail();
      await tester.pump();
      expect(find.byKey(const ValueKey('legacyRetryUsb')), findsOneWidget);
      expect(find.text('Error'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('legacyRetryUsb')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('legacyRetryUsb')));
      await tester.pump();
      expect(radio.retries, 1);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );
}

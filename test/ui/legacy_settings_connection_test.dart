// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

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
    error = 'Нет устройства';
    notifyListeners();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
      expect(find.text('ПОДКЛЮЧЕНИЕ К SDR'), findsOneWidget);
      expect(find.text('USB параметры'), findsNothing);
      expect(find.text('Параметры устройства'), findsOneWidget);
      expect(find.text('Громкость'), findsNothing);
      expect(find.text('СОСТОЯНИЕ'), findsNothing);
      expect(find.text('droppedBuffers'), findsNothing);
      final start = find.byKey(const ValueKey('legacyStartStop'));
      expect(start, findsOneWidget);
      await tester.tap(start);
      await tester.pump();
      expect(radio.running, isTrue);
      expect(find.text('Стоп'), findsOneWidget);
      await tester.tap(start);
      await tester.pump();
      expect(radio.running, isFalse);

      await tester.scrollUntilVisible(
        find.text('ПАРАМЕТРЫ ПРИЁМНИКА'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.getTopLeft(start).dy,
        lessThan(tester.getTopLeft(find.text('ПАРАМЕТРЫ ПРИЁМНИКА')).dy),
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
      expect(find.text('Ошибка'), findsOneWidget);
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

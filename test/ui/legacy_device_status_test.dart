// SPDX-License-Identifier: GPL-3.0-or-later
// Receive screen: explicit mute/unmute button (separate from the volume slider), device link
// status line and the retry button after a refused USB permission (task t_3cfa7a1d).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/receive_screen.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _LinkRadio extends DemoRadioController {
  DeviceLinkState link = DeviceLinkState.waiting;
  int retries = 0;
  @override
  DeviceLinkState get linkState => running ? DeviceLinkState.receiving : link;
  @override
  Future<void> retryDevice() async => retries++;
  void set(DeviceLinkState s) {
    link = s;
    notifyListeners();
  }
}

Future<(_LinkRadio, FavoritesRepository)> _pump(
  WidgetTester tester, {
  Size size = const Size(344, 882),
}) async {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = size * 2.625;
  addTearDown(tester.view.reset);
  final radio = _LinkRadio();
  final favorites = FavoritesRepository();
  await favorites.load();
  await tester.pumpWidget(
    MaterialApp(
      home: LegacyAppShell(controller: radio, favorites: favorites),
    ),
  );
  await tester.pump();
  return (radio, favorites);
}

Future<void> _done(
  WidgetTester tester,
  _LinkRadio r,
  FavoritesRepository f,
) async {
  await tester.pumpWidget(const SizedBox());
  r.dispose();
  f.dispose();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'mute button toggles mute only; volume slider value is untouched',
    (tester) async {
      final (radio, favorites) = await _pump(tester);
      radio.setVolume(0.7);
      await tester.pump();
      final mute = find.byKey(const ValueKey('legacyMute'));
      expect(mute, findsOneWidget);
      expect(radio.muted, isTrue, reason: 'session starts muted');
      expect(
        find.descendant(of: mute, matching: find.byIcon(Icons.volume_off)),
        findsOneWidget,
      );
      expect(tester.widget<IconButton>(mute).tooltip, 'Включить звук');

      await tester.tap(mute);
      await tester.pump();
      expect(radio.muted, isFalse);
      expect(radio.volume, 0.7);
      expect(
        find.descendant(of: mute, matching: find.byIcon(Icons.volume_up)),
        findsOneWidget,
      );
      expect(tester.widget<IconButton>(mute).tooltip, 'Выключить звук');

      await tester.tap(mute);
      await tester.pump();
      expect(radio.muted, isTrue);
      expect(radio.volume, 0.7);
      await _done(tester, radio, favorites);
    },
  );

  testWidgets(
    'status line reflects the device link; retry only after refused permission',
    (tester) async {
      final (radio, favorites) = await _pump(tester);
      final status = find.byKey(const ValueKey('legacyStats'));
      final retry = find.byKey(const ValueKey('legacyRetryUsb'));

      expect(tester.widget<Text>(status).data, 'ожидание USB SDR');
      expect(retry, findsNothing);

      radio.set(DeviceLinkState.connecting);
      await tester.pump();
      expect(tester.widget<Text>(status).data, 'подключение…');

      radio.set(DeviceLinkState.disconnected);
      await tester.pump();
      expect(
        tester.widget<Text>(status).data,
        'устройство отключено, ожидание',
      );
      expect(tester.getRect(status).right, lessThanOrEqualTo(344));

      radio.set(DeviceLinkState.stoppedByUser);
      await tester.pump();
      expect(tester.widget<Text>(status).data, 'приём остановлен');

      radio.set(DeviceLinkState.permissionDenied);
      await tester.pump();
      expect(tester.widget<Text>(status).data, 'нет разрешения USB');
      expect(retry, findsNothing, reason: 'USB controls belong in Settings');
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pump();
      await tester.scrollUntilVisible(retry, 170,
          scrollable: find.byType(Scrollable).first);
      expect(retry, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(retry);
      await tester.pump();
      expect(radio.retries, 1);

      radio.set(DeviceLinkState.failed);
      await tester.pump();
      expect(
        retry,
        findsOneWidget,
        reason: 'a failed open can be retried as well',
      );

      await radio.start();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tab-0')));
      await tester.pump();
      expect(tester.widget<Text>(status).data, compactStatsLine(radio));
      expect(retry, findsNothing);
      await radio.stop();
      await _done(tester, radio, favorites);
    },
  );

  test('status texts cover every link state', () {
    for (final s in DeviceLinkState.values) {
      expect(linkStatusText(s), isNotEmpty);
    }
  });
}

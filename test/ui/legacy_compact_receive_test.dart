import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/channels/channels.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/receive_screen.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(
    WidgetTester tester,
    DemoRadioController radio,
    ChannelsRepository channels,
    Size size,
    double scale,
  ) async {
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = size * 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: LegacyAppShell(controller: radio, channels: channels),
      ),
    );
    await tester.pump();
  }

  for (final size in [
    const Size(344, 882),
    const Size(300, 640),
    const Size(690, 829),
  ]) {
    for (final count in [0, 12]) {
      testWidgets('receive fits $size with $count channels, scale 1.25', (
        tester,
      ) async {
        final radio = DemoRadioController();
        final channels = ChannelsRepository();
        await channels.load();
        for (var i = 0; i < count; i++) {
          channels.add(
            frequencyHz: 101000000 + i * 12500,
            mode: DemodMode.nfm,
            name: 'Канал $i',
          );
        }
        await pump(tester, radio, channels, size, 1.25);
        expect(tester.takeException(), isNull);
        final receive = find.byType(ReceiveScreen);
        expect(
          find.descendant(of: receive, matching: find.byType(ListView)),
          findsNothing,
        );
        final freq = tester.getRect(
          find.byKey(const ValueKey('legacyFrequency')),
        );
        final spectrum = tester.getRect(
          find.byKey(const ValueKey('legacySpectrumDrag')),
        );
        expect(freq.top, lessThan(spectrum.top));
        expect(find.byKey(const ValueKey('tuningRuler')), findsNothing);
        expect(find.byKey(const ValueKey('key-OK')), findsOneWidget);
        expect(
          tester.getRect(find.byKey(const ValueKey('key-OK'))).bottom,
          lessThanOrEqualTo(size.height - 64),
        );
        await tester.pumpWidget(const SizedBox());
        radio.dispose();
        channels.dispose();
      });
    }
  }

  testWidgets('mode, step and digit entry share compact controls', (
    tester,
  ) async {
    final radio = DemoRadioController();
    final channels = ChannelsRepository();
    await channels.load();
    await pump(tester, radio, channels, const Size(344, 882), 1);
    expect(find.byKey(const ValueKey('legacyDevice')), findsNothing);
    expect(find.byKey(const ValueKey('legacyPlayStop')), findsNothing);
    expect(find.byKey(const ValueKey('legacyMute')), findsOneWidget);
    expect(find.byTooltip('Очистить ввод'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('key-1')));
    await tester.pump();
    expect(find.byTooltip('Очистить ввод'), findsOneWidget);
    expect(find.byKey(const ValueKey('legacyMute')), findsNothing);
    await tester.tap(find.byTooltip('Очистить ввод'));
    await tester.pump();
    expect(find.byKey(const ValueKey('legacyMute')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('legacyModeSelect')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('legacyMode-USB')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('legacyMode-USB')));
    await tester.pumpAndSettle();
    expect(radio.mode, DemodMode.usb);
    expect(find.byKey(const ValueKey('legacyModeSelect')), findsOneWidget);
    expect(find.byKey(const ValueKey('legacyMode-USB')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('legacyStep')));
    await tester.pump();
    expect(radio.vfoOffset, 0);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    channels.dispose();
  });
}

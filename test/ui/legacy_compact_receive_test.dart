import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  for (final width in [344.0, 411.0]) {
    testWidgets('frequency field has fixed geometry at $width dp', (
      tester,
    ) async {
      final radio = DemoRadioController();
      await radio.selectDevice(radio.devices[1]); // HackRF: 1 MHz … 6 GHz
      final channels = ChannelsRepository();
      await channels.load();
      await pump(tester, radio, channels, Size(width, 882), 1);
      final freq = find.byKey(const ValueKey('legacyFrequency'));
      final field = find.byKey(const ValueKey('legacyFrequencyField'));
      final mode = find.byKey(const ValueKey('legacyModeStatus'));
      final spectrum = find.byKey(const ValueKey('legacySpectrumDrag'));
      double? fontSize() =>
          tester.renderObject<RenderParagraph>(freq).text.style!.fontSize;
      double textHeight() => tester.getRect(freq).height;
      Rect? fieldRect, modeRect, spectrumRect;
      double? size, height;
      void same(String why) {
        expect(tester.takeException(), isNull);
        if (fieldRect == null) {
          fieldRect = tester.getRect(field);
          modeRect = tester.getRect(mode);
          spectrumRect = tester.getRect(spectrum);
          size = fontSize();
          height = textHeight();
          return;
        }
        expect(tester.getRect(field), fieldRect, reason: why);
        expect(tester.getRect(mode), modeRect, reason: why);
        expect(tester.getRect(spectrum), spectrumRect, reason: why);
        expect(fontSize(), size, reason: why);
        expect(textHeight(), height, reason: why);
        // Never clipped: the text fits inside the field.
        expect(
          tester.getRect(freq).right,
          lessThanOrEqualTo(fieldRect!.right + 0.01),
          reason: why,
        );
      }

      for (final hz in [7100000, 145500000, 1090000000, 5999993750]) {
        radio.setTuning(centerFrequency: hz.toDouble(), vfoOffset: 0);
        await tester.pump();
        same('$hz Hz');
      }
      // Partial keypad entry: mute → clear button, same geometry.
      for (final k in ['1', '4', '5', '.', '5', '1', '2', '5', '0', '0', '0']) {
        await tester.tap(find.byKey(ValueKey('key-$k')));
        await tester.pump();
        same('entry $k');
      }
      expect(find.byTooltip('Очистить ввод'), findsOneWidget);
      await tester.tap(find.byTooltip('Очистить ввод'));
      await tester.pump();
      expect(find.byKey(const ValueKey('legacyMute')), findsOneWidget);
      same('after clear');
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      channels.dispose();
    });
  }

  testWidgets('mode moves to Decoder; step and digit entry stay compact', (
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
    expect(find.byKey(const ValueKey('legacyModeSelect')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('decoderSelector')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('decoderSelect-demod:4')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('decoderSelect-demod:4')));
    await tester.pumpAndSettle();
    expect(radio.mode, DemodMode.usb);
    expect(find.byKey(const ValueKey('decoderSelector')), findsOneWidget);
    expect(find.byKey(const ValueKey('decoderSelect-demod:4')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tab-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('legacyStep')));
    await tester.pump();
    expect(radio.vfoOffset, 0);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    channels.dispose();
  });
}

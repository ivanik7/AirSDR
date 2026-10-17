// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/main.dart';

import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/theme.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';
import 'package:sdr_flutter/ui/source_settings.dart';

class _SourceRadio extends DemoRadioController {
  _SourceRadio(this.items, {this.device});
  final List<SourceSetting> items;
  final SdrDeviceInfo? device;
  final applied = <(String, Object)>[];
  @override
  SdrDeviceInfo? get selectedDevice => device ?? super.selectedDevice;
  @override
  List<SourceSetting> get sourceSettings => items;
  @override
  void setSourceSetting(String id, Object value) => applied.add((id, value));
  @override
  Map<String, Object?> get demodOptions => const {
    'stereo': false,
    'lowPass': true,
  };
  @override
  Map<String, Object?> get stats => const {
    'droppedBuffers': 2,
    'audioDropped': 1,
    'audioOutput': 'AAudio',
  };
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'no promo rows; disabled legacy presets remain actionable and count as saved',
    (tester) async {
      tester.view.physicalSize = const Size(344, 882);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        FavoritesRepository.storageKey: jsonEncode({
          'version': 2,
          'nextId': 1,
          'seenDefaults': builtInFavorites.map((f) => f.id).toList(),
          'entries': [
            {
              'id': 'user-0',
              'frequencyHz': 99500000,
              'name': 'Old preset',
              'mode': 'WFM',
              'category': 'FM',
              'enabled': false,
              'builtIn': false,
            },
          ],
        }),
      });
      final favorites = FavoritesRepository();
      await favorites.load();
      final radio = DemoRadioController();
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pump();
      expect(find.textContaining('1 saved'), findsOneWidget);
      expect(find.text('Old preset'), findsOneWidget);
      expect(find.byKey(const ValueKey('toggle-user-0')), findsNothing);
      expect(find.byIcon(Icons.bookmark), findsNothing);
      expect(find.textContaining('MONITORING CHANNELS'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('apply-user-0')));
      await tester.pump();
      expect(radio.tunedFrequency, 99500000);
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pump();
      await tester.drag(find.byType(ListView).last, const Offset(0, -1200));
      await tester.pump();
      expect(find.text('LATER'), findsNothing);
      expect(find.text('Channel scan'), findsNothing);
      expect(find.textContaining('rtl_tcp'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );

  testWidgets(
    'device sheet hides exact duplicates, translates remaining controls and fits 344dp',
    (tester) async {
      tester.view.physicalSize = const Size(344, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final radio = _SourceRadio(const [
        ChoiceSetting('device', 'Device', ['rtl'], 0),
        ChoiceSetting('sampleRate', 'Sample Rate', ['2.4MHz'], 0),
        SliderSetting(
          'gain',
          'Gain 29.7 dB',
          min: 0,
          max: 28,
          step: 1,
          value: 14,
        ),
        BoolSetting('tunerAgc', 'Tuner AGC', false),
        BoolSetting('rtlAgc', 'RTL AGC', true),
        ChoiceSetting('directSampling', 'Direct Sampling', [
          'Disabled',
          'I branch',
          'Q branch',
        ], 0),
        SliderSetting(
          'ppm',
          'PPM Correction',
          min: -1000000,
          max: 1000000,
          step: 1,
          value: 0,
        ),
        BoolSetting('biasT', 'Bias T', false),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: legacyTheme(),
          home: Scaffold(body: SourceSettingsPanel(radio: radio)),
        ),
      );
      expect(find.byKey(const ValueKey('src:sampleRate')), findsNothing);
      expect(find.byKey(const ValueKey('src:gain')), findsNothing);
      expect(find.byKey(const ValueKey('src:tunerAgc')), findsNothing);
      expect(find.byKey(const ValueKey('src:rtlAgc')), findsOneWidget);
      expect(find.text('Direct sampling'), findsOneWidget);
      expect(find.text('PPM correction'), findsOneWidget);
      expect(find.text('Stereo'), findsNothing);
      expect(find.textContaining('USB drops 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('RTL AGC'));
      expect(radio.applied.last, ('rtlAgc', false));
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );

  testWidgets(
    'HackRF-specific and synthetic controls remain visible; empty selected device has no placeholder',
    (tester) async {
      tester.view.physicalSize = const Size(344, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final radio = _SourceRadio(const [
        ChoiceSetting('sampleRate', 'Sample Rate', ['2MHz'], 0),
        ChoiceSetting('bandwidth', 'Bandwidth', ['Auto', '2MHz'], 0),
        SliderSetting(
          'lnaGain',
          'LNA Gain',
          min: 0,
          max: 40,
          step: 8,
          value: 8,
        ),
        SliderSetting(
          'vgaGain',
          'VGA Gain',
          min: 0,
          max: 62,
          step: 2,
          value: 16,
        ),
        BoolSetting('amp', 'Amp Enabled', false),
      ]);
      await radio.selectDevice(radio.devices[1]);
      await tester.pumpWidget(
        MaterialApp(
          theme: legacyTheme(),
          home: Scaffold(body: SourceSettingsPanel(radio: radio)),
        ),
      );
      for (final id in ['bandwidth', 'lnaGain', 'vgaGain', 'amp']) {
        expect(find.byKey(ValueKey('src:$id')), findsOneWidget);
      }
      expect(find.text('Auto'), findsOneWidget);
      expect(find.text('RF filter bandwidth'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      final empty = _SourceRadio(
        const [],
        device: const SdrDeviceInfo(
          id: 'demo:synth',
          name: 'Signal generator',
          sampleRates: [2400000],
          gain: GainRange(min: 0, max: 0),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SourceSettingsPanel(radio: empty)),
        ),
      );
      expect(find.textContaining('No device-specific settings'), findsNothing);
      expect(find.text('Signal generator'), findsOneWidget);
      empty.dispose();
    },
  );

  testWidgets(
    'receive status contains BW and band, not duplicated modulation, at compact width',
    (tester) async {
      tester.view.physicalSize = const Size(344, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final radio = DemoRadioController();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.pump();
      final status = find.byKey(const ValueKey('legacyStatus'));
      expect(
        find.descendant(of: status, matching: find.textContaining('BW')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: status, matching: find.textContaining('WFM')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('legacyModeSelect')), findsNothing);
      expect(find.byKey(const ValueKey('legacyModeStatus')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );

  testWidgets(
    'Android system bars use the dark app background and light navigation icons',
    (tester) async {
      final radio = DemoRadioController();
      await tester.pumpWidget(SdrApp(controller: radio));
      final region = tester.widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
      );
      expect(
        region.any(
          (r) =>
              r.value.systemNavigationBarColor == LegacyColors.background &&
              r.value.systemNavigationBarIconBrightness == Brightness.light &&
              r.value.systemNavigationBarContrastEnforced == false,
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );
}

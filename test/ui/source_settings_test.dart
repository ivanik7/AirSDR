// Source settings sheet + error snackbar + status line (lib/ui/source_settings.dart, main_screen.dart)
// on a DemoRadioController extended with declarative source settings.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/main_screen.dart';

import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';


class _SettingsDemo extends DemoRadioController {
  final applied = <(String, Object)>[];
  final demod = <String, Object?>{'stereo': false, 'lowPass': true};
  String? error;

  @override
  List<SourceSetting> get sourceSettings => const <SourceSetting>[
    ChoiceSetting('sampleRate', 'Sample Rate', <String>[
      '1.024MHz',
      '2.4MHz',
    ], 1),
    SliderSetting('gain', 'Gain 29.7 dB', min: 0, max: 28, step: 1, value: 14),
    SliderSetting(
      'ppm',
      'PPM Correction',
      min: -1000000,
      max: 1000000,
      step: 1,
      value: 0,
    ),
    BoolSetting('biasT', 'Bias T', false),
  ];

  @override
  void setSourceSetting(String id, Object value) => applied.add((id, value));

  @override
  Map<String, Object?> get demodOptions => demod;

  @override
  void setDemodOption(String key, Object value) {
    demod[key] = value;
    notifyListeners();
  }

  @override
  Map<String, Object?> get stats => const <String, Object?>{
    'droppedBuffers': 3,
    'audioDropped': 0,
    'audioOutput': 'mp_audio_stream',
  };

  @override
  String? get lastError => error;

  void fail(String e) {
    error = e;
    notifyListeners();
  }

  @override
  void clearError() {
    error = null;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'settings sheet renders SourceSettings, applies them; snackbar; status line',
    (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final c = _SettingsDemo();
      await tester.pumpWidget(MaterialApp(home: MainScreen(controller: c)));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey<String>('sourceSettings')));
      await tester.pumpAndSettle();
      expect(find.text('Sample Rate'), findsNothing);
      expect(find.text('Gain 29.7 dB'), findsNothing);
      expect(find.text('Коррекция PPM'), findsOneWidget);
      expect(find.text('Питание антенны (Bias-T)'), findsOneWidget);
      expect(find.text('Стерео'), findsOneWidget);
      expect(find.textContaining('Мвыб/с'), findsOneWidget);
      expect(find.textContaining('USB потери 3'), findsOneWidget);
      expect(find.textContaining('выход mp_audio_stream'), findsOneWidget);

      await tester.tap(find.text('Питание антенны (Bias-T)'));
      await tester.pump();
      expect(c.applied.last, ('biasT', true));

      await tester.tap(find.byKey(const ValueKey<String>('demod:stereo')));
      await tester.pump();
      expect(c.demod['stereo'], isTrue);

      await tester.enterText(find.byType(TextFormField), '52');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(c.applied.last, ('ppm', 52));

      // Close the sheet; errors show as a snackbar.
      Navigator.of(tester.element(find.text('Питание антенны (Bias-T)'))).pop();
      await tester.pumpAndSettle();
      c.fail('RTL-SDR device disconnected');
      await tester.pump();
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100)); // slide-in
      }
      expect(find.byKey(const ValueKey<String>('errorSnack')), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pump();
      expect(c.lastError, isNull);

      // Status line while running.
      await tester.tap(find.byKey(const ValueKey<String>('playStop')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey<String>('statusLine')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('playStop')));
      await tester.pumpAndSettle(const Duration(seconds: 7));
    },
  );
}

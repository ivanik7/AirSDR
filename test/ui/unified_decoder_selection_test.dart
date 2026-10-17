// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _StereoRadio extends DemoRadioController {
  final options = <String, Object?>{'stereo': false};
  @override
  Map<String, Object?> get demodOptions =>
      mode == DemodMode.wfm ? options : const <String, Object?>{};
  @override
  void setDemodOption(String key, Object value) {
    options[key] = value;
    notifyListeners();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'one catalog has one concrete choice for each v3 demod and data engine',
    () {
      expect(decoderCatalog.map((d) => d.id).toList(), [
        'demod:0',
        'demod:1',
        'demod:2',
        'demod:4',
        'demod:6',
        'demod:3',
        'demod:5',
        'demod:7',
        'dmr',
        'sstv',
        'rtl_433',
        'adsb',
      ]);
      expect(
        decoderCatalog.where((d) => d.demodMode != null).length,
        DemodMode.values.length,
      );
      // DMR is a voice mode in the same list, decoded natively (no v3 demod).
      expect(
        decoderCatalog.where((d) => d.voice).map((d) => d.id),
        contains('dmr'),
      );
      expect(decoderById('dmr')!.demodMode, isNull);
      expect(decoderById('voice'), isNull);
    },
  );

  test('voice selection retunes through the centered receiver; data preview preserves it', () async {
    final radio = DemoRadioController();
    final receiver = CenteredReceiver(radio);
    final session = DecoderSession(radio, receiver: receiver);
    await radio.start();
    session.selectPreview('demod:4');
    expect(radio.mode, DemodMode.usb);
    expect(radio.running, isTrue);
    expect(radio.centerFrequency, radio.tunedFrequency);
    expect(radio.vfoOffset, 0);
    session.selectPreview('sstv');
    radio.setMode(DemodMode.am);
    expect(session.selectedId, 'sstv');
    session.selectPreview('demod:1');
    expect(radio.mode, DemodMode.wfm);
    radio.setMode(DemodMode.nfm);
    expect(session.selectedId, 'demod:0');
    session.dispose();
    receiver.dispose();
    await radio.stop();
    radio.dispose();
  });

  testWidgets(
    'one searchable/list chooser without generic Audio or nested mode picker',
    (tester) async {
      final radio = DemoRadioController();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      expect(find.byKey(const ValueKey('legacyModeSelect')), findsNothing);
      expect(find.text('Режим приёма'), findsNothing);
      expect(find.text('Аудио'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('decoderSelector')));
      await tester.pumpAndSettle();
      for (final mode in DemodMode.values) {
        expect(
          find.byKey(ValueKey('decoderSelect-demod:${mode.id}')),
          findsOneWidget,
        );
      }
      for (final id in ['sstv', 'rtl_433', 'adsb']) {
        expect(find.byKey(ValueKey('decoderSelect-$id')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('decoderSelect-demod:4')));
      await tester.pumpAndSettle();
      expect(radio.mode, DemodMode.usb);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );

  testWidgets(
    'WFM from the one list shows live stereo at 344dp without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(344, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final radio = _StereoRadio();
      radio.setMode(DemodMode.nfm);
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('decoderSelector')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decoderSelect-demod:1')));
      await tester.pumpAndSettle();
      expect(radio.mode, DemodMode.wfm);
      expect(find.byKey(const ValueKey('demod:stereo')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('demod:stereo')));
      await tester.tap(find.byKey(const ValueKey('demod:stereo')));
      await tester.pump();
      expect(radio.options['stereo'], isTrue);
      expect(find.byKey(const ValueKey('decoderPanel-sstv')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );
}

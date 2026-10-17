// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/decoders/dmr_panel.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';

class _Backend implements DecoderBackend {
  final calls = <Map<String, Object>>[];
  @override
  Set<String> get availableIds => {'dmr'};
  @override
  bool select(String? id, Map<String, Object> config) {
    if (id == 'dmr') calls.add(config);
    return true;
  }

  @override
  DecoderEvent? poll(int afterSequence) => null;
}

class _Radio extends DemoRadioController {
  _Radio(this.backend);
  final _Backend backend;
  @override
  DecoderBackend get decoderBackend => backend;
}

void main() {
  for (final width in [344.0, 690.0]) {
    testWidgets('DMR panel fits $width dp and configures native filters', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = _Backend();
      final radio = _Radio(backend);
      await radio.start();
      final session = DecoderSession(radio)..selectPreview('dmr');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DmrDecoderPanel(session: session),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('dmrSlot-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('dmrSlot-2')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('dmrSetting-slot_filter')),
      );
      await tester.tap(find.byKey(const ValueKey('dmrSetting-slot_filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TS2').last);
      await tester.pumpAndSettle();
      expect(backend.calls.last['slot_filter'], 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      await radio.stop();
      radio.dispose();
    });
  }
}

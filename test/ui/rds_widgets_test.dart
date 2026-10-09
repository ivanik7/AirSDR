// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/decoders/rds_widgets.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _Events implements DecoderBackend, RbdsDecoderBackend {
  final events = <DecoderEvent>[];
  final controls = <bool>[];
  @override
  bool get rbdsAvailable => true;
  @override
  bool setRbds(bool value) {
    controls.add(value);
    return true;
  }

  @override
  Set<String> get availableIds => {};
  @override
  bool select(String? id, Map<String, Object> config) => true;
  @override
  DecoderEvent? poll(int afterSequence) {
    for (final e in events) {
      if (e.sequence > afterSequence) return e;
    }
    return null;
  }
}

class _Radio extends DemoRadioController {
  _Radio(this.backend);
  final _Events backend;
  @override
  DecoderBackend get decoderBackend => backend;
}

void main() {
  testWidgets(
    'WFM station line and details fit 344 dp, RBDS toggle persists in preset settings',
    (tester) async {
      tester.view.physicalSize = const Size(904, 1811);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = _Events();
      final radio = _Radio(backend);
      final session = DecoderSession(radio);
      await radio.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: session,
              builder: (context, _) => ListView(
                children: [
                  RdsStationLine(session: session),
                  RdsDetailsPanel(session: session),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('RDS: нет сигнала'), findsOneWidget);
      final hz = radio.tunedFrequency.round();
      backend.events.add(
        DecoderEvent(
          1,
          1,
          DecoderResult.message,
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'source': 'rds',
                'version': 1,
                'event': 'state',
                'frequency_hz': hz,
                'sync': true,
                'fields': {
                  'pi': '6201',
                  'ps': 'LONG RADIO NAME',
                  'prog_type': 'Pop Music',
                  'radiotext': 'This is a very long radio text message for the compact cover screen',
                },
              }),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.textContaining('LONG RADIO NAME'), findsWidgets);
      expect(find.textContaining('6201'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('rdsRbds')));
      await tester.tap(find.byKey(const ValueKey('rdsRbds')));
      await tester.pump();
      expect(backend.controls.last, true);
      expect(
        session.settingsFor(decoderIdForMode(DemodMode.wfm))['rbds'],
        true,
      );
      expect(radio.running, true);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      radio.dispose();
    },
  );
}

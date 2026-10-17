// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/legacy/decoder_screen.dart';

class _Backend implements DecoderBackend {
  final events = <DecoderEvent>[];
  final selections = <String?>[];
  @override
  Set<String> get availableIds => {'adsb'};
  @override
  bool select(String? id, Map<String, Object> config) {
    selections.add(id);
    return id != null;
  }

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
  final _Backend backend;
  @override
  DecoderBackend get decoderBackend => backend;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('live aircraft and explicit rate/tune controls on cover width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(344, 690) * 2.625;
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final backend = _Backend();
    final radio = _Radio(backend)..setSampleRate(2048000);
    final receiver = CenteredReceiver(radio);
    final session = DecoderSession(radio, receiver: receiver);
    await radio.start();
    session.selectPreview('adsb');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DecoderScreen(
            controller: radio,
            receiver: receiver,
            session: session,
          ),
        ),
      ),
    );
    expect(find.text('not ready: set sample rate 2.4 MS/s'), findsOneWidget);
    expect(backend.selections.last, isNull);
    await tester.tap(find.byKey(const ValueKey('adsbSetRate')));
    await tester.pump();
    expect(radio.sampleRate, 2400000);
    expect(backend.selections.last, 'adsb');
    await tester.tap(find.byKey(const ValueKey('adsbQuickTune')));
    await tester.pump();
    expect(radio.tunedFrequency, 1090000000);
    expect(radio.vfoOffset, 0);
    final now = DateTime.now().millisecondsSinceEpoch;
    backend.events.add(
      DecoderEvent(
        1,
        1,
        DecoderResult.aircraft,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'source': 'adsb',
              'timestamp_ms': now,
              'input_rate_hz': 2400000,
              'message_rate': 3.0,
              'crc_fixed': 0,
              'aircraft': [
                {
                  'icao': 'ABC123',
                  'callsign': 'TEST123',
                  'last_seen_ms': now,
                  'messages': 9,
                  'altitude_ft': 24000,
                  'latitude': 51.5,
                  'longitude': -0.1,
                },
              ],
            }),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.textContaining('Messages/s: 3.0'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('adsbAircraft-ABC123')),
    );
    await tester.tap(find.byKey(const ValueKey('adsbAircraft-ABC123')));
    await tester.pump();
    expect(find.textContaining('Altitude: 24000 ft'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('adsbLocation')));
    await tester.tap(find.byKey(const ValueKey('adsbLocation')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('adsbLatitude')), '51.5');
    await tester.enterText(find.byKey(const ValueKey('adsbLongitude')), '-0.1');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('adsb.receiver.latitude'), 51.5);
    await tester.ensureVisible(find.byKey(const ValueKey('adsbSort')));
    await tester.tap(find.byKey(const ValueKey('adsbSort')));
    await tester.pump();
    expect(find.text('By distance'), findsOneWidget);
    expect(find.textContaining('0.0 km'), findsWidgets);
    expect(tester.takeException(), isNull);
    // Each native snapshot is complete: an empty update removes old tracks.
    backend.events.add(
      DecoderEvent(
        2,
        1,
        DecoderResult.aircraft,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'source': 'adsb',
              'timestamp_ms': now + 1000,
              'input_rate_hz': 2400000,
              'message_rate': 0,
              'crc_fixed': 0,
              'aircraft': [],
            }),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const ValueKey('adsbAircraft-ABC123')), findsNothing);
    expect(session.adsbSnapshot?.aircraft, isEmpty);
    radio.setTuning(centerFrequency: 1091000000, vfoOffset: 0);
    await tester.pump();
    expect(session.adsbSnapshot, isNull);
    session.dispose();
    receiver.dispose();
    await tester.pumpWidget(const SizedBox());
    await radio.stop();
    radio.dispose();
  });
}

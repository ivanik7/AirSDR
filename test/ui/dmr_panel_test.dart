// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_panels.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/decoders/dmr_panel.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';

class _Backend implements DecoderBackend {
  final calls = <Map<String, Object>>[];
  final events = <DecoderEvent>[];
  @override
  Set<String> get availableIds => {'dmr'};
  @override
  bool select(String? id, Map<String, Object> config) {
    if (id == 'dmr') calls.add(config);
    return true;
  }

  @override
  DecoderEvent? poll(int afterSequence) {
    for (final event in events) {
      if (event.sequence > afterSequence) return event;
    }
    return null;
  }

  void add(int sequence, Map<String, Object?> data) => events.add(
    DecoderEvent(
      sequence,
      1,
      DecoderResult.message,
      Uint8List.fromList(utf8.encode(jsonEncode(data))),
    ),
  );
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

  test('slot toggle never mutes both slots', () {
    expect(DmrDecoderPanel.toggledSlotMask(3, 0), 2);
    expect(DmrDecoderPanel.toggledSlotMask(3, 1), 1);
    expect(DmrDecoderPanel.toggledSlotMask(2, 0), 3);
    expect(DmrDecoderPanel.toggledSlotMask(1, 0), isNull);
    expect(DmrDecoderPanel.toggledSlotMask(2, 1), isNull);
  });

  testWidgets('without a native DMR backend the panel is honestly '
      'unavailable and its controls are disabled', (tester) async {
    final radio = DemoRadioController();
    await radio.start();
    final session = DecoderSession(radio)..selectPreview('dmr');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: DmrDecoderPanel(session: session)),
        ),
      ),
    );
    expect(session.active, isFalse);
    expect(find.text('Unavailable in the current native build'), findsOneWidget);
    final dropdown = tester.widget<DropdownButton<int>>(
      find.byKey(const ValueKey('dmrSetting-slot_filter')),
    );
    expect(dropdown.onChanged, isNull);
    final toggle = tester.widget<InkWell>(
      find.byKey(const ValueKey('dmrSlotToggle-1')),
    );
    expect(toggle.onTap, isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await radio.stop();
    radio.dispose();
  });

  for (final width in [344.0, 690.0]) {
    testWidgets('DMR live call card, encrypted badge, history and slot tap '
        'at $width dp', (tester) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = _Backend();
      final radio = _Radio(backend);
      await radio.start();
      final receiver = CenteredReceiver(radio);
      final session = DecoderSession(radio, receiver: receiver)
        ..selectPreview('dmr');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: session,
              builder: (context, _) => SingleChildScrollView(
                child: buildDecoderPanel(
                  selectedId: session.selectedId,
                  controller: radio,
                  receiver: receiver,
                  session: session,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('decoderPanelFor-dmr')), findsOneWidget);
      expect(find.byKey(const ValueKey('decoderPanel-dmr')), findsOneWidget);
      expect(find.byKey(const ValueKey('decoderPanel-voice')), findsNothing);
      expect(find.byKey(const ValueKey('dmrIdLookupNote')), findsOneWidget);
      backend.add(1, {
        'schema': 'dmr/1',
        'protocol': 'DMR',
        'slot': 1,
        'sync': 'voice',
        'type': 'group',
        'source': 2620001,
        'target': 91,
        'privacy': true,
        'color_code': 1,
        'talkeralias': 'UN7XYZ Test',
        'lat': 43.25,
        'lon': 76.95,
        'duration_ms': 2400,
      });
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.textContaining('TG 91'), findsOneWidget);
      expect(find.textContaining('Source 2620001'), findsOneWidget);
      expect(find.textContaining('CC 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('dmrEncrypted-s2')), findsOneWidget);
      expect(find.textContaining('UN7XYZ Test'), findsOneWidget);
      expect(find.textContaining('GPS: 43.25000, 76.95000'), findsOneWidget);
      expect(find.textContaining('2.4 s'), findsOneWidget);
      expect(find.text('Voice · sync'), findsOneWidget);
      backend.add(2, {'schema': 'dmr/1', 'protocol': 'DMR', 'slot': 1});
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Call history · 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('dmrEncrypted-h2')), findsOneWidget);
      expect(find.byKey(const ValueKey('dmrEncrypted-s2')), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('dmrSlotToggle-1')));
      await tester.pump();
      expect(backend.calls.last['slot_filter'], 2);
      expect(find.byKey(const ValueKey('dmrSlotMuted-1')), findsOneWidget);
      // History survives a filter change; the TS2-only mask can't drop TS2.
      expect(find.text('Call history · 1'), findsOneWidget);
      final before = backend.calls.length;
      await tester.tap(find.byKey(const ValueKey('dmrSlotToggle-2')));
      await tester.pump();
      expect(backend.calls.length, before);
      await tester.tap(find.byKey(const ValueKey('dmrClearHistory')));
      await tester.pump();
      expect(find.text('Call history · 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      receiver.dispose();
      await radio.stop();
      radio.dispose();
    });
  }
}

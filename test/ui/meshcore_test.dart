// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/decoders/meshcore_keys.dart';
import 'package:sdr_flutter/ui/decoders/meshcore_packets.dart';

import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/legacy/decoder_screen.dart';

import 'meshtastic_fixtures.dart';

const secret = '00112233445566778899AABBCCDDEEFF';
Map<String, Object?> advert({bool valid = true}) => {
  'mode': 'MeshCore',
  'timestamp': 1791500001000,
  'freq': 869618000,
  'phy': {'crc': 1, 'sf': 8, 'bw': 62.5, 'cr': 8, 'level': -20.0},
  'raw': 'AABB',
  'header': {'version': 1, 'route': 1, 'type': 4, 'type_name': 'ADVERT'},
  'path': {'hash_size': 1, 'hashes': <String>[]},
  'payload': {
    'public_key': 'AABBCCDD',
    'signature_valid': valid,
    if (valid) 'advert': {'name': 'Beacon'},
  },
};
Map<String, Object?> group({bool verified = true}) => {
  ...advert(),
  'header': {'version': 1, 'route': 1, 'type': 5, 'type_name': 'GRP_TXT'},
  'payload': {
    'channel_hash': '2A',
    'encrypted': !verified,
    if (verified) 'text': 'Hello',
    if (verified) 'channel': 'Public',
  },
};

void main() {
  test('catalog config validates MeshCore bandwidth and hex-only secrets', () {
    final d = decoderById('meshcore')!;
    expect(d.input, DecoderInput.baseband);
    expect(d.requiredRateHz, 1000000);
    expect(d.result, DecoderResult.message);
    expect(d.settings.first.accept('6'), '6');
    expect(d.settings.first.accept('10'), isNull);
    final channels = d.settings.last;
    expect(
      channels.accept([
        {'name': 'Ops', 'secret': secret},
      ]),
      [
        {'name': 'Ops', 'secret': secret},
      ],
    );
    expect(
      channels.accept([
        {'name': 'Ops', 'secret': 'AQ=='},
      ]),
      isNull,
    );
    expect(
      channels.accept([
        {'name': 'Ops', 'secret': secret},
        {'name': 'Ops', 'secret': secret},
      ]),
      isNull,
    );
    expect(
      channels.accept([
        {'name': 'é' * 17, 'secret': secret},
      ]),
      isNull,
    );
    expect(
      channels.accept(
        List.generate(9, (i) => {'name': '$i', 'secret': secret}),
      ),
      isNull,
    );
    expect(
      meshcoreChannels(
        channels.accept([
          {'name': 'Ops', 'secret': secret},
        ]),
      ).single.secret,
      secret,
    );
  });

  test('only signed adverts form nodes and only MAC-verified group text forms messages', () {
    final log = MeshcoreLog();
    for (final (i, event) in [
      advert(valid: false),
      group(verified: false),
      group(),
      advert(),
    ].indexed) {
      final packet = MeshcorePacket.fromEvent(
        i + 1,
        event,
        receivedAt: DateTime.utc(2026),
        secrets: {secret.toLowerCase()},
      );
      expect(packet, isNotNull);
      log.add(packet!);
    }
    expect(log.packets.length, 4);
    expect(log.nodes.length, 1);
    expect(log.nodes.single.name, 'Beacon');
    expect(log.messages.length, 1);
    expect(log.messages.single.text, 'Hello');
    expect(
      MeshcorePacket.fromEvent(5, {
        ...group(),
        'mode': 'Meshtastic',
      }, receivedAt: DateTime.utc(2026)),
      isNull,
    );
    final injected = MeshcorePacket.fromEvent(
      6,
      {...group(), 'extra': 'echo $secret'},
      receivedAt: DateTime.utc(2026),
      secrets: {secret.toLowerCase()},
    )!;
    expect(injected.formattedJson, isNot(contains(secret)));
  });

  test('bounded logs exclude malformed and unsigned node data', () {
    final log = MeshcoreLog();
    for (var i = 0; i < 510; i++) {
      log.add(
        MeshcorePacket.fromEvent(i, {
          ...advert(),
          'payload': {
            'public_key': i.toRadixString(16).padLeft(64, '0').toUpperCase(),
            'signature_valid': true,
            'advert': {'name': 'Node $i'},
          },
        }, receivedAt: DateTime.fromMillisecondsSinceEpoch(i, isUtc: true))!,
      );
    }
    expect(log.packets.length, MeshcoreLog.packetLimit);
    expect(log.nodes.length, MeshcoreLog.nodeLimit);
    log.add(
      MeshcorePacket.fromEvent(511, {
        ...advert(),
        'error': 'malformed_packet',
      }, receivedAt: DateTime.utc(2026))!,
    );
    expect(log.nodes.length, MeshcoreLog.nodeLimit);
    log.clearPackets();
    expect(log.packets, isEmpty);
    expect(log.nodes.length, MeshcoreLog.nodeLimit);
    log.clear();
    expect(log.nodes, isEmpty);
  });

  testWidgets(
    '344dp selected-only panel, masked key, quick tune and config round trip',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(344, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = MeshcoreBackend();
      final radio = MeshcoreRadio(backend);
      radio.setSampleRate(2048000);
      await radio.start();
      final receiver = CenteredReceiver(radio);
      final session = DecoderSession(radio, receiver: receiver);
      session.selectPreview('meshcore');
      session.setSetting('meshcore', 'bandwidth', '7');
      session.setSetting('meshcore', 'channels', [
        {'name': 'Ops', 'secret': secret},
      ]);
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
      expect(
        find.byKey(const ValueKey('decoderPanelFor-meshcore')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('decoderPanelFor-meshtastic')),
        findsNothing,
      );
      expect(find.textContaining(secret), findsNothing);
      expect(find.textContaining('Ops'), findsWidgets);
      expect(tester.takeException(), isNull);
      expect((backend.calls.last.$2['settings'] as Map)['channels'], [
        {'name': 'Ops', 'secret': secret},
      ]);
      session.applyStored('meshcore', {
        'bandwidth': '7',
        'channels': [
          {'name': 'Ops', 'secret': secret},
        ],
      });
      expect(session.settingsFor('meshcore')['bandwidth'], '7');
      expect(jsonEncode(session.settingsFor('meshcore')), contains(secret));
      backend.add({...group(), 'extra': 'echo $secret'});
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(find.textContaining('Text 1'), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      final packet = find.byKey(const ValueKey('meshcorePacket-1'));
      await tester.ensureVisible(packet);
      await tester.tap(packet);
      await tester.pumpAndSettle();
      final detail = find.byKey(const ValueKey('meshcoreJson-1'));
      expect(detail, findsOneWidget);
      expect(tester.widget<SelectableText>(detail).data, contains('GRP_TXT'));
      expect(
        tester.widget<SelectableText>(detail).data,
        isNot(contains(secret)),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('meshcoreTune')));
      await tester.tap(find.byKey(const ValueKey('meshcoreTune')));
      await tester.pump();
      expect(radio.tunedFrequency, 869612500); // normal 12.5 kHz VFO grid
      expect(radio.centerFrequency, radio.tunedFrequency);
      expect(radio.vfoOffset, 0);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('meshcoreAddKey')));
      await tester.tap(find.byKey(const ValueKey('meshcoreAddKey')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('meshcoreKeySecret'));
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      await radio.stop();
      radio.dispose();
    },
  );
}

class MeshcoreBackend extends MeshBackend {
  @override
  Set<String> get availableIds => {'meshcore'};
}

class MeshcoreRadio extends MeshRadio {
  MeshcoreRadio(super.backend);
}

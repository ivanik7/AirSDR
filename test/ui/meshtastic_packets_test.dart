// SPDX-License-Identifier: GPL-3.0-or-later
// Meshtastic packet log, node list and channel-key handling, fed with the
// real native parser output in fixtures/meshtastic_native_events.json
// (regenerated and checked by native ctest sdrcore_meshtastic_ui_fixture).
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/decoders/meshtastic_keys.dart';
import 'package:sdr_flutter/ui/decoders/meshtastic_packets.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

import 'meshtastic_fixtures.dart';

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 160));

Future<(MeshRadio, DecoderSession)> startMeshtastic() async {
  final radio = MeshRadio(MeshBackend());
  radio.setSampleRate(2048000);
  await radio.start();
  final session = DecoderSession(radio);
  session.selectPreview('meshtastic');
  return (radio, session);
}

void main() {
  group('native fixture', () {
    test('contains decoded, encrypted and node events', () {
      final groups = loadNativeEvents();
      expect(groups.keys, containsAll(['default', 'aes256', 'aes128_hex']));
      final all = groups.values.expand((e) => e).toList();
      expect(all.every((e) => e['mode'] == 'Meshtastic'), isTrue);
      expect(all.any((e) => e['encrypted'] == true), isTrue);
      expect(all.any((e) => e['type'] == 'NODEINFO_APP'), isTrue);
    });
  });

  group('MeshtasticPacket', () {
    test('real on-air text packet: header, PHY and content', () {
      final p = MeshtasticPacket.fromEvent(
        1,
        event('default', 'real_meshtastic_sdr_text'),
        receivedAt: DateTime.utc(2030),
      )!;
      expect(p.text, 'TestingCLU1234');
      expect(p.from, '!da6354b4');
      expect(p.to, 'ALL');
      expect(p.headline, 'TEXT_MESSAGE_APP');
      expect(p.frequencyHz, 869525000);
      expect(p.phySummary, 'SF11 · BW 250 kHz · CR 4/5');
      expect(p.signalSummary, 'level 10.5 dB · SNR 11.0 dB');
      expect(p.headerSummary, contains('id 8caa71b9'));
      expect(p.headerSummary, contains('hop 0/3'));
      expect(p.headerSummary, contains('ch 0x08'));
      // Native `timestamp` (epoch ms) wins over arrival time.
      expect(p.time, DateTime.fromMillisecondsSinceEpoch(1791500001000,
          isUtc: true));
    });

    test('lorarx Hz bandwidth is shown in kHz', () {
      final raw = {...event('default', 'real_meshtastic_sdr_text')};
      raw['phy'] = {'bw': 250000.0, 'sf': 9, 'cr': 5};
      final p = MeshtasticPacket.fromEvent(1, raw, receivedAt: DateTime.now())!;
      expect(p.phySummary, 'SF9 · BW 250 kHz · CR 4/5');
    });

    test('unknown key and wrong key are explicit encrypted states', () {
      final unknown = MeshtasticPacket.fromEvent(
        1,
        event('default', 'unknown_key_hash_mismatch'),
        receivedAt: DateTime.now(),
      )!;
      expect(unknown.encrypted, isTrue);
      expect(unknown.headline, 'Encrypted · unknown key');
      expect(unknown.text, isNull);
      expect(unknown.dataRows.map((r) => r.$1), contains('ciphertext'));
      final wrong = MeshtasticPacket.fromEvent(
        2,
        event('aes128_hex', 'aes128_wrong_key_reported_encrypted'),
        receivedAt: DateTime.now(),
      )!;
      expect(wrong.headline, contains('key did not decode'));
    });

    test('OpenWebRX+ attribute conversions', () {
      final p = MeshtasticPacket.fromEvent(
        1,
        event('default', 'telemetry_device'),
        receivedAt: DateTime.now(),
      )!;
      final rows = Map.fromEntries(p.dataRows.map((r) => MapEntry(r.$1, r.$2)));
      expect(rows['battery_level'], '87 %');
      expect(rows['voltage'], '4.11 V');
      expect(rows['channel_utilization'], '12 %');
      expect(rows['time'], '2026-10-08T22:55:00Z'); // date -u -d @1791500100
      final node = MeshtasticPacket.fromEvent(
        2,
        event('default', 'nodeinfo'),
        receivedAt: DateTime.now(),
      )!;
      final nodeRows =
          Map.fromEntries(node.dataRows.map((r) => MapEntry(r.$1, r.$2)));
      expect(nodeRows['macaddr'], '48CA433C1A2B');
      expect(formatMeshtasticAttr('latitude_i', 516789012), '51.6789012');
      expect(formatMeshtasticAttr('temperature', 21.7), '21.7 °C');
    });

    test('non-Meshtastic or malformed events are rejected', () {
      expect(
        MeshtasticPacket.fromEvent(1, {'model': 'Acurite'},
            receivedAt: DateTime.now()),
        isNull,
      );
      expect(
        MeshtasticPacket.fromEvent(1, {'mode': 'Meshtastic', 'src': 1},
            receivedAt: DateTime.now()),
        isNull,
      );
    });
  });

  group('MeshtasticLog', () {
    test('newest first, bounded packet and text logs', () {
      final log = MeshtasticLog();
      final base = event('default', 'real_meshtastic_sdr_text');
      for (var i = 0; i < MeshtasticLog.packetLimit + 20; i++) {
        log.add(MeshtasticPacket.fromEvent(
          i + 1,
          {...base, 'packet_id': i},
          receivedAt: DateTime.now(),
        )!);
      }
      expect(log.packets.length, MeshtasticLog.packetLimit);
      expect(log.messages.length, MeshtasticLog.messageLimit);
      expect(log.packets.first.sequence, MeshtasticLog.packetLimit + 20);
      expect(log.packets.last.sequence, 21);
    });

    test('node list built from real NODEINFO, POSITION and TELEMETRY', () {
      final log = MeshtasticLog();
      var seq = 0;
      for (final e in loadNativeEvents()['default']!) {
        log.add(MeshtasticPacket.fromEvent(++seq, e,
            receivedAt: DateTime.now())!);
      }
      final tst = log.nodes.firstWhere((n) => n.id == '!433c1a2b');
      expect(tst.shortName, 'TST');
      expect(tst.longName, 'Test Heltec V3');
      expect(tst.hwModel, 'HELTEC_V3');
      expect(tst.lat, closeTo(51.6789012, 1e-9));
      expect(tst.lon, closeTo(-0.1234567, 1e-9));
      expect(tst.batteryLevel, 87);
      expect(tst.voltage, closeTo(4.105, 1e-6));
      expect(tst.snr, isNotNull);
      expect(tst.packets, greaterThan(3));
      // Environment telemetry alone creates a node without a name.
      expect(log.nodes.any((n) => n.id == '!9e7f0001'), isTrue);
      // A text from an unseen node without NODEINFO does not invent one.
      expect(log.nodes.any((n) => n.id == '!da6354b4'), isFalse);
      // Newest-heard first.
      for (var i = 1; i < log.nodes.length; i++) {
        expect(
          log.nodes[i - 1].lastHeard.isBefore(log.nodes[i].lastHeard),
          isFalse,
        );
      }
    });

    test('encrypted packets never create nodes', () {
      final log = MeshtasticLog();
      log.add(MeshtasticPacket.fromEvent(
        1,
        event('default', 'unknown_key_hash_mismatch'),
        receivedAt: DateTime.now(),
      )!);
      expect(log.nodes, isEmpty);
      expect(log.messages, isEmpty);
      expect(log.packets.length, 1);
    });

    test('node list is bounded', () {
      final log = MeshtasticLog();
      final base = event('default', 'nodeinfo');
      for (var i = 0; i < MeshtasticLog.nodeLimit + 10; i++) {
        log.add(MeshtasticPacket.fromEvent(
          i + 1,
          {...base, 'src': 0x1000 + i, 'timestamp': 1791500000000 + i * 1000},
          receivedAt: DateTime.now(),
        )!);
      }
      expect(log.nodes.length, MeshtasticLog.nodeLimit);
      expect(log.nodes.first.nodeNum, 0x1000 + MeshtasticLog.nodeLimit + 9);
      expect(log.nodes.any((n) => n.nodeNum == 0x1000), isFalse);
    });
  });

  group('channel keys', () {
    test('resolve like native resolve_key', () {
      const def = 'd4f1bb3a20290759f0bcffabcf4e6901';
      String hex(MeshtasticKey k) =>
          k.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      for (final s in ['AQ==', 'aq==', 'default', ' Default ', '01', '0x01']) {
        expect(hex(resolveMeshtasticKey(s)), def, reason: s);
      }
      expect(() => resolveMeshtasticKey('AQ'), throwsFormatException);
      expect(hex(resolveMeshtasticKey('Ag==')),
          'd4f1bb3a20290759f0bcffabcf4e6902');
      expect(hex(resolveMeshtasticKey('0A')),
          'd4f1bb3a20290759f0bcffabcf4e690a');
      expect(resolveMeshtasticKey('AA==').bytes, isEmpty);
      expect(
        hex(resolveMeshtasticKey(
            '0x8A:1F:0C:55-E2:D4:B6:97:03:11:AA:BB:CC:DD:EE:FF')),
        '8a1f0c55e2d4b6970311aabbccddeeff',
      );
      expect(
        hex(resolveMeshtasticKey(
            'ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=')),
        '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f',
      );
      expect(hex(resolveMeshtasticKey('aabbcc')),
          'aabbcc00000000000000000000000000');
      expect(resolveMeshtasticKey('a' * 34).bytes.length, 32);
      expect(() => resolveMeshtasticKey(''), throwsFormatException);
      expect(() => resolveMeshtasticKey('b' * 66), throwsFormatException);
      const secret = 'not*a*key';
      final err = meshtasticKeyError(secret)!;
      expect(err.contains(secret), isFalse);
    });

    test('kind labels reveal no key material', () {
      expect(resolveMeshtasticKey('AQ==').kind, 'default key');
      expect(resolveMeshtasticKey('AA==').kind, 'no encryption');
      expect(resolveMeshtasticKey('Ag==').kind, 'default key #2');
      expect(resolveMeshtasticKey('aabbcc').kind, 'AES-128');
      expect(
        resolveMeshtasticKey('ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=')
            .kind,
        'AES-256',
      );
    });

    test('channels setting normalization', () {
      final n = normalizeMeshtasticChannels([
        {'name': 'Ops', 'psk': ' AQ== '},
        {'name': 'x' * 12, 'psk': 'AQ=='}, // name too long
        {'name': 'Bad', 'psk': 'not*a*key'},
        {'psk': 'Ag=='}, // name defaults to ''
        'junk',
        for (var i = 0; i < 10; i++) {'name': 'c$i', 'psk': 'AQ=='},
      ])! as List;
      expect(n.length, meshtasticMaxChannels);
      expect(n[0], {'name': 'Ops', 'psk': 'AQ=='});
      expect(n[1], {'name': '', 'psk': 'Ag=='});
      expect(normalizeMeshtasticChannels('AQ=='), isNull);
    });

    test('configured private keys are redacted from packet JSON', () {
      const b64 = 'ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=';
      final secrets = meshtasticKeySecrets([
        {'name': 'Ops', 'psk': b64},
        {'name': '', 'psk': 'AQ=='}, // public: not a secret
      ]);
      final raw = {
        ...event('default', 'real_meshtastic_sdr_text'),
        'message': 'leaked $b64',
        'data': {
          'note': 'key=202122232425262728292A2B2C2D2E2F'
              '303132333435363738393a3b3c3d3e3f',
        },
      };
      final p = MeshtasticPacket.fromEvent(1, raw,
          receivedAt: DateTime.now(), secrets: secrets)!;
      expect(p.text, '[redacted]');
      expect((p.data!)['note'], '[redacted]');
      expect(p.formattedJson.contains(b64), isFalse);
      expect(p.formattedJson.toLowerCase().contains('2e2f3031'), isFalse);
      // The public default key text is not treated as a secret.
      expect(secrets.any((s) => s.contains('aq==')), isFalse);
    });
  });

  group('DecoderSession', () {
    test('selection sends preset and channel keys in the versioned config',
        () async {
      final (radio, session) = await startMeshtastic();
      final backend = radio.backend;
      expect(session.active, isTrue);
      expect(backend.calls.last.$1, 'meshtastic');
      expect(backend.calls.last.$2, {
        'version': 1,
        'settings': {'preset': 'LongFast', 'region': 'EU_868', 'channels': []},
      });
      session.setSetting('meshtastic', 'channels', [
        {'name': 'Ops', 'psk': 'aabbcc'},
      ]);
      expect(
        (backend.calls.last.$2['settings'] as Map)['channels'],
        [{'name': 'Ops', 'psk': 'aabbcc'}],
      );
      // An invalid key list is rejected without restarting the decoder.
      final n = backend.calls.length;
      session.setSetting('meshtastic', 'channels', 'oops');
      expect(backend.calls.length, n);
      session.setSetting('meshtastic', 'preset', 'MediumFast');
      expect((backend.calls.last.$2['settings'] as Map)['preset'],
          'MediumFast');
      session.dispose();
      radio.dispose();
    });

    test('native events fill the log; non-Meshtastic events are ignored',
        () async {
      final (radio, session) = await startMeshtastic();
      for (final e in loadNativeEvents()['default']!) {
        radio.backend.add(e);
      }
      radio.backend.add({'model': 'Acurite-Tower', 'id': 1});
      await tick();
      final log = session.meshtastic;
      expect(log.packets.length, loadNativeEvents()['default']!.length);
      expect(log.packets.first.json['fixture'],
          loadNativeEvents()['default']!.last['fixture']);
      expect(log.messages.map((m) => m.text), contains('TestingCLU1234'));
      expect(log.nodes, isNotEmpty);
      expect(session.messages, isEmpty); // rtl_433 log untouched
      session.dispose();
      radio.dispose();
    });

    test('retune, stream generation and mode changes clear packets',
        () async {
      final (radio, session) = await startMeshtastic();
      final ev = event('default', 'nodeinfo');
      radio.backend.add(ev);
      await tick();
      expect(session.meshtastic.packets.length, 1);
      expect(session.meshtastic.nodes.length, 1);
      // Retune: stale packets go, heard nodes stay (like OWRX+ node cache).
      radio.setTuning(
        centerFrequency: radio.tunedFrequency + 25000,
        vfoOffset: 0,
      );
      expect(session.meshtastic.packets, isEmpty);
      expect(session.meshtastic.nodes.length, 1);
      // New native stream generation drops the old packets.
      radio.backend.events.clear();
      radio.backend.add(ev, generation: 1);
      await tick();
      expect(session.meshtastic.packets.length, 1);
      radio.backend.add(event('default', 'position'), generation: 2);
      await tick();
      expect(session.meshtastic.packets.length, 1);
      expect(session.meshtastic.packets.first.type, 'POSITION_APP');
      // Selecting another decoder stops Meshtastic results.
      session.selectPreview('rtl_433');
      expect(session.meshtastic.packets, isEmpty);
      radio.backend.add(ev, generation: 2);
      await tick();
      expect(session.meshtastic.packets, isEmpty);
      session.dispose();
      radio.dispose();
    });

    test('no packets while the receiver cannot feed 1 MS/s', () async {
      final (radio, session) = await startMeshtastic();
      radio.setSampleRate(250000);
      expect(session.active, isFalse);
      expect(session.failureReason, contains('1 MS/s'));
      radio.backend.add(event('default', 'nodeinfo'));
      await tick();
      expect(session.meshtastic.packets, isEmpty);
      session.dispose();
      radio.dispose();
    });

    test('clear keeps nodes unless asked', () async {
      final (radio, session) = await startMeshtastic();
      radio.backend.add(event('default', 'nodeinfo'));
      await tick();
      session.clearMeshtastic();
      expect(session.meshtastic.packets, isEmpty);
      expect(session.meshtastic.nodes.length, 1);
      session.clearMeshtastic(nodes: true);
      expect(session.meshtastic.nodes, isEmpty);
      session.dispose();
      radio.dispose();
    });
  });

  test('preset round-trip keeps preset, region and channel keys', () async {
    SharedPreferences.setMockInitialValues({});
    final favorites = FavoritesRepository();
    await favorites.load();
    final saved = favorites.add(
      frequencyHz: 869525000,
      name: 'Mesh EU',
      mode: DemodMode.nfm,
      category: 'UHF',
      decoderId: 'meshtastic',
      decoderSettings: {
        'preset': 'MediumFast',
        'region': 'RU',
        'channels': [
          {'name': 'Ops', 'psk': 'aabbcc'},
          {'name': 'Bad', 'psk': '???'},
        ],
      },
    );
    expect(saved.decoderSettings['channels'], [
      {'name': 'Ops', 'psk': 'aabbcc'},
    ]);
    await favorites.flush();
    final reopened = FavoritesRepository();
    await reopened.load();
    final restored = reopened.entries.firstWhere((e) => e.id == saved.id);
    expect(restored.decoderId, 'meshtastic');
    expect(restored.decoderSettings, {
      'preset': 'MediumFast',
      'region': 'RU',
      'channels': [
        {'name': 'Ops', 'psk': 'aabbcc'},
      ],
    });
  });
}

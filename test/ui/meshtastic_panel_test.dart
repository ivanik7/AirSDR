// SPDX-License-Identifier: GPL-3.0-or-later
// Meshtastic panel widgets fed by real native fixture events.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/decoders/meshtastic_mode_panel.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';

import 'meshtastic_fixtures.dart';

Future<(MeshRadio, DecoderSession)> _pump(WidgetTester tester, double width) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final radio = MeshRadio(MeshBackend());
  radio.setSampleRate(2048000);
  await radio.start();
  final receiver = CenteredReceiver(radio);
  final session = DecoderSession(radio, receiver: receiver);
  session.selectPreview('meshtastic');
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: session,
            builder: (context, _) =>
                MeshtasticModePanel(session: session, receiver: receiver),
          ),
        ),
      ),
    ),
  );
  return (radio, session);
}

Future<void> _drain(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump();
}

Future<void> _teardown(
  WidgetTester tester,
  MeshRadio radio,
  DecoderSession session,
) async {
  await tester.pumpWidget(const SizedBox());
  session.dispose();
  await radio.stop();
  radio.dispose();
}

void main() {
  for (final width in [344.0, 720.0]) {
    testWidgets('packet log, text and nodes at $width dp', (tester) async {
      final (radio, session) = await _pump(tester, width);
      expect(find.text('Decoding active'), findsOneWidget);
      expect(find.byKey(const ValueKey('meshtasticEmpty')), findsOneWidget);
      for (final e in loadNativeEvents()['default']!) {
        radio.backend.add(e);
      }
      await _drain(tester);
      expect(tester.takeException(), isNull);
      // Newest first: the last fixture event is the first tile.
      final count = loadNativeEvents()['default']!.length;
      expect(find.text('Packets $count'), findsOneWidget);
      final tiles = find.byType(ExpansionTile);
      expect(tiles, findsNWidgets(count));
      expect(
        (tester.widget(tiles.first) as ExpansionTile).key,
        ValueKey('meshtasticPacket-$count'),
      );
      // Real on-air text packet: content, PHY metadata and header.
      expect(find.text('TestingCLU1234'), findsOneWidget);
      expect(
        find.textContaining('869.525 MHz · SF11 · BW 250 kHz · CR 4/5'),
        findsWidgets,
      );
      expect(find.textContaining('id 8caa71b9 · hop 0/3 · ch 0x08'),
          findsOneWidget);
      expect(find.text('22:53:21  !da6354b4 → ALL  TEXT_MESSAGE_APP'),
          findsOneWidget); // native timestamp 1791500001000 ms, UTC
      // Explicit encrypted state.
      expect(find.textContaining('Encrypted · unknown key'), findsOneWidget);
      // Tap opens the full JSON.
      final textTile = find.byKey(const ValueKey('meshtasticPacket-1'));
      await tester.ensureVisible(textTile);
      await tester.tap(textTile);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('meshtasticJson-1')), findsOneWidget);
      // Text messages view.
      await tester.ensureVisible(
          find.byKey(const ValueKey('meshtasticView-messages')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('meshtasticView-messages')));
      await tester.pumpAndSettle();
      expect(find.text('TestingCLU1234'), findsOneWidget);
      expect(find.textContaining('Encrypted'), findsNothing);
      // Node list from NODEINFO/POSITION/TELEMETRY.
      await tester.ensureVisible(
          find.byKey(const ValueKey('meshtasticView-nodes')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('meshtasticView-nodes')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('meshtasticNode-!433c1a2b')),
          findsOneWidget);
      expect(find.textContaining('TST · Test Heltec V3 · !433c1a2b'),
          findsOneWidget);
      expect(find.textContaining('battery 87%'), findsOneWidget);
      expect(find.textContaining('HELTEC_V3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _teardown(tester, radio, session);
    });
  }

  testWidgets('channel key entry is obscured and never displayed',
      (tester) async {
    final (radio, session) = await _pump(tester, 344);
    const secret = 'ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=';
    await tester.tap(find.byKey(const ValueKey('meshtasticAddKey')));
    await tester.pumpAndSettle();
    final psk = find.byKey(const ValueKey('meshtasticKeyPsk'));
    expect(tester.widget<TextField>(psk).obscureText, isTrue);
    await tester.enterText(find.byKey(const ValueKey('meshtasticKeyName')), 'Ops');
    await tester.enterText(psk, 'not*a*key');
    await tester.tap(find.byKey(const ValueKey('meshtasticKeySave')));
    await tester.pumpAndSettle();
    expect(find.text('Key is neither hex nor valid base64'), findsOneWidget);
    await tester.enterText(psk, secret);
    await tester.tap(find.byKey(const ValueKey('meshtasticKeySave')));
    await tester.pumpAndSettle();
    expect(find.text('1. Ops · AES-256'), findsOneWidget);
    expect(find.textContaining(secret), findsNothing);
    final settings = radio.backend.calls.last.$2['settings'] as Map;
    expect(settings['channels'], [
      {'name': 'Ops', 'psk': secret},
    ]);
    // A decrypted packet on that channel shows content, never the key.
    radio.backend.add({
      ...event('aes256', 'aes256_text'),
      'comment': 'echo $secret',
    });
    await _drain(tester);
    expect(find.textContaining(secret), findsNothing);
    // Editing never pre-fills the stored key.
    await tester.tap(find.byKey(const ValueKey('meshtasticEditKey-0')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(psk).controller!.text, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('meshtasticDeleteKey-0')));
    await tester.pump();
    expect(
      (radio.backend.calls.last.$2['settings'] as Map)['channels'],
      isEmpty,
    );
    await _teardown(tester, radio, session);
  });

  testWidgets('preset/region controls retune through the normal VFO path',
      (tester) async {
    final (radio, session) = await _pump(tester, 344);
    await tester.tap(find.byKey(const ValueKey('decoderSetting-meshtastic-region')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('US').last);
    await tester.pumpAndSettle();
    expect(session.settingsFor('meshtastic')['region'], 'US');
    final tune = find.byKey(const ValueKey('meshtasticTune'));
    expect(find.textContaining('Tune US · slot 20 · 906.875 MHz'),
        findsOneWidget);
    await tester.ensureVisible(tune);
    await tester.tap(tune);
    await tester.pump();
    expect(radio.tunedFrequency, 906875000);
    expect(radio.centerFrequency, radio.tunedFrequency);
    expect(radio.vfoOffset, 0);
    // A preset not offered in the region is reported, not tuned.
    session.setSetting('meshtastic', 'preset', 'LiteFast');
    await tester.pump();
    expect(find.byKey(const ValueKey('meshtasticRegionPresetInvalid')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('meshtasticTune')), findsNothing);
    // The selected preset drives the PHY summary and the native config.
    session.setSetting('meshtastic', 'preset', 'MediumFast');
    await tester.pump();
    expect(find.textContaining('MediumFast: BW 250.0 kHz · SF9 · CR 4/5'),
        findsOneWidget);
    expect((radio.backend.calls.last.$2['settings'] as Map)['preset'],
        'MediumFast');
    await _teardown(tester, radio, session);
  });

  testWidgets('KZ_863 quick tune is labeled unverified and recenters at 344 dp',
      (tester) async {
    final (radio, session) = await _pump(tester, 344);
    final kz = find.byKey(const ValueKey('meshtasticTune-KZ_863'));
    expect(find.textContaining('KZ_863 · 866.875 MHz · Unverified frequency'),
        findsOneWidget);
    await tester.ensureVisible(kz);
    await tester.tap(kz);
    await tester.pump();
    expect(radio.tunedFrequency, 866875000);
    expect(radio.centerFrequency, radio.tunedFrequency);
    expect(radio.vfoOffset, 0);
    expect(tester.takeException(), isNull);
    await _teardown(tester, radio, session);
  });
}

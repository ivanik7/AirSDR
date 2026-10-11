// SPDX-License-Identifier: GPL-3.0-or-later
//
// Decoder tab architecture: one panel per selected decoder (RDS/RBDS only
// inside the WFM panel), no RDS row on Receive, Decoder is the second tab.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/rds_widgets.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/decoder_screen.dart';
import 'package:sdr_flutter/ui/legacy/presets_screen.dart';
import 'package:sdr_flutter/ui/legacy/receive_screen.dart';
import 'package:sdr_flutter/ui/legacy/settings_screen.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

/// Backend exposing the RBDS control so the WFM panel shows the real switch.
class _RbdsBackend implements DecoderBackend, RbdsDecoderBackend {
  @override
  bool get rbdsAvailable => true;
  @override
  bool setRbds(bool enabled) => true;
  @override
  Set<String> get availableIds => const {};
  @override
  bool select(String? id, Map<String, Object> versionedConfig) => id == null;
  @override
  DecoderEvent? poll(int afterSequence) => null;
}

class _WfmRadio extends DemoRadioController {
  _WfmRadio() {
    setMode(DemodMode.wfm);
  }
  final _backend = _RbdsBackend();
  @override
  DecoderBackend get decoderBackend => _backend;
}

const _tabLabels = ['Приём', 'Decoder', 'Пресеты', 'Настройки'];

Future<void> _openDecoder(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('tab-1')));
  await tester.pump();
}

Future<void> _select(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const ValueKey('decoderSelector')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(ValueKey('decoderSelect-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('decoderSelect-$id')));
  await tester.pumpAndSettle();
}

void _expectNoRds() {
  expect(find.byType(RdsDetailsPanel), findsNothing);
  expect(find.byKey(const ValueKey('rdsRbds')), findsNothing);
  expect(find.textContaining('RBDS'), findsNothing);
  expect(find.textContaining('RDS'), findsNothing);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final id in ['rtl_433', 'sstv', 'adsb']) {
    testWidgets('$id selected while the radio is in WFM shows only its own '
        'panel, no RDS/RBDS', (tester) async {
      final radio = _WfmRadio();
      await radio.start();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.pump();
      await _openDecoder(tester);
      // Baseline: the WFM decoder panel carries RDS.
      expect(find.byType(RdsDetailsPanel), findsOneWidget);
      await _select(tester, id);
      expect(radio.mode, DemodMode.wfm);
      expect(find.byKey(ValueKey('decoderPanel-$id')), findsOneWidget);
      expect(find.byKey(ValueKey('decoderPanelFor-$id')), findsOneWidget);
      expect(find.byKey(const ValueKey('decoderPanel-voice')), findsNothing);
      _expectNoRds();
      await tester.pumpWidget(const SizedBox());
      await radio.stop();
      radio.dispose();
    });
  }

  testWidgets('NFM panel has no RDS; WFM panel has RDS details and RBDS', (
    tester,
  ) async {
    final radio = _WfmRadio();
    await radio.start();
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.pump();
    await _openDecoder(tester);
    await _select(tester, decoderIdForMode(DemodMode.nfm));
    expect(radio.mode, DemodMode.nfm);
    expect(find.byKey(const ValueKey('decoderPanel-voice')), findsOneWidget);
    _expectNoRds();
    await _select(tester, decoderIdForMode(DemodMode.wfm));
    expect(radio.mode, DemodMode.wfm);
    expect(
      find.byKey(
        ValueKey('decoderPanelFor-${decoderIdForMode(DemodMode.wfm)}'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('decoderPanel-voice')), findsOneWidget);
    expect(find.byType(RdsDetailsPanel), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('rdsRbds')));
    expect(find.text('RBDS (США)'), findsOneWidget);
    for (final mode in [
      DemodMode.am,
      DemodMode.usb,
      DemodMode.lsb,
      DemodMode.dsb,
      DemodMode.cw,
      DemodMode.raw,
    ]) {
      await tester.drag(find.byType(DecoderScreen), const Offset(0, 900));
      await tester.pump();
      await _select(tester, decoderIdForMode(mode));
      expect(radio.mode, mode);
      _expectNoRds();
    }
    await tester.pumpWidget(const SizedBox());
    await radio.stop();
    radio.dispose();
  });

  testWidgets('Receive in WFM with an RDS session has no RDS station row', (
    tester,
  ) async {
    final radio = _WfmRadio();
    await radio.start();
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.pump();
    expect(find.byType(ReceiveScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('rdsStationLine')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ReceiveScreen),
        matching: find.textContaining('RDS'),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
    await radio.stop();
    radio.dispose();
  });

  testWidgets('tabs are Приём, Decoder, Пресеты, Настройки in that order', (
    tester,
  ) async {
    final radio = DemoRadioController();
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.pump();
    for (var i = 0; i < _tabLabels.length; i++) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('tab-$i')),
          matching: find.text(_tabLabels[i]),
        ),
        findsOneWidget,
      );
    }
    expect(find.byKey(const ValueKey('tab-4')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    expect(find.byType(DecoderScreen), findsOneWidget);
    expect(find.byType(ReceiveScreen), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump();
    expect(find.byType(PresetsScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-3')));
    await tester.pump();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-0')));
    await tester.pump();
    expect(find.byType(ReceiveScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });

  testWidgets('applying a preset still returns to Receive', (tester) async {
    final radio = DemoRadioController();
    final favorites = FavoritesRepository();
    await favorites.load();
    favorites.add(
      frequencyHz: 101700000,
      name: 'FM',
      mode: DemodMode.wfm,
      category: 'FM',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump();
    expect(find.byType(PresetsScreen), findsOneWidget);
    final f = favorites.entries.firstWhere((e) => e.name == 'FM');
    await tester.tap(find.byKey(ValueKey('apply-${f.id}')));
    await tester.pump();
    expect(find.byType(ReceiveScreen), findsOneWidget);
    expect(find.byType(PresetsScreen), findsNothing);
    expect(radio.tunedFrequency, 101700000);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });

  testWidgets('openReceive brings the shell back to Receive from Decoder', (
    tester,
  ) async {
    final radio = DemoRadioController();
    final open = ChangeNotifier();
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, openReceive: open),
      ),
    );
    await tester.pump();
    await _openDecoder(tester);
    expect(find.byType(DecoderScreen), findsOneWidget);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    open.notifyListeners();
    await tester.pump();
    expect(find.byType(ReceiveScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    open.dispose();
    radio.dispose();
  });

  for (final tab in [0, 1]) {
    testWidgets('WFM tab $tab fits the 344x690 dp cover screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(344, 690) * 2.625;
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final radio = _WfmRadio();
      await radio.start();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.pump();
      if (tab != 0) {
        await tester.tap(find.byKey(ValueKey('tab-$tab')));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      if (tab == 1) {
        expect(find.byType(DecoderScreen), findsOneWidget);
        await tester.drag(find.byType(DecoderScreen), const Offset(0, -900));
        await tester.pump();
        expect(find.byType(RdsDetailsPanel), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      await radio.stop();
      radio.dispose();
    });
  }
}

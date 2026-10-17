// SPDX-License-Identifier: GPL-3.0-or-later
//
// One decoder selection (DecoderSession.selectedId) shown and chosen
// identically on Receive, Decoder, Presets, channel tiles and bands.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/runtime/background_reception.dart';
import 'package:sdr_flutter/ui/bands/bands.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _FakeBackend implements DecoderBackend {
  @override
  Set<String> get availableIds => const {'rtl_433'};
  @override
  bool select(String? id, Map<String, Object> versionedConfig) => true;
  @override
  DecoderEvent? poll(int afterSequence) => null;
}

class _BackedRadio extends DemoRadioController {
  final _backend = _FakeBackend();
  @override
  DecoderBackend get decoderBackend => _backend;
}

String _textOf(WidgetTester tester, Key key) {
  // Tabs live in an IndexedStack: read offstage tabs too.
  final finder = find.byKey(key, skipOffstage: false);
  final widget = tester.widget(finder);
  if (widget is Text) return widget.data!;
  final texts = find.descendant(
    of: finder,
    matching: find.byType(Text, skipOffstage: false),
    skipOffstage: false,
  );
  return tester.widgetList<Text>(texts).map((t) => t.data ?? '').join(' ');
}

String _receiveChip(WidgetTester tester) =>
    _textOf(tester, const ValueKey('legacyModeStatus'));

String _decoderTab(WidgetTester tester) =>
    _textOf(tester, const ValueKey('decoderSelector'));

Future<void> _selectOnDecoderTab(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const ValueKey('tab-1')));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('decoderSelector')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(ValueKey('decoderSelect-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('decoderSelect-$id')));
  await tester.pumpAndSettle();
}

Future<void> _openReceive(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('tab-0')));
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('rtl_433 chosen on Decoder tab is what Receive shows; back to '
      'WFM shows WFM on both', (tester) async {
    final radio = _BackedRadio();
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.pump();
    expect(_receiveChip(tester), 'WFM');

    await _selectOnDecoderTab(tester, 'rtl_433');
    expect(_decoderTab(tester), contains('rtl_433'));
    await _openReceive(tester);
    expect(_receiveChip(tester), 'rtl_433');
    expect(radio.mode, DemodMode.wfm, reason: 'data decoder keeps the demod');

    await _selectOnDecoderTab(tester, 'demod:1');
    expect(_decoderTab(tester), contains('WFM'));
    await _openReceive(tester);
    expect(_receiveChip(tester), 'WFM');

    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });

  testWidgets('applying a preset carrying rtl_433 shows rtl_433 on Receive, '
      'Decoder and the preset card', (tester) async {
    final radio = _BackedRadio();
    final favorites = FavoritesRepository();
    await favorites.load();
    final f = favorites.add(
      frequencyHz: 433920000,
      name: 'Sensors',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump();
    expect(
      find.text('433.920 MHz · rtl_433'),
      findsOneWidget,
      reason: 'preset card shows its unified decoder, not the raw mode',
    );
    await tester.tap(find.byKey(ValueKey('apply-${f.id}')));
    await tester.pump();
    expect(_receiveChip(tester), 'rtl_433');
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    expect(_decoderTab(tester), contains('rtl_433'));

    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });

  testWidgets('active channel tile shows the selected decoder', (tester) async {
    final radio = _BackedRadio();
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.pump();
    await tester.pump();
    // First run seeds one active channel at the current frequency/mode.
    final tile = find.byKey(const ValueKey('channelSection-activeDecoder'));
    expect(tester.widget<Text>(tile).data, 'WFM');
    await _selectOnDecoderTab(tester, 'rtl_433');
    await _openReceive(tester);
    expect(tester.widget<Text>(tile).data, 'rtl_433');
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });

  testWidgets('restored radio mode is the same on Receive and Decoder', (
    tester,
  ) async {
    final radio = _BackedRadio();
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.pump();
    // Persisted tuning arrives after the shell is built.
    radio.setMode(DemodMode.am);
    await tester.pump();
    expect(_receiveChip(tester), 'AM');
    expect(_decoderTab(tester), contains('AM'));
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });

  testWidgets('compact 344x690: long decoder labels do not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(344, 690);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final radio = _BackedRadio();
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.pump();
    for (final id in ['rtl_433', 'adsb']) {
      await _selectOnDecoderTab(tester, id);
      expect(tester.takeException(), isNull);
      await _openReceive(tester);
      await tester.pump();
      expect(_receiveChip(tester), decoderById(id)!.label);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });

  group('bands use the unified decoder list', () {
    testWidgets('band editor offers every catalog decoder and stores a data '
        'decoder id', (tester) async {
      tester.view.physicalSize = const Size(903, 2315);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final radio = DemoRadioController();
      final bands = BandsRepository();
      await bands.load();
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, bands: bands),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settingsBands')),
        200,
      );
      await tester.tap(find.byKey(const ValueKey('settingsBands')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('band-band-ism433')),
      );
      await tester.tap(find.byKey(const ValueKey('band-band-ism433')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bandMode')));
      await tester.pumpAndSettle();
      for (final d in decoderCatalog) {
        expect(find.byKey(ValueKey('bandDecoder-${d.id}')), findsWidgets);
      }
      await tester.tap(find.byKey(const ValueKey('bandDecoder-rtl_433')).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bandSave')));
      await tester.pumpAndSettle();
      final b = bands.byId('band-ism433')!;
      expect(b.decoderId, 'rtl_433');
      expect(b.mode, DemodMode.am, reason: 'data decoder keeps the band mode');
      expect(find.textContaining('rtl_433 · step'), findsOneWidget);

      await bands.flush();
      final restored = BandsRepository();
      await restored.load();
      expect(restored.byId('band-ism433')!.decoderId, 'rtl_433');
      expect(restored.byId('band-ism433')!.decoderChoice, 'rtl_433');
      expect(restored.byId('band-fm')!.decoderChoice, 'demod:1');
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      bands.dispose();
      restored.dispose();
    });

    test('a voice choice stores only the mode; unknown ids load as none', () {
      final bands = BandsRepository();
      final b = bands.add(
        name: 'X',
        startHz: 300000000,
        endHz: 301000000,
        mode: DemodMode.nfm,
        stepHz: 12500,
        decoderId: 'demod:2',
      );
      expect(b.decoderId, isNull);
      expect(b.mode, DemodMode.am);
      bands.edit(
        b.id,
        name: 'X',
        startHz: 300000000,
        endHz: 301000000,
        mode: DemodMode.am,
        stepHz: 12500,
        decoderId: 'no-such',
      );
      expect(bands.byId(b.id)!.decoderId, isNull);
      bands.dispose();
    });

    test(
      'entering a band with a data decoder selects it in the session',
      () async {
        final radio = _BackedRadio();
        final receiver = CenteredReceiver(radio);
        final bands = BandsRepository();
        receiver.bands = bands;
        final session = DecoderSession(radio, receiver: receiver);
        bands.edit(
          'band-ism433',
          name: 'ISM 433',
          startHz: 433050000,
          endHz: 434790000,
          mode: DemodMode.am,
          stepHz: 25000,
          decoderId: 'rtl_433',
        );
        receiver.tune(433920000);
        expect(session.selectedId, 'rtl_433');
        expect(radio.mode, DemodMode.am);
        // A band without a data decoder behaves as before: its mode applies,
        // a voice selection follows it.
        session.selectPreview('demod:0');
        receiver.tune(100000000);
        expect(radio.mode, DemodMode.wfm);
        expect(session.selectedId, 'demod:1');
        session.dispose();
        receiver.dispose();
        bands.dispose();
        radio.dispose();
      },
    );
  });

  group('background notification', () {
    const channel = MethodChannel('sdr/background');
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    test('shows the selected decoder label, not the raw demod', () async {
      final radio = DemoRadioController();
      final label = ValueNotifier<String?>(null);
      final bridge = BackgroundReception(
        radio,
        channel: channel,
        updateInterval: const Duration(milliseconds: 20),
        decoderLabel: label,
      );
      await radio.start();
      label.value = 'rtl_433';
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls.map((c) => c.method), ['update']);
      expect(calls.single.arguments, {
        'frequency': radio.tunedFrequency.round(),
        'mode': 'rtl_433',
      });
      bridge.dispose();
      await radio.stop();
      radio.dispose();
      label.dispose();
    });

    test(
      'promotion text is corrected when a data decoder is selected',
      () async {
        final radio = DemoRadioController();
        final label = ValueNotifier<String?>('rtl_433');
        final bridge = BackgroundReception(
          radio,
          channel: channel,
          updateInterval: const Duration(milliseconds: 20),
          decoderLabel: label,
        );
        await radio.start(); // native promote() sent radio.mode.label
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(calls.map((c) => c.method), ['update']);
        expect((calls.single.arguments as Map)['mode'], 'rtl_433');
        bridge.dispose();
        await radio.stop();
        radio.dispose();
        label.dispose();
      },
    );

    testWidgets('shell publishes the selected decoder label', (tester) async {
      final radio = _BackedRadio();
      final label = ValueNotifier<String?>(null);
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, decoderLabel: label),
        ),
      );
      await tester.pump();
      expect(label.value, 'WFM');
      await _selectOnDecoderTab(tester, 'rtl_433');
      expect(label.value, 'rtl_433');
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      label.dispose();
    });
  });
}

// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/decoder_screen.dart';
import 'package:sdr_flutter/ui/legacy/receive_screen.dart';
import 'package:sdr_flutter/ui/legacy/settings_screen.dart';
import 'package:sdr_flutter/ui/legacy/squelch_controls.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _DemodRadio extends DemoRadioController {
  final options = <String, Object?>{'stereo': false, 'lowPass': true};
  @override
  Map<String, Object?> get demodOptions =>
      mode == DemodMode.wfm ? options : const <String, Object?>{};
  @override
  void setDemodOption(String key, Object value) {
    options[key] = value;
    notifyListeners();
  }
}

/// Reports a fixed, test-controlled set of decoders as installed; never
/// synthesizes a [DecoderEvent] (decoder_contract.dart forbids fake output
/// from an unsupported/placeholder backend, and this fake backend is a
/// *supported* one for exactly [_available]).
class _FakeBackend implements DecoderBackend {
  _FakeBackend(this._available);
  final Set<String> _available;
  final List<String?> selected = [];
  final List<DecoderEvent> events = [];
  @override
  Set<String> get availableIds => _available;
  @override
  bool select(String? id, Map<String, Object> versionedConfig) {
    selected.add(id);
    return id != null;
  }

  @override
  DecoderEvent? poll(int afterSequence) {
    for (final event in events) {
      if (event.sequence > afterSequence) return event;
    }
    return null;
  }
}

class _BackedRadio extends DemoRadioController {
  _BackedRadio(this._backend);
  final DecoderBackend? _backend;
  @override
  DecoderBackend? get decoderBackend => _backend;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Decoder is the sole demod control surface and retains reception',
    (tester) async {
      final radio = _DemodRadio();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.pump();
      await radio.start();
      final hz = radio.tunedFrequency;
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      expect(find.text('Decoder'), findsNWidgets(2));
      expect(find.byType(SquelchControls), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ReceiveScreen),
          matching: find.byKey(const ValueKey('legacyModeSelect')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(SquelchControls),
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('demod:stereo')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('demod:stereo')));
      await tester.pump();
      expect(radio.options['stereo'], isTrue);
      await tester.drag(
        find.byKey(const ValueKey('decoderBandwidth')),
        const Offset(90, 0),
      );
      await tester.pump();
      expect(radio.bandwidth, isNot(DemodMode.wfm.params.defaultBandwidth));
      await tester.tap(find.byKey(const ValueKey('decoderSelector')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decoderSelect-demod:0')));
      await tester.pump();
      expect(radio.mode, DemodMode.nfm);
      expect(radio.bandwidth, DemodMode.nfm.params.defaultBandwidth);
      await tester.ensureVisible(find.byKey(const ValueKey('squelchType')));
      await tester.pump();
      await tester.tap(find.text('Manual'));
      await tester.pump();
      expect(radio.squelchType, SquelchType.manual);
      await tester.drag(
        find.byKey(const ValueKey('squelchLevelSlider')),
        const Offset(60, 0),
      );
      await tester.pump();
      expect(radio.squelchLevel, isNot(-50));
      await tester.tap(find.text('Auto'));
      await tester.pump();
      expect(radio.squelchType, SquelchType.auto);
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.pump();
      expect(find.byType(DecoderScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('squelchType')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tab-0')));
      await tester.pump();
      expect(find.byKey(const ValueKey('legacyMute')), findsOneWidget);
      expect(radio.tunedFrequency, hz);
      expect(radio.running, isTrue);
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pump();
      expect(find.text('Receiver settings'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      expect(radio.mode, DemodMode.nfm);
      expect(radio.squelchType, SquelchType.auto);
      expect(radio.running, isTrue);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );

  testWidgets('Decoder tab defaults to the voice panel, selector lists '
      'every catalog entry', (tester) async {
    final radio = DemoRadioController();
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    expect(find.byKey(const ValueKey('decoderSelector')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('decoderSelector')));
    await tester.pumpAndSettle();
    for (final d in decoderCatalog) {
      expect(find.byKey(ValueKey('decoderSelect-${d.id}')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('decoderPanel-voice')), findsOneWidget);
    for (final id in ['sstv', 'rtl_433', 'adsb']) {
      expect(find.byKey(ValueKey('decoderResult-$id')), findsNothing);
    }
    expect(find.byType(SquelchControls), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });

  testWidgets('Unavailable SSTV panel shows an honest empty state and disabled '
      'controls, selecting it never touches the radio', (tester) async {
    final radio = DemoRadioController();
    final beforeFreq = radio.tunedFrequency;
    final beforeMode = radio.mode;
    final beforeMuted = radio.muted;
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('decoderSelector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('decoderSelect-sstv')));
    await tester.pump();
    expect(find.byKey(const ValueKey('decoderPanel-sstv')), findsOneWidget);
    expect(find.byKey(const ValueKey('decoderResult-sstv')), findsOneWidget);
    expect(find.byKey(const ValueKey('decoderResult-rtl_433')), findsNothing);
    expect(find.byKey(const ValueKey('decoderResult-adsb')), findsNothing);
    expect(
      find.byKey(const ValueKey('decoderUnavailable-sstv')),
      findsOneWidget,
    );
    expect(find.text('Start'), findsNothing);
    final modeDropdown = tester.widget<DropdownButton<Object>>(
      find.byKey(const ValueKey('decoderSetting-sstv-mode')),
    );
    expect(
      modeDropdown.onChanged,
      isNull,
      reason: 'a setting a native backend never reads must not look live',
    );
    expect(radio.tunedFrequency, beforeFreq);
    expect(radio.mode, beforeMode);
    expect(radio.muted, beforeMuted);
    expect(radio.running, isFalse);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });

  testWidgets(
    'Unavailable rtl_433 panel shows an honest empty log and VFO tuning',
    (tester) async {
      final radio = DemoRadioController();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('decoderSelector')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decoderSelect-rtl_433')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('decoderPanel-rtl_433')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('decoderResult-rtl_433')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('decoderResult-sstv')), findsNothing);
      expect(find.text('Unavailable in the current native build'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('decoderSetting-rtl_433-frequency_hz')),
        findsNothing,
      );
      expect(find.textContaining('VFO'), findsOneWidget);
      expect(radio.running, isFalse, reason: 'selecting never starts anything');
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );

  testWidgets(
    'Unavailable ADS-B panel lists aircraft as empty with no settings to '
    'disable',
    (tester) async {
      final radio = DemoRadioController();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('decoderSelector')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decoderSelect-adsb')));
      await tester.pump();
      expect(find.byKey(const ValueKey('decoderPanel-adsb')), findsOneWidget);
      expect(find.byKey(const ValueKey('decoderResult-adsb')), findsOneWidget);
      expect(find.byKey(const ValueKey('decoderResult-rtl_433')), findsNothing);
      expect(
        find.byKey(const ValueKey('decoderUnavailable-adsb')),
        findsOneWidget,
      );
      // ADS-B uses the current tuned IQ tap, not a second/taken-over tuner.
      expect(find.textContaining('single receiver'), findsNothing);
      expect(find.text('Start'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    },
  );

  testWidgets(
    'a decoder the backend reports as installed enables its settings and '
    'is actually selected on the backend',
    (tester) async {
      final backend = _FakeBackend({'sstv'});
      final radio = _BackedRadio(backend);
      radio.setMode(DemodMode.usb);
      await radio.start();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('decoderSelector')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decoderSelect-sstv')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('decoderUnavailable-sstv')),
        findsNothing,
      );
      final modeDropdown = tester.widget<DropdownButton<Object>>(
        find.byKey(const ValueKey('decoderSetting-sstv-mode')),
      );
      expect(modeDropdown.onChanged, isNotNull);
      expect(backend.selected.last, 'sstv');
      // rtl_433 was never reported available: still gated even after
      // a different decoder became selectable.
      await tester.tap(find.byKey(const ValueKey('decoderSelector')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decoderSelect-rtl_433')));
      await tester.pump();
      expect(backend.selected.last, isNull);
      await tester.pumpWidget(const SizedBox());
      await radio.stop();
      radio.dispose();
    },
  );

  testWidgets('rtl_433 shows real JSON, drops and clear at 344dp', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(344, 690) * 2.625;
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final backend = _FakeBackend({'rtl_433'});
    final radio = _BackedRadio(backend);
    await radio.start();
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('decoderSelector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('decoderSelect-rtl_433')));
    await tester.pump();
    expect(backend.selected.last, 'rtl_433');
    backend.events.add(
      DecoderEvent(
        1,
        1,
        DecoderResult.message,
        Uint8List.fromList(
          utf8.encode('{"model":"Weather","id":17,"temperature_C":21.5}'),
        ),
        droppedEvents: 2,
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('Weather · ID 17 · temperature_C: 21.5'), findsOneWidget);
    expect(find.textContaining('Dropped events: 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rtl433Message-1')));
    await tester.pump();
    expect(find.byKey(const ValueKey('rtl433Json-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('rtl433Clear')));
    await tester.pump();
    expect(find.text('No messages yet'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await radio.stop();
    radio.dispose();
  });

  testWidgets('RAW channel bandwidth is locked and squelch unavailable', (
    tester,
  ) async {
    final radio = DemoRadioController()..setMode(DemodMode.raw);
    await tester.pumpWidget(
      MaterialApp(home: LegacyAppShell(controller: radio)),
    );
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('decoderBandwidth')))
          .onChanged,
      isNull,
    );
    expect(radio.bandwidth, DemodMode.raw.params.defaultBandwidth);
    final squelch = tester.widget<SegmentedButton<SquelchType>>(
      find.byKey(const ValueKey('squelchType')),
    );
    expect(
      squelch.segments.firstWhere((s) => s.value == SquelchType.manual).enabled,
      isFalse,
    );
    expect(
      squelch.segments.firstWhere((s) => s.value == SquelchType.auto).enabled,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
  });

  for (final size in [const Size(344, 690), const Size(690, 344)]) {
    testWidgets('Decoder scrolls without overflow at $size', (tester) async {
      tester.view.physicalSize = size * 2.625;
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final radio = _DemodRadio();
      await tester.pumpWidget(
        MaterialApp(home: LegacyAppShell(controller: radio)),
      );
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      expect(find.byType(DecoderScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(DecoderScreen), const Offset(0, -900));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
    });

    for (final id in ['sstv', 'rtl_433', 'adsb']) {
      testWidgets('Decoder $id panel scrolls without overflow at $size', (
        tester,
      ) async {
        tester.view.physicalSize = size * 2.625;
        tester.view.devicePixelRatio = 2.625;
        addTearDown(tester.view.reset);
        final radio = DemoRadioController();
        await tester.pumpWidget(
          MaterialApp(home: LegacyAppShell(controller: radio)),
        );
        await tester.tap(find.byKey(const ValueKey('tab-1')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('decoderSelector')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(ValueKey('decoderSelect-$id')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('decoderSelect-$id')));
        await tester.pump();
        expect(find.byKey(ValueKey('decoderPanel-$id')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(DecoderScreen), const Offset(0, -900));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        radio.dispose();
      });
    }
  }
}

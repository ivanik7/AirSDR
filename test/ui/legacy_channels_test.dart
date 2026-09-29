import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/channels/channels.dart';
import 'package:sdr_flutter/ui/channels/signal_meter.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';
import 'package:sdr_flutter/ui/sdr_ui_state.dart';

class _Env {
  _Env(this.radio, this.favorites, this.channels);
  final DemoRadioController radio;
  final FavoritesRepository favorites;
  final ChannelsRepository channels;
}

class _RowsRadio extends DemoRadioController {
  final rows = StreamController<FftRow>.broadcast(sync: true);
  @override
  Stream<FftRow> get fftRows => rows.stream;
  @override
  void dispose() {
    rows.close();
    super.dispose();
  }
}

class _ScanRadio extends DemoRadioController {
  AutoSquelchStatus? status;
  @override
  AutoSquelchStatus? get autoSquelchStatus => status;
  @override
  void setTuning({required double centerFrequency, required double vfoOffset}) {
    if (centerFrequency != this.centerFrequency) status = null;
    super.setTuning(centerFrequency: centerFrequency, vfoOffset: vfoOffset);
  }

  void signal(bool open) {
    status = AutoSquelchStatus(
      open: open,
      metricDb: open ? 14 : 0,
      thresholdDb: 6,
    );
    notifyListeners();
  }
}

Future<_Env> _pump(
  WidgetTester tester, {
  Size size = const Size(344, 882),
  void Function(ChannelsRepository)? seed,
  DemoRadioController? radioOverride,
}) async {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = size * 2.625;
  addTearDown(tester.view.reset);
  final radio = radioOverride ?? DemoRadioController();
  final favorites = FavoritesRepository();
  await favorites.load();
  // Presets the channel tests name tiles after (explicit, not defaults).
  favorites.add(
    frequencyHz: 145500000,
    name: 'Симплекс 2м',
    mode: DemodMode.nfm,
    category: 'VHF',
  );
  favorites.add(
    frequencyHz: 433500000,
    name: 'PMR вызов',
    mode: DemodMode.nfm,
    category: 'UHF',
  );
  final channels = ChannelsRepository();
  await channels.load();
  seed?.call(channels);
  await tester.pumpWidget(
    MaterialApp(
      home: LegacyAppShell(
        controller: radio,
        favorites: favorites,
        channels: channels,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return _Env(radio, favorites, channels);
}

Future<void> _dispose(WidgetTester tester, _Env env) async {
  await tester.pumpWidget(const SizedBox());
  env.radio.dispose();
  env.favorites.dispose();
  env.channels.dispose();
}

Future<void> _showChannels(WidgetTester tester) async {
  expect(find.byKey(const ValueKey('channelsSection')), findsOneWidget);
  await tester.pumpAndSettle(); // let the scroll come to rest
}

void _seed3(ChannelsRepository c) {
  c.add(frequencyHz: 101200000, mode: DemodMode.wfm, name: 'FM радио');
  c.add(frequencyHz: 118100000, mode: DemodMode.am, name: 'Вышка');
  c.add(frequencyHz: 145500000, mode: DemodMode.nfm, name: '2м');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'selected display stays on selected slot while another tile receives',
    (tester) async {
      final radio = _ScanRadio();
      final env = await _pump(
        tester,
        radioOverride: radio,
        seed: (c) {
          c.add(frequencyHz: 145500000, mode: DemodMode.nfm, name: 'Выбранный');
          c.add(frequencyHz: 433500000, mode: DemodMode.nfm, name: 'Другой');
          c.activate(c.channels.first.id);
        },
      );
      await radio.start();
      await _showChannels(tester);
      await tester.tap(find.byKey(const ValueKey('channelScanToggle')));
      await tester.pump();
      radio.signal(false);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 220)),
      );
      await tester.pump(const Duration(milliseconds: 25));
      expect(radio.tunedFrequency, 433500000);
      radio.signal(true);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 220)),
      );
      await tester.pump(const Duration(milliseconds: 25));
      expect(find.text('Приём: PMR вызов'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('legacyFrequency'))).data,
        '145.500',
      );
      expect(env.channels.activeId, env.channels.channels.first.id);
      final receiving = find.byKey(
        ValueKey('channel-${env.channels.channels[1].id}'),
      );
      expect(
        find.descendant(
          of: receiving,
          matching: find.byKey(const ValueKey('channelLed')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _dispose(tester, env);
    },
  );

  testWidgets(
    'scan control needs two supported channels; 344dp and selected frequency stays fixed',
    (tester) async {
      final env = await _pump(
        tester,
        seed: (c) {
          c.add(frequencyHz: 145500000, mode: DemodMode.nfm, name: 'Выбранный');
          c.add(frequencyHz: 433500000, mode: DemodMode.nfm, name: 'Другой');
          c.activate(c.channels.first.id);
        },
      );
      await _showChannels(tester);
      final toggle = find.byKey(const ValueKey('channelScanToggle'));
      expect(
        tester.widget<TextButton>(toggle).onPressed,
        isNull,
        reason: 'receiver not running',
      );
      await env.radio.start();
      await tester.pump();
      expect(tester.widget<TextButton>(toggle).onPressed, isNotNull);
      await tester.tap(toggle);
      await tester.pump();
      expect(find.text('Стоп скан'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('legacyFrequency'))).data,
        '145.500',
      );
      expect(tester.takeException(), isNull);
      await tester.tap(toggle);
      await tester.pump();
      expect(find.text('Скан'), findsOneWidget);
      await _dispose(tester, env);
    },
  );

  test('FFT rows from other channels and retune transition never enter selected waterfall', () async {
    final radio = _RowsRadio();
    final ui = SdrUiState(radio, centerDisplayOnVfo: true);
    radio.setTuning(centerFrequency: 145500000, vfoOffset: 0);
    await radio.start();
    ui.holdDisplayAt(145500000);
    radio.setTuning(centerFrequency: 433500000, vfoOffset: 0);
    radio.rows.add(
      FftRow(
        db: Float32List.fromList(List.filled(8, -40)),
        lowFreq: 432300000,
        highFreq: 434700000,
      ),
    );
    expect(ui.waterfall.lines, 0);
    expect(ui.displayViewport.centerFreq, 145500000);
    radio.setTuning(centerFrequency: 145500000, vfoOffset: 0);
    radio.rows.add(
      FftRow(
        db: Float32List.fromList(List.filled(8, -30)),
        lowFreq: 144300000,
        highFreq: 146700000,
      ),
    );
    expect(ui.waterfall.lines, 0, reason: 'retune buffer discarded');
    await Future<void>.delayed(const Duration(milliseconds: 210));
    radio.rows.add(
      FftRow(
        db: Float32List.fromList(List.filled(8, -60)),
        lowFreq: 144300000,
        highFreq: 146700000,
      ),
    );
    expect(ui.waterfall.lines, 1);
    radio.rows.add(
      FftRow(
        db: Float32List.fromList(List.filled(8, -30)),
        lowFreq: 432300000,
        highFreq: 434700000,
      ),
    );
    expect(ui.waterfall.lines, 1);
    ui.dispose();
    radio.dispose();
  });

  testWidgets('first launch seeds one active channel from the receiver', (
    tester,
  ) async {
    final env = await _pump(tester);
    expect(env.channels.length, 1);
    expect(env.channels.active!.frequencyHz, env.radio.tunedFrequency.round());
    await _showChannels(tester);
    expect(find.text('КАНАЛЫ · 1'), findsOneWidget);
    expect(find.textContaining('активно'), findsNothing);
    expect(find.textContaining('позже'), findsNothing);
    await _dispose(tester, env);
  });

  testWidgets('restored active channel drives the receiver; tap switches', (
    tester,
  ) async {
    final env = await _pump(
      tester,
      seed: (c) {
        _seed3(c);
        c.activate(c.channels[1].id);
      },
    );
    expect(env.radio.tunedFrequency, 118100000);
    expect(env.radio.mode, DemodMode.am);
    await _showChannels(tester);
    final fm = env.channels.channels[0];
    await tester.tap(find.byKey(ValueKey('channel-${fm.id}')));
    await tester.pump();
    expect(env.channels.activeId, fm.id);
    expect(env.radio.tunedFrequency, 101200000);
    expect(env.radio.centerFrequency, 101200000);
    expect(env.radio.vfoOffset, 0);
    expect(env.radio.mode, DemodMode.wfm);
    // Mode chip changes only the active channel.
    await tester.tap(find.byKey(const ValueKey('legacyModeSelect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('legacyMode-NFM')));
    await tester.pump();
    expect(env.channels.channels[0].mode, DemodMode.nfm);
    expect(env.channels.channels[1].mode, DemodMode.am);
    expect(env.channels.channels[2].mode, DemodMode.nfm);
    expect(env.channels.channels[2].frequencyHz, 145500000);
    await _dispose(tester, env);
  });

  testWidgets('+ канал adds the current frequency and makes it active', (
    tester,
  ) async {
    final env = await _pump(tester, seed: _seed3);
    await _showChannels(tester);
    expect(find.text('КАНАЛЫ · 3'), findsOneWidget);
    env.radio.setTuning(centerFrequency: 433500000, vfoOffset: 0);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('channelAdd')));
    await tester.pump();
    expect(env.channels.length, 4);
    expect(env.channels.active!.frequencyHz, 433500000);
    expect(env.channels.active!.name, 'PMR вызов');
    expect(find.text('КАНАЛЫ · 4'), findsOneWidget);
    await _dispose(tester, env);
  });

  testWidgets('long press without moving opens the menu; delete confirms', (
    tester,
  ) async {
    final env = await _pump(tester, seed: _seed3);
    await _showChannels(tester);
    final air = env.channels.channels[1];
    final third = env.channels.channels[2];
    // air is not active (the last added one is), make it active by tap.
    await tester.tap(find.byKey(ValueKey('channel-${air.id}')));
    await tester.pump();
    await tester.longPress(find.byKey(ValueKey('channel-${air.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Переименовать'), findsNothing);
    expect(find.text('Сохранить как пресет'), findsOneWidget);
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    expect(find.text('Удалить канал?'), findsOneWidget);
    expect(env.channels.length, 3, reason: 'not before confirmation');
    await tester.tap(find.byKey(const ValueKey('channelDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(env.channels.length, 2);
    expect(env.channels.activeId, third.id, reason: 'neighbour takes over');
    expect(env.radio.tunedFrequency, 145500000);
    expect(env.radio.mode, DemodMode.nfm);
    await _dispose(tester, env);
  });

  testWidgets('menu has no rename; save as preset asks for a name', (
    tester,
  ) async {
    final env = await _pump(tester, seed: _seed3);
    await _showChannels(tester);
    final c = env.channels.channels[2];
    final tile = find.byKey(ValueKey('channel-${c.id}'));
    // 145.500 is the built-in "Симплекс 2м": the tile shows the preset name.
    expect(
      find.descendant(of: tile, matching: find.text('Симплекс 2м')),
      findsOneWidget,
    );
    await tester.longPress(tile);
    await tester.pumpAndSettle();
    expect(find.text('Переименовать'), findsNothing);
    expect(find.byKey(const ValueKey('channelMenu-rename')), findsNothing);
    expect(find.text('Сохранить как пресет'), findsOneWidget);
    expect(find.text('Удалить'), findsOneWidget);
    await tester.tap(find.text('Сохранить как пресет'));
    await tester.pumpAndSettle();
    // Duplicate frequency: readable reason, as before.
    await tester.tap(find.byKey(const ValueKey('presetNameSave')));
    await tester.pumpAndSettle();
    expect(find.textContaining('уже есть'), findsOneWidget);

    // A free frequency (no preset): auto name, then the dialog.
    env.radio.setTuning(centerFrequency: 99912500, vfoOffset: 0);
    await tester.pump();
    expect(env.channels.channels[2].frequencyHz, 99912500);
    expect(
      find.descendant(of: tile, matching: find.text('NFM 99.9125')),
      findsOneWidget,
    );
    final before = env.favorites.entries.length;
    await tester.longPress(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить как пресет'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('presetName'));
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          )
          .controller
          .text,
      'NFM 99.9125',
      reason: 'prefilled with channel name',
    );
    // Empty name: validation error, dialog stays, nothing saved.
    await tester.enterText(field, '   ');
    await tester.tap(find.byKey(const ValueKey('presetNameSave')));
    await tester.pumpAndSettle();
    expect(find.text('введите название'), findsOneWidget);
    expect(field, findsOneWidget);
    expect(env.favorites.entries.length, before);
    // Cancel changes nothing.
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    expect(env.favorites.entries.length, before);
    // Save under the typed name; the channel now shows the preset name.
    await tester.longPress(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить как пресет'));
    await tester.pumpAndSettle();
    await tester.enterText(field, 'Ретранс');
    await tester.tap(find.byKey(const ValueKey('presetNameSave')));
    await tester.pumpAndSettle();
    final saved = env.favorites.entries.last;
    expect(env.favorites.entries.length, before + 1);
    expect(saved.name, 'Ретранс');
    expect(saved.frequencyHz, 99912500);
    expect(saved.mode, DemodMode.nfm);
    expect(find.text('Сохранено как пресет'), findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.text('Ретранс')),
      findsOneWidget,
    );
    await _dispose(tester, env);
  });

  testWidgets('tile name follows keypad retune and preset deletion', (
    tester,
  ) async {
    final env = await _pump(tester, seed: _seed3);
    await _showChannels(tester);
    final c = env.channels.active!;
    final tile = find.byKey(ValueKey('channel-${c.id}'));
    expect(
      find.descendant(of: tile, matching: find.text('Симплекс 2м')),
      findsOneWidget,
    );
    for (final k in ['1', '4', '5', '.', '6', 'OK']) {
      await tester.tap(find.byKey(ValueKey('key-$k')));
      await tester.pump();
    }
    expect(env.channels.active!.frequencyHz, 145600000);
    expect(
      find.descendant(of: tile, matching: find.text('NFM 145.600')),
      findsOneWidget,
    );
    final p = env.favorites.add(
      frequencyHz: 145600000,
      name: 'Новый пресет',
      mode: DemodMode.nfm,
      category: 'VHF',
    );
    await tester.pump();
    expect(
      find.descendant(of: tile, matching: find.text('Новый пресет')),
      findsOneWidget,
    );
    env.favorites.delete(p.id);
    await tester.pump();
    expect(
      find.descendant(of: tile, matching: find.text('NFM 145.600')),
      findsOneWidget,
    );
    await _dispose(tester, env);
  });

  testWidgets('long press + drag reorders; active stays active; persisted', (
    tester,
  ) async {
    final env = await _pump(tester, seed: _seed3);
    await _showChannels(tester);
    final [a, b, c] = env.channels.channels;
    expect(env.channels.activeId, c.id);
    final from = tester.getCenter(find.byKey(ValueKey('channel-${c.id}')));
    // a may be partly scrolled out on the left: aim at its visible part.
    final aRect = tester.getRect(find.byKey(ValueKey('channel-${a.id}')));
    final to = Offset(aRect.right - 20, aRect.center.dy);
    final gesture = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(from + const Offset(0, -10));
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Сохранить как пресет'), findsNothing, reason: 'no menu');
    expect(env.channels.channels.map((e) => e.id), [c.id, a.id, b.id]);
    expect(env.channels.activeId, c.id);
    expect(env.radio.tunedFrequency, 145500000);
    await env.channels.flush();
    final reopened = ChannelsRepository();
    await reopened.load();
    expect(reopened.channels.map((e) => e.id), [c.id, a.id, b.id]);
    expect(reopened.activeId, c.id);
    reopened.dispose();
    await _dispose(tester, env);
  });

  testWidgets('level/LED only on the active tile', (tester) async {
    final env = await _pump(tester, seed: _seed3);
    await _showChannels(tester);
    expect(find.byKey(const ValueKey('channelLevel')), findsOneWidget);
    expect(find.byKey(const ValueKey('channelLed')), findsOneWidget);
    final active = find.byKey(ValueKey('channel-${env.channels.activeId}'));
    expect(
      find.descendant(
        of: active,
        matching: find.byKey(const ValueKey('channelLevel')),
      ),
      findsOneWidget,
    );
    await _dispose(tester, env);
  });

  void seedMany(ChannelsRepository c, int n) {
    for (var i = 0; i < n; i++) {
      c.add(
        frequencyHz: 1766000000 - i * 1000,
        mode: DemodMode.values[i % DemodMode.values.length],
        name: 'Очень длинное название канала номер $i для проверки',
      );
    }
  }

  Finder tileOf(String id) => find.byKey(ValueKey('channel-$id'));
  Rect rowRect(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('channelsRow')));
  bool fullyVisible(WidgetTester tester, String id) {
    final f = tileOf(id);
    if (f.evaluate().isEmpty) return false;
    final r = tester.getRect(f);
    final row = rowRect(tester);
    return r.left >= row.left - 0.5 && r.right <= row.right + 0.5;
  }

  testWidgets('channels block is aligned with the spectrum panel', (
    tester,
  ) async {
    final env = await _pump(tester, seed: _seed3);
    await _showChannels(tester);
    final panel = tester.getRect(
      find.byKey(const ValueKey('legacySpectrumDrag')),
    );
    final header = tester.getRect(find.byKey(const ValueKey('channelsHeader')));
    final row = rowRect(tester);
    final scan = tester.getRect(
      find.byKey(const ValueKey('channelScanToggle')),
    );
    expect(header.left, closeTo(panel.left, 0.5));
    expect(row.left, closeTo(panel.left, 0.5));
    expect(row.right, closeTo(panel.right, 0.5));
    expect(scan.right, closeTo(panel.right, 0.5), reason: 'no gap at the end');
    await _dispose(tester, env);
  });

  for (final n in [5, 12]) {
    testWidgets('$n channels: one horizontal row, + канал always there', (
      tester,
    ) async {
      final env = await _pump(tester, seed: (c) => seedMany(c, n));
      await _showChannels(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('КАНАЛЫ · $n'), findsOneWidget);
      expect(find.byKey(const ValueKey('channelsExpand')), findsNothing);
      expect(find.textContaining('Все каналы'), findsNothing);
      final scrollables = find.descendant(
        of: find.byKey(const ValueKey('channelsSection')),
        matching: find.byType(Scrollable),
      );
      expect(scrollables, findsOneWidget);
      expect(
        tester.widget<Scrollable>(scrollables).axisDirection,
        AxisDirection.right,
      );
      // All tiles are in one row.
      final firstTop = tester.getRect(tileOf(env.channels.activeId!)).top;
      for (final c in env.channels.channels) {
        if (tileOf(c.id).evaluate().isNotEmpty) {
          expect(tester.getRect(tileOf(c.id)).top, firstTop);
        }
      }
      // The (last-added) active channel was scrolled into view.
      expect(fullyVisible(tester, env.channels.activeId!), isTrue);
      final add = find.byKey(const ValueKey('channelAdd'));
      expect(add.hitTestable(), findsOneWidget);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(env.channels.length, n + 1);
      expect(find.text('КАНАЛЫ · ${n + 1}'), findsOneWidget);
      expect(fullyVisible(tester, env.channels.activeId!), isTrue);
      // Horizontal fling reveals the first channel again.
      final first = env.channels.channels.first.id;
      await tester.drag(scrollables, const Offset(4000, 0));
      await tester.pumpAndSettle();
      expect(fullyVisible(tester, first), isTrue);
      expect(tester.takeException(), isNull);
      await _dispose(tester, env);
    });
  }

  testWidgets('channels block height does not depend on the channel count', (
    tester,
  ) async {
    final heights = <double>[];
    for (final n in [0, 1, 5, 12]) {
      SharedPreferences.setMockInitialValues({});
      final env = await _pump(
        tester,
        seed: (c) {
          seedMany(c, n);
          // Keep "no channels" really empty (first run would seed one).
          if (n == 0) c.add(frequencyHz: 100000000, mode: DemodMode.wfm);
        },
      );
      if (n == 0) {
        env.channels.delete(env.channels.channels.single.id);
        await tester.pump();
        expect(env.channels.length, 0);
      }
      heights.add(
        tester.getRect(find.byKey(const ValueKey('channelsSection'))).height,
      );
      expect(tester.takeException(), isNull);
      await _dispose(tester, env);
    }
    expect(heights.toSet().length, 1, reason: '$heights');
  });

  testWidgets('active channel off-screen is scrolled into view on switch', (
    tester,
  ) async {
    final env = await _pump(tester, seed: (c) => seedMany(c, 12));
    await _showChannels(tester);
    final first = env.channels.channels.first.id;
    final last = env.channels.channels.last.id;
    expect(fullyVisible(tester, last), isTrue);
    expect(fullyVisible(tester, first), isFalse);
    env.channels.activate(first); // e.g. restored / switched elsewhere
    await tester.pumpAndSettle();
    expect(fullyVisible(tester, first), isTrue);
    await _dispose(tester, env);
  });

  testWidgets('scan: the channel being tuned is scrolled into view', (
    tester,
  ) async {
    final radio = _ScanRadio();
    final env = await _pump(
      tester,
      radioOverride: radio,
      seed: (c) {
        for (var i = 0; i < 10; i++) {
          c.add(
            frequencyHz: 433050000 + i * 25000,
            mode: DemodMode.nfm,
            name: 'К$i',
          );
        }
        c.activate(c.channels.first.id);
      },
    );
    await radio.start();
    await _showChannels(tester);
    final ids = env.channels.channels.map((c) => c.id).toList();
    expect(fullyVisible(tester, ids.first), isTrue);
    await tester.tap(find.byKey(const ValueKey('channelScanToggle')));
    await tester.pump();
    // Walk the scanner through closed channels until it reaches far ones.
    for (var i = 0; i < 12; i++) {
      radio.signal(false);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 220)),
      );
      await tester.pump(const Duration(milliseconds: 25));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      final tunedIndex = ids.indexOf(
        env.channels.channels
            .firstWhere((c) => c.frequencyHz == radio.tunedFrequency.round())
            .id,
      );
      expect(fullyVisible(tester, ids[tunedIndex]), isTrue, reason: 'step $i');
    }
    await tester.tap(find.byKey(const ValueKey('channelScanToggle')));
    await tester.pumpAndSettle();
    await _dispose(tester, env);
  });

  testWidgets('reorder in the row with auto-scroll at the edge', (
    tester,
  ) async {
    final env = await _pump(
      tester,
      seed: (c) {
        seedMany(c, 10);
        c.activate(c.channels.first.id);
      },
    );
    await _showChannels(tester);
    final ids = env.channels.channels.map((c) => c.id).toList();
    final lastId = ids.last;
    expect(fullyVisible(tester, ids.first), isTrue);
    expect(fullyVisible(tester, lastId), isFalse, reason: 'far off-screen');
    final from = tester.getCenter(tileOf(ids.first));
    final row = rowRect(tester);
    final gesture = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(from + const Offset(20, 0));
    await tester.pump();
    // Hold at the right edge: the row scrolls by itself.
    await gesture.moveTo(Offset(row.right - 4, from.dy));
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(fullyVisible(tester, lastId), isTrue, reason: 'auto-scrolled');
    await gesture.moveTo(tester.getCenter(tileOf(lastId)));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Сохранить как пресет'), findsNothing, reason: 'no menu');
    expect(env.channels.channels.last.id, ids.first);
    expect(env.channels.activeId, ids.first);
    expect(tester.takeException(), isNull);
    await _dispose(tester, env);
  });

  test('vfoSignalInfo: SDR++ max-in-band minus side-band mean', () {
    // 100 bins over 0..100 Hz; noise -100 dB, carrier -40 dB at 50 Hz.
    final db = Float32List(100)..fillRange(0, 100, -100);
    db[50] = -40;
    final info = vfoSignalInfo(db, 0, 100, 50, 10)!;
    expect(info.strengthDb, -40);
    expect(info.snrDb, closeTo(60, 1e-9));
    expect(vfoSignalInfo(Float32List(0), 0, 100, 50, 10), isNull);
    // Passband off the row: no reading.
    expect(vfoSignalInfo(db, 0, 100, 500, 10), isNull);
  });

  test('signal meter clears the old channel reading on retune', () async {
    final radio = _RowsRadio();
    final meter = SignalMeter(radio);
    radio.setMode(DemodMode.nfm);
    await radio.start();
    final center = radio.centerFrequency;
    final db = Float32List(100)..fillRange(0, 100, -100);
    db[50] = -40;
    radio.rows.add(
      FftRow(db: db, lowFreq: center - 50000, highFreq: center + 50000),
    );
    expect(meter.value, isNotNull);
    radio.setTuning(centerFrequency: center + 1000000, vfoOffset: 0);
    expect(
      meter.value,
      isNull,
      reason: 'old level must not appear on a new channel',
    );
    meter.dispose();
    await radio.stop();
    radio.dispose();
  });
}

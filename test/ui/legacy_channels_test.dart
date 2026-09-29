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
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('channelsSection')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
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
      expect(find.text('Приём: Другой'), findsOneWidget);
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
    await tester.ensureVisible(find.byKey(const ValueKey('legacyMode-NFM')));
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
    expect(find.text('Переименовать'), findsOneWidget);
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

  testWidgets('menu: rename and save as preset', (tester) async {
    final env = await _pump(tester, seed: _seed3);
    await _showChannels(tester);
    final c = env.channels.channels[2];
    await tester.longPress(find.byKey(ValueKey('channel-${c.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Переименовать'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('channelName')),
      'Ретранс',
    );
    await tester.tap(find.byKey(const ValueKey('channelNameSave')));
    await tester.pumpAndSettle();
    expect(env.channels.channels[2].name, 'Ретранс');

    await tester.longPress(find.byKey(ValueKey('channel-${c.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить как пресет'));
    await tester.pumpAndSettle();
    // 145.500 is the built-in "Симплекс 2м": a readable duplicate reason.
    expect(find.textContaining('уже есть'), findsOneWidget);
    // A free frequency is saved under the channel's name.
    env.radio.setTuning(centerFrequency: 99912500, vfoOffset: 0);
    await tester.pump();
    expect(env.channels.channels[2].frequencyHz, 99912500);
    await tester.longPress(find.byKey(ValueKey('channel-${c.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить как пресет'));
    await tester.pumpAndSettle();
    final saved = env.favorites.entries.last;
    expect(saved.name, 'Ретранс');
    expect(saved.frequencyHz, 99912500);
    expect(saved.mode, DemodMode.nfm);
    expect(find.text('Сохранено как пресет'), findsOneWidget);
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
    final to = tester.getCenter(find.byKey(ValueKey('channel-${a.id}')));
    final gesture = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(from + const Offset(0, -10));
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Переименовать'), findsNothing, reason: 'no menu');
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

  testWidgets('many channels collapse to 4 tiles and expand; 344 dp OK', (
    tester,
  ) async {
    final env = await _pump(
      tester,
      seed: (c) {
        for (var i = 0; i < 7; i++) {
          c.add(
            frequencyHz: 1766000000 - i * 1000,
            mode: DemodMode.values[i % DemodMode.values.length],
            name: 'Очень длинное название канала номер $i для проверки',
          );
        }
      },
    );
    await _showChannels(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('КАНАЛЫ · 7'), findsOneWidget);
    expect(find.byKey(const ValueKey('channelAdd')), findsNothing);
    expect(
      find.byKey(ValueKey('channel-${env.channels.activeId}')),
      findsOneWidget,
      reason: 'the active receiver must remain visible while collapsed',
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('channel-ch-'),
      ),
      findsNWidgets(4),
    );
    await tester.tap(find.byKey(const ValueKey('channelsExpand')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Свернуть ▲'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('channelAdd')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
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

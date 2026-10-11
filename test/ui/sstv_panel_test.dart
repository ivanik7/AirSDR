// SPDX-License-Identifier: GPL-3.0-or-later
//
// SSTV panel: live picture and status from real native image events,
// gallery, enlarge + save, underlying demod control, honest forced-mode note.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/decoders/sstv_image.dart';
import 'package:sdr_flutter/ui/decoders/sstv_panel.dart';
import 'package:sdr_flutter/ui/decoders/sstv_save.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _FakeBackend implements DecoderBackend {
  final List<DecoderEvent> events = [];
  int _sequence = 0;
  @override
  Set<String> get availableIds => {'sstv'};
  @override
  bool select(String? id, Map<String, Object> versionedConfig) {
    events.clear();
    return id != null;
  }

  @override
  DecoderEvent? poll(int afterSequence) {
    for (final event in events) {
      if (event.sequence > afterSequence) return event;
    }
    return null;
  }

  void push(DecoderResult kind, Map<String, Object?> json) => events.add(
    DecoderEvent(
      ++_sequence,
      1,
      kind,
      Uint8List.fromList(utf8.encode(jsonEncode(json))),
    ),
  );
}

class _BackedRadio extends DemoRadioController {
  _BackedRadio(this._backend);
  final DecoderBackend _backend;
  @override
  DecoderBackend? get decoderBackend => _backend;
}

class _FakeSaver implements SstvImageSaver {
  final List<SstvFrame> saved = [];
  @override
  bool get supported => true;
  @override
  Future<String> save(SstvFrame frame) async {
    saved.add(frame);
    return '/Pictures/AirSDR/${frame.fileStem}.png';
  }
}

void _frame(_FakeBackend b, int hz, {required int lines, bool end = true}) {
  final meta = {
    'source': 'sstv',
    'version': 1,
    'frame_id': '1',
    'vis': 0,
    'sstv_mode': 'Robot 12',
    'width': 160,
    'height': 120,
    'timestamp_utc': '2026-10-11T10:00:00.000Z',
    'frequency_hz': hz,
    'underlying': 'usb',
  };
  b.push(DecoderResult.imageProgress, {
    ...meta,
    'phase': 'start',
    'line': null,
    'pixels_bgr_base64': null,
    'padded': null,
  });
  for (var i = 0; i < lines; i++) {
    b.push(DecoderResult.imageProgress, {
      ...meta,
      'phase': 'line',
      'line': i,
      'pixels_bgr_base64': base64Encode(Uint8List(480)..fillRange(0, 480, i)),
      'padded': false,
    });
  }
  if (end) {
    b.push(DecoderResult.imageComplete, {
      ...meta,
      'received_lines': lines,
      'padded_lines': 0,
      'status': lines == 120 ? 'complete' : 'partial',
      'reason': lines == 120 ? 'end' : 'sync_lost',
    });
  }
}

void main() {
  late _FakeBackend backend;
  late _BackedRadio radio;
  late DecoderSession session;
  late _FakeSaver saver;

  Future<void> mount(
    WidgetTester tester, {
    DemodMode mode = DemodMode.usb,
  }) async {
    tester.view.physicalSize = const Size(344, 690) * 2.625;
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    backend = _FakeBackend();
    radio = _BackedRadio(backend)..setMode(mode);
    await radio.start();
    session = DecoderSession(radio)..selectPreview('sstv');
    saver = _FakeSaver();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: session,
            builder: (_, _) => SingleChildScrollView(
              child: SstvDecoderPanel(session: session, saver: saver),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await radio.stop();
    radio.dispose();
  }

  testWidgets('waiting state, live partial frame, then a gallery picture', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('Ожидание VIS-заголовка…'), findsOneWidget);
    expect(find.text('Изображение не получено'), findsOneWidget);
    expect(find.textContaining('Галерея сеанса · 0/'), findsOneWidget);

    final hz = radio.tunedFrequency.round();
    _frame(backend, hz, lines: 40, end: false);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Приём кадра Robot 12'), findsOneWidget);
    expect(find.byKey(const ValueKey('sstvLive')), findsOneWidget);
    expect(find.textContaining('строк 40/120'), findsOneWidget);
    expect(find.textContaining('приём ·'), findsOneWidget);

    for (var i = 40; i < 120; i++) {
      backend.push(DecoderResult.imageProgress, {
        'source': 'sstv',
        'version': 1,
        'frame_id': '1',
        'vis': 0,
        'sstv_mode': 'Robot 12',
        'width': 160,
        'height': 120,
        'timestamp_utc': '2026-10-11T10:00:00.000Z',
        'frequency_hz': hz,
        'underlying': 'usb',
        'phase': 'line',
        'line': i,
        'pixels_bgr_base64': base64Encode(Uint8List(480)),
        'padded': false,
      });
    }
    backend.push(DecoderResult.imageComplete, {
      'source': 'sstv',
      'version': 1,
      'frame_id': '1',
      'vis': 0,
      'sstv_mode': 'Robot 12',
      'width': 160,
      'height': 120,
      'timestamp_utc': '2026-10-11T10:00:00.000Z',
      'frequency_hz': hz,
      'underlying': 'usb',
      'received_lines': 120,
      'padded_lines': 0,
      'status': 'complete',
      'reason': 'end',
    });
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Ожидание VIS-заголовка…'), findsOneWidget);
    expect(find.textContaining('строк 120/120 · полный'), findsOneWidget);
    expect(find.byKey(const ValueKey('sstvThumb-1')), findsOneWidget);
    expect(find.textContaining('Галерея сеанса · 1/'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('tap enlarges a picture and Save stores it with the '
      'OpenWebRX+ name; partial pictures are labelled', (tester) async {
    await mount(tester);
    _frame(backend, radio.tunedFrequency.round(), lines: 30);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Robot 12 · частично'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('sstvThumb-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sstvThumb-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sstvDialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('sstvEnlarged')), findsOneWidget);
    expect(find.textContaining('сохраняются только принятые'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('sstvSave')));
    await tester.tap(find.byKey(const ValueKey('sstvSave')));
    await tester.pumpAndSettle();
    expect(saver.saved.single.receivedLines, 30);
    expect(
      find.text(
        'Сохранено: /Pictures/AirSDR/SSTV-261011-100000-'
        '${radio.tunedFrequency.round() ~/ 1000}-partial.png',
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Закрыть'));
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('sstvClear')));
    await tester.tap(find.byKey(const ValueKey('sstvClear')));
    await tester.pump();
    expect(session.sstv.gallery, isEmpty);
    expect(find.byKey(const ValueKey('sstvThumb-1')), findsNothing);
    await unmount(tester);
  });

  testWidgets('in WFM the panel says what is needed and the demod buttons '
      'switch the receiver; forced picture modes are honestly absent', (
    tester,
  ) async {
    await mount(tester, mode: DemodMode.wfm);
    expect(find.textContaining('Не готов: нужен режим'), findsOneWidget);
    expect(radio.mode, DemodMode.wfm);
    final mode = tester.widget<DropdownButton<Object>>(
      find.byKey(const ValueKey('decoderSetting-sstv-mode')),
    );
    expect(mode.items!.map((i) => i.value), ['auto']);
    expect(find.byKey(const ValueKey('sstvForcedModeNote')), findsOneWidget);
    await tester.ensureVisible(find.text('LSB'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LSB'));
    await tester.pump();
    expect(radio.mode, DemodMode.lsb);
    expect(session.active, isTrue);
    expect(find.text('Ожидание VIS-заголовка…'), findsOneWidget);
    await unmount(tester);
  });
}

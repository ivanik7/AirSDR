// SPDX-License-Identifier: GPL-3.0-or-later
//
// DecoderSession routing of real SSTV FIFO events, underlying-demod choice,
// retune/mode/stop handling and gallery lifetime.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/decoders/sstv_image.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _FakeBackend implements DecoderBackend {
  _FakeBackend(this._available);
  final Set<String> _available;
  final List<(String?, Map<String, Object>)> selectCalls = [];
  final List<DecoderEvent> events = [];
  int dropped = 0;
  int generation = 1;
  int _sequence = 0;
  @override
  Set<String> get availableIds => _available;

  /// Like sdr_decoder_select: the FIFO is invalidated, sequence continues.
  @override
  bool select(String? id, Map<String, Object> versionedConfig) {
    selectCalls.add((id, Map<String, Object>.from(versionedConfig)));
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

  void push(DecoderResult kind, Map<String, Object?> json) {
    events.add(
      DecoderEvent(
        ++_sequence,
        generation,
        kind,
        Uint8List.fromList(utf8.encode(jsonEncode(json))),
        droppedEvents: dropped,
      ),
    );
  }
}

class _BackedRadio extends DemoRadioController {
  _BackedRadio(this._backend);
  final DecoderBackend? _backend;
  @override
  DecoderBackend? get decoderBackend => _backend;
}

Map<String, Object?> _meta(int freq, {String frameId = '1'}) => {
  'source': 'sstv',
  'version': 1,
  'frame_id': frameId,
  'vis': 0,
  'sstv_mode': 'Robot 12',
  'width': 160,
  'height': 120,
  'timestamp_utc': '2026-10-11T10:00:00.000Z',
  'frequency_hz': freq,
  'underlying': 'usb',
};

void _start(_FakeBackend b, int freq, {String frameId = '1'}) =>
    b.push(DecoderResult.imageProgress, {
      ..._meta(freq, frameId: frameId),
      'phase': 'start',
      'line': null,
      'pixels_bgr_base64': null,
      'padded': null,
    });

void _line(_FakeBackend b, int freq, int line, {String frameId = '1'}) =>
    b.push(DecoderResult.imageProgress, {
      ..._meta(freq, frameId: frameId),
      'phase': 'line',
      'line': line,
      'pixels_bgr_base64': base64Encode(Uint8List(480)),
      'padded': false,
    });

void _complete(_FakeBackend b, int freq, int lines) =>
    b.push(DecoderResult.imageComplete, {
      ..._meta(freq),
      'received_lines': lines,
      'padded_lines': 0,
      'status': lines == 120 ? 'complete' : 'partial',
      'reason': lines == 120 ? 'end' : 'sync_lost',
    });

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 130));

Future<(_FakeBackend, _BackedRadio, DecoderSession)> _running({
  DemodMode mode = DemodMode.usb,
}) async {
  final backend = _FakeBackend({'sstv', 'rtl_433'});
  final radio = _BackedRadio(backend)..setMode(mode);
  await radio.start();
  final session = DecoderSession(radio);
  session.selectPreview('sstv');
  return (backend, radio, session);
}

void main() {
  test(
    'SSTV selection sends mode auto plus the running underlying demod',
    () async {
      final (backend, radio, session) = await _running(mode: DemodMode.lsb);
      expect(backend.selectCalls.last.$1, 'sstv');
      expect(backend.selectCalls.last.$2, {
        'version': 1,
        'settings': {'mode': 'auto', 'underlying': 'lsb'},
      });
      expect(session.active, isTrue);
      session.dispose();
      await radio.stop();
      radio.dispose();
    },
  );

  test('previewing SSTV in an incompatible mode never changes the mode and '
      'reports not ready', () async {
    final (backend, radio, session) = await _running(mode: DemodMode.wfm);
    expect(radio.mode, DemodMode.wfm);
    expect(backend.selectCalls.last.$1, isNull);
    expect(session.active, isFalse);
    expect(session.failureReason, contains('USB'));
    session.dispose();
    await radio.stop();
    radio.dispose();
  });

  test('choosing an underlying demod goes through the normal mode control '
      'and reattaches with it', () async {
    final (backend, radio, session) = await _running(mode: DemodMode.wfm);
    session.setSetting('sstv', 'underlying', 'nfm');
    expect(radio.mode, DemodMode.nfm);
    expect(backend.selectCalls.last.$1, 'sstv');
    expect(
      (backend.selectCalls.last.$2['settings']! as Map)['underlying'],
      'nfm',
    );
    expect(session.active, isTrue);
    session.dispose();
    await radio.stop();
    radio.dispose();
  });

  test('stale forced modes normalize to auto', () {
    final radio = DemoRadioController();
    final session = DecoderSession(radio);
    session.applyStored('sstv', {'mode': 'martin_m1', 'underlying': 'lsb'});
    expect(session.currentSettings, {'mode': 'auto', 'underlying': 'lsb'});
    session.dispose();
    radio.dispose();
  });

  test('real image events build the live frame and a gallery picture; '
      'messages and rtl_433 never absorb them', () async {
    final (backend, radio, session) = await _running();
    final hz = radio.tunedFrequency.round();
    _start(backend, hz);
    for (var i = 0; i < 60; i++) {
      _line(backend, hz, i);
    }
    await _tick();
    expect(session.sstv.current!.mode, 'Robot 12');
    expect(session.sstv.current!.receivedLines, 60);
    expect(session.messages, isEmpty);
    for (var i = 60; i < 120; i++) {
      _line(backend, hz, i);
    }
    _complete(backend, hz, 120);
    await _tick();
    expect(session.sstv.current, isNull);
    expect(session.sstv.gallery.single.status, SstvFrameStatus.complete);
    session.dispose();
    await radio.stop();
    radio.dispose();
  });

  test('retune mid-frame keeps received rows as partial and rejects late '
      'rows of the old frequency', () async {
    final (backend, radio, session) = await _running();
    final hz = radio.tunedFrequency.round();
    _start(backend, hz);
    _line(backend, hz, 0);
    await _tick();
    radio.setTuning(
      centerFrequency: radio.centerFrequency + 10000,
      vfoOffset: 0,
    );
    expect(session.sstv.current, isNull);
    expect(session.sstv.gallery.single.reason, 'retune');
    // A late start stamped with the old frequency is stale.
    _start(backend, hz, frameId: '2');
    await _tick();
    expect(session.sstv.current, isNull);
    session.dispose();
    await radio.stop();
    radio.dispose();
  });

  test('mode change and stop close the frame with their reason', () async {
    final (backend, radio, session) = await _running();
    final hz = radio.tunedFrequency.round();
    _start(backend, hz);
    _line(backend, hz, 0);
    await _tick();
    radio.setMode(DemodMode.lsb);
    expect(session.sstv.gallery.first.reason, 'mode');
    expect(session.settingsFor('sstv')['underlying'], 'lsb');
    expect(session.active, isTrue);
    _start(backend, hz, frameId: '2');
    _line(backend, hz, 0, frameId: '2');
    await _tick();
    await radio.stop();
    expect(session.sstv.gallery.first.reason, 'stop');
    expect(session.sstv.gallery, hasLength(2));
    session.dispose();
    radio.dispose();
  });

  test('FIFO overflow during a frame closes it as lost', () async {
    final (backend, radio, session) = await _running();
    final hz = radio.tunedFrequency.round();
    _start(backend, hz);
    _line(backend, hz, 0);
    await _tick();
    backend.dropped = 3;
    _line(backend, hz, 1);
    await _tick();
    expect(session.sstv.gallery.single.reason, 'lost');
    expect(session.sstv.gallery.single.receivedLines, 1);
    session.dispose();
    await radio.stop();
    radio.dispose();
  });

  test(
    'deselect moves the open frame to the gallery; dispose frees all',
    () async {
      final (backend, radio, session) = await _running();
      final hz = radio.tunedFrequency.round();
      _start(backend, hz);
      _line(backend, hz, 0);
      await _tick();
      session.selectPreview(decoderIdForMode(DemodMode.usb));
      expect(session.sstv.current, isNull);
      expect(session.sstv.gallery.single.reason, 'deselect');
      final sstv = session.sstv;
      session.dispose();
      expect(sstv.gallery, isEmpty);
      await radio.stop();
      radio.dispose();
    },
  );
}

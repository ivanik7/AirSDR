// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/decoders/rds_station.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _Backend implements DecoderBackend, RbdsDecoderBackend {
  final events = <DecoderEvent>[];
  final rbdsCalls = <bool>[];
  @override
  bool get rbdsAvailable => true;
  @override
  bool setRbds(bool enabled) {
    rbdsCalls.add(enabled);
    return true;
  }

  @override
  Set<String> get availableIds => {'rtl_433'};
  @override
  bool select(String? id, Map<String, Object> config) => true;
  @override
  DecoderEvent? poll(int afterSequence) {
    for (final e in events) {
      if (e.sequence > afterSequence) return e;
    }
    return null;
  }

  void add(int seq, int generation, Map<String, Object?> payload) => events.add(
    DecoderEvent(
      seq,
      generation,
      DecoderResult.message,
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    ),
  );
}

class _Radio extends DemoRadioController {
  _Radio(this.backend);
  final _Backend backend;
  @override
  DecoderBackend get decoderBackend => backend;
}

Map<String, Object?> _event(
  String type,
  int hz, {
  Map<String, Object?> fields = const {},
}) => {
  'source': 'rds',
  'version': 1,
  'event': type,
  'frequency_hz': hz,
  'rbds': false,
  if (type == 'state') ...{'fields': fields, 'sync': true},
};

void main() {
  test('RDS merges partial fields, clears on PI change and reset', () {
    final station = RdsStation();
    expect(
      station.apply({
        'source': 'rds',
        'version': 1,
        'event': 'state',
        'fields': {'pi': '6201', 'ps': 'FIRST'},
        'sync': true,
      }),
      isTrue,
    );
    station.apply({
      'source': 'rds',
      'version': 1,
      'event': 'state',
      'fields': {'radiotext': 'Hello'},
    });
    expect(station.fields, containsPair('ps', 'FIRST'));
    expect(station.text('radiotext'), 'Hello');
    station.apply({
      'source': 'rds',
      'version': 1,
      'event': 'state',
      'fields': {'pi': '6202', 'prog_type': 'News'},
    });
    expect(station.text('ps'), isNull);
    expect(station.text('radiotext'), isNull);
    station.apply({
      'source': 'rds',
      'version': 1,
      'event': 'reset',
      'reason': 'retune',
    });
    expect(station.fields, isEmpty);
    expect(station.synced, isFalse);
  });

  test('WFM implicitly polls with audio selected; clears stale events on tune, mode, generation and stop', () async {
    final backend = _Backend();
    final radio = _Radio(backend);
    final session = DecoderSession(radio);
    await radio.start();
    final hz = radio.tunedFrequency.round();
    backend.add(
      1,
      1,
      _event('state', hz, fields: {'pi': '6201', 'ps': 'FIRST'}),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(session.rds.text('ps'), 'FIRST');
    expect(session.messages, isEmpty, reason: 'RDS is not a data-decoder log');
    radio.setTuning(centerFrequency: hz + 100000, vfoOffset: 0);
    expect(session.rds.fields, isEmpty);
    backend.add(2, 1, _event('state', hz, fields: {'ps': 'OLD'}));
    backend.add(3, 1, _event('state', hz + 100000, fields: {'ps': 'NEW'}));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(session.rds.text('ps'), 'NEW');
    backend.add(4, 2, _event('reset', hz + 100000));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(session.rds.fields, isEmpty);
    radio.setMode(DemodMode.am);
    expect(session.rds.fields, isEmpty);
    radio.setMode(DemodMode.wfm);
    backend.add(5, 2, _event('state', hz + 100000, fields: {'ps': 'BACK'}));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(session.rds.text('ps'), 'BACK');
    backend.add(6, 2, _event('reset', hz));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(session.rds.text('ps'), 'BACK', reason: 'old-frequency reset ignored');
    backend.add(7, 2, _event('reset', hz + 100000));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(session.rds.fields, isEmpty);
    await radio.stop();
    expect(session.rds.fields, isEmpty);
    session.dispose();
    radio.dispose();
  });

  test(
    'RBDS is a WFM preset setting, applies without selecting or retuning',
    () async {
      final backend = _Backend();
      final radio = _Radio(backend);
      final session = DecoderSession(radio);
      final wfm = decoderIdForMode(DemodMode.wfm);
      expect(session.settingsFor(wfm)['rbds'], false);
      await radio.start();
      final freq = radio.tunedFrequency;
      session.setSetting(wfm, 'rbds', true);
      expect(backend.rbdsCalls.last, true);
      expect(session.settingsFor(wfm)['rbds'], true);
      expect(radio.tunedFrequency, freq);
      expect(radio.running, true);
      session.applyStored(wfm, {'rbds': false});
      expect(backend.rbdsCalls.last, false);
      session.dispose();
      await radio.stop();
      radio.dispose();
    },
  );
}

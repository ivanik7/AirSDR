// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';

class _Backend implements DecoderBackend {
  final calls = <(String?, Map<String, Object>)>[];
  final events = <DecoderEvent>[];
  @override
  Set<String> get availableIds => {'dmr'};
  @override
  bool select(String? id, Map<String, Object> config) {
    calls.add((id, config));
    return true;
  }

  @override
  DecoderEvent? poll(int afterSequence) {
    for (final event in events) {
      if (event.sequence > afterSequence) return event;
    }
    return null;
  }

  void add(int sequence, int generation, Map<String, Object?> data) {
    events.add(
      DecoderEvent(
        sequence,
        generation,
        DecoderResult.message,
        Uint8List.fromList(utf8.encode(jsonEncode(data))),
      ),
    );
  }
}

class _Radio extends DemoRadioController {
  _Radio(this.backend);
  final _Backend backend;
  @override
  DecoderBackend get decoderBackend => backend;
}

void main() {
  test(
    'DMR selection and filters propagate without changing radio mode',
    () async {
      final backend = _Backend();
      final radio = _Radio(backend);
      final mode = radio.mode;
      await radio.start();
      final session = DecoderSession(radio);
      session.selectPreview('dmr');
      expect(radio.mode, mode);
      expect(backend.calls.last, (
        'dmr',
        <String, Object>{
          'schema': 'dmr/1',
          'slot_filter': 3,
          'color_code': -1,
          'voice': true,
        },
      ));
      session.setSetting('dmr', 'slot_filter', 2);
      session.setSetting('dmr', 'color_code', 7);
      expect(backend.calls.last.$2['slot_filter'], 2);
      expect(backend.calls.last.$2['color_code'], 7);
      final previous = backend.calls.length;
      session.setSetting('dmr', 'color_code', 16);
      expect(backend.calls.length, previous);
      session.applyStored('dmr', {
        'slot_filter': 1,
        'color_code': -1,
        'voice': false,
      });
      expect(backend.calls.last.$2['voice'], false);
      session.dispose();
      await radio.stop();
      radio.dispose();
    },
  );

  test('DMR events update both slots, close calls, bound history and clear on retune', () async {
    final backend = _Backend();
    final radio = _Radio(backend);
    await radio.start();
    final session = DecoderSession(radio);
    session.selectPreview('dmr');
    backend.add(1, 1, {
      'schema': 'dmr/1',
      'protocol': 'DMR',
      'slot': 0,
      'sync': 'voice',
      'type': 'group',
      'source': 123,
      'target': 91,
      'privacy': true,
      'color_code': 4,
    });
    backend.add(2, 1, {
      'schema': 'dmr/1',
      'protocol': 'DMR',
      'slot': 1,
      'sync': 'voice',
      'type': 'direct',
      'source': 456,
      'target': 789,
      'talkeralias': 'CALL',
    });
    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(session.dmrSlots[0]?.source, 123);
    expect(session.dmrSlots[1]?.source, 456);
    expect(session.dmrSlots[0]?.privacy, true);
    backend.add(3, 1, {'schema': 'dmr/1', 'protocol': 'DMR', 'slot': 0});
    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(session.dmrSlots[0], isNull);
    expect(session.dmrHistory.first.source, 123);
    for (var i = 4; i < 120; i++) {
      backend.add(i, 1, {
        'schema': 'dmr/1',
        'protocol': 'DMR',
        'slot': 0,
        'sync': 'voice',
        'source': i,
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(session.dmrHistory.length, lessThanOrEqualTo(100));
    radio.setTuning(centerFrequency: 433920000, vfoOffset: 0);
    expect(session.dmrSlots, [null, null]);
    expect(session.dmrHistory, isEmpty);
    backend.add(120, 2, {
      'schema': 'dmr/1',
      'protocol': 'DMR',
      'slot': 1,
      'sync': 'data',
    });
    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(session.dmrSync[1], 'data');
    session.dispose();
    await radio.stop();
    radio.dispose();
  });

  test('silent DMR voice expires without a native reset event', () async {
    final backend = _Backend();
    final radio = _Radio(backend);
    await radio.start();
    final session = DecoderSession(
      radio,
      dmrCallTimeout: const Duration(milliseconds: 200),
    );
    session.selectPreview('dmr');
    backend.add(1, 1, {
      'schema': 'dmr/1',
      'protocol': 'DMR',
      'slot': 0,
      'sync': 'voice',
      'source': 42,
    });
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(session.dmrSlots[0]?.source, 42);
    await Future<void>.delayed(const Duration(milliseconds: 320));
    expect(session.dmrSlots[0], isNull);
    expect(session.dmrSync[0], isNull);
    session.dispose();
    await radio.stop();
    radio.dispose();
  });
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// DecoderSession: real v3 mode choices and conservative data previews.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

/// Records every `select` call and reports a fixed, test-controlled set of
/// available ids — never pretends an id is available unless told to.
class _FakeBackend implements DecoderBackend {
  _FakeBackend(this._available);
  final Set<String> _available;
  final List<(String?, Map<String, Object>)> selectCalls = [];
  final List<DecoderEvent> events = [];
  final List<int> pollCalls = [];
  bool reject = false;
  @override
  Set<String> get availableIds => _available;
  @override
  bool select(String? id, Map<String, Object> versionedConfig) {
    selectCalls.add((id, Map<String, Object>.from(versionedConfig)));
    return id != null && !reject;
  }

  @override
  DecoderEvent? poll(int afterSequence) {
    pollCalls.add(afterSequence);
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
  test('default session selects the current v3 mode with no backend wired', () {
    final radio = DemoRadioController();
    final session = DecoderSession(radio);
    expect(session.selectedId, decoderIdForMode(radio.mode));
    expect(session.availableIds, {
      for (final m in DemodMode.values) decoderIdForMode(m),
    });
    expect(session.isAvailable('sstv'), isFalse);
    expect(session.isAvailable('rtl_433'), isFalse);
    expect(session.isAvailable('adsb'), isFalse);
    radio.dispose();
  });

  test(
    'availableIds includes all v3 modes and mirrors the data backend only',
    () {
      final backend = _FakeBackend({'sstv'});
      final radio = _BackedRadio(backend);
      final session = DecoderSession(radio);
      expect(session.availableIds, {
        for (final m in DemodMode.values) decoderIdForMode(m),
        'sstv',
      });
      expect(session.isAvailable('sstv'), isTrue);
      expect(session.isAvailable('rtl_433'), isFalse, reason: 'not reported');
      radio.dispose();
    },
  );

  test('selecting an unavailable decoder previews it but never starts the '
      'backend', () {
    final backend = _FakeBackend(const {});
    final radio = _BackedRadio(backend);
    final session = DecoderSession(radio);
    session.selectPreview('rtl_433');
    expect(session.selectedId, 'rtl_433', reason: 'preview still switches');
    expect(backend.selectCalls, hasLength(1));
    expect(backend.selectCalls.single.$1, isNull);
    expect(
      backend.selectCalls.single.$2,
      isEmpty,
      reason: 'an unavailable id is never handed to the backend as a start',
    );
    radio.dispose();
  });

  test(
    'rtl_433 attaches to a running receiver with empty versioned settings',
    () async {
      final backend = _FakeBackend({'rtl_433'});
      final radio = _BackedRadio(backend);
      await radio.start();
      final session = DecoderSession(radio);
      session.selectPreview('rtl_433');
      expect(session.selectedId, 'rtl_433');
      expect(backend.selectCalls, hasLength(1));
      expect(backend.selectCalls.single.$1, 'rtl_433');
      expect(backend.selectCalls.single.$2, {
        'version': 1,
        'settings': <String, Object>{},
      });
      await radio.stop();
      radio.dispose();
    },
  );

  test(
    'native rejection reports reason and never polls a false session',
    () async {
      final backend = _FakeBackend({'rtl_433'})..reject = true;
      final radio = _BackedRadio(backend);
      await radio.start();
      final session = DecoderSession(radio);
      session.selectPreview('rtl_433');
      expect(session.active, isFalse);
      expect(session.failureReason, isNotNull);
      expect(backend.selectCalls.first.$1, 'rtl_433');
      expect(backend.selectCalls.last.$1, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(backend.pollCalls, isEmpty);
      session.dispose();
      await radio.stop();
      radio.dispose();
    },
  );

  test('compatible running audio decoder gets versioned settings', () async {
    final backend = _FakeBackend({'sstv'});
    final radio = _BackedRadio(backend);
    radio.setMode(DemodMode.usb);
    await radio.start();
    final session = DecoderSession(radio);
    session.selectPreview('sstv');
    expect(backend.selectCalls.last.$1, 'sstv');
    expect(backend.selectCalls.last.$2, {
      'version': 1,
      'settings': {'mode': 'auto', 'underlying': 'usb'},
    });
    await radio.stop();
    radio.dispose();
  });

  test('switching back to voice tells the backend to stop any decoder', () {
    final backend = _FakeBackend({'rtl_433'});
    final radio = _BackedRadio(backend);
    final session = DecoderSession(radio);
    session.selectPreview('rtl_433');
    session.selectPreview(decoderIdForMode(DemodMode.wfm));
    expect(session.selectedId, decoderIdForMode(DemodMode.wfm));
    expect(backend.selectCalls.last.$1, isNull);
    expect(backend.selectCalls.last.$2, isEmpty);
    radio.dispose();
  });

  test('previewing a data decoder never changes radio tuning/mode or mutes/'
      'starts it', () {
    final radio = DemoRadioController();
    final beforeFreq = radio.tunedFrequency;
    final beforeMode = radio.mode;
    final beforeMuted = radio.muted;
    final beforeRunning = radio.running;
    final session = DecoderSession(radio);
    for (final id in ['sstv', 'rtl_433', 'adsb']) {
      session.selectPreview(id);
    }
    expect(radio.tunedFrequency, beforeFreq);
    expect(radio.mode, beforeMode);
    expect(radio.muted, beforeMuted);
    expect(radio.running, beforeRunning);
    radio.dispose();
  });

  test('rtl_433 has no decoder-specific settings; tuning is the radio VFO', () {
    final backend = _FakeBackend({'rtl_433'});
    final radio = _BackedRadio(backend);
    final session = DecoderSession(radio);
    session.selectPreview('rtl_433');
    session.setSetting('rtl_433', 'frequency_hz', 915000000);
    expect(session.currentSettings, isEmpty);
    // Disallowed value: ignored, keeps the previous one.
    session.setSetting('rtl_433', 'frequency_hz', 999);
    expect(session.currentSettings, isEmpty);
    // Unknown key: ignored entirely.
    session.setSetting('rtl_433', 'nonsense', 1);
    expect(session.currentSettings.containsKey('nonsense'), isFalse);
    radio.dispose();
  });

  test('setSetting on an unavailable decoder does not start the backend', () {
    final backend = _FakeBackend(const {});
    final radio = _BackedRadio(backend);
    final session = DecoderSession(radio);
    session.selectPreview('rtl_433');
    backend.selectCalls.clear();
    session.setSetting('rtl_433', 'frequency_hz', 868000000);
    expect(session.currentSettings, isEmpty);
    expect(
      backend.selectCalls,
      isEmpty,
      reason: 'never asked the backend to (re)start an unavailable decoder',
    );
    radio.dispose();
  });

  test('settingsFor resolves defaults for an untouched decoder', () {
    final radio = DemoRadioController();
    final session = DecoderSession(radio);
    expect(session.settingsFor('sstv'), {'mode': 'auto', 'underlying': 'usb'});
    expect(session.settingsFor('adsb'), isEmpty);
    expect(session.settingsFor('unknown-id'), isEmpty);
    radio.dispose();
  });

  test('applyStored restores a preset/channel decoder selection and '
      'normalizes an unknown id to voice', () {
    final backend = _FakeBackend({'sstv'});
    final radio = _BackedRadio(backend);
    final session = DecoderSession(radio);
    session.applyStored('sstv', {'mode': 'auto', 'underlying': 'lsb'});
    expect(session.selectedId, 'sstv');
    expect(session.currentSettings['underlying'], 'lsb');
    expect(backend.selectCalls.last.$1, isNull, reason: 'no running USB demod');

    session.applyStored('no-such-decoder', {'x': 1});
    expect(session.selectedId, decoderIdForMode(radio.mode));
    expect(backend.selectCalls.last.$1, isNull);
    expect(backend.selectCalls.last.$2, isEmpty);
    radio.dispose();
  });

  test('applyStored never starts a decoder unavailable in this backend', () {
    final backend = _FakeBackend(const {});
    final radio = _BackedRadio(backend);
    final session = DecoderSession(radio);
    session.applyStored('rtl_433', {'frequency_hz': 868000000});
    expect(session.selectedId, 'rtl_433', reason: 'preview still switches');
    expect(backend.selectCalls.last.$1, isNull);
    expect(backend.selectCalls.last.$2, isEmpty);
    radio.dispose();
  });

  test(
    'rtl_433 drains FIFO, tracks drops, bounds log, and reselects on restart',
    () async {
      final backend = _FakeBackend({'rtl_433'});
      final radio = _BackedRadio(backend);
      final session = DecoderSession(radio);
      session.selectPreview('rtl_433');
      expect(backend.selectCalls.last.$1, isNull);
      await radio.start();
      expect(backend.selectCalls.last.$1, 'rtl_433');
      for (var i = 1; i <= 510; i++) {
        backend.events.add(
          DecoderEvent(
            i,
            1,
            DecoderResult.message,
            Uint8List.fromList(utf8.encode('{"model":"Sensor","id":$i}')),
            droppedEvents: 4,
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(session.messages, hasLength(500));
      expect(session.messages.first.sequence, 510);
      expect(session.messages.last.sequence, 11);
      expect(session.droppedEvents, 4);
      expect(backend.pollCalls, contains(0));
      session.clearMessages();
      expect(session.messages, isEmpty);
      await radio.stop();
      final count = backend.pollCalls.length;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(backend.pollCalls.length, count);
      await radio.start();
      expect(backend.selectCalls.last.$1, 'rtl_433');
      session.selectPreview(decoderIdForMode(radio.mode));
      expect(backend.selectCalls.last.$1, isNull);
      session.dispose();
      radio.dispose();
    },
  );

  test(
    'retuning clears rtl_433 log; an invalid rate detaches until restored',
    () async {
      final backend = _FakeBackend({'rtl_433'});
      final radio = _BackedRadio(backend);
      final session = DecoderSession(radio);
      await radio.start();
      session.selectPreview('rtl_433');
      expect(session.active, isTrue);
      backend.events.add(
        DecoderEvent(
          1,
          1,
          DecoderResult.message,
          Uint8List.fromList(utf8.encode('{"model":"Weather"}')),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(session.messages, hasLength(1));
      radio.setTuning(centerFrequency: 433920000, vfoOffset: 0);
      expect(session.messages, isEmpty);
      expect(session.active, isTrue);
      radio.setSampleRate(192000);
      expect(session.active, isFalse);
      expect(session.failureReason, contains('200 кГц'));
      expect(backend.selectCalls.last.$1, isNull);
      radio.setSampleRate(2400000);
      expect(session.active, isTrue);
      expect(session.decoderRateHz, 240000);
      expect(backend.selectCalls.last.$1, 'rtl_433');
      session.dispose();
      await radio.stop();
      radio.dispose();
    },
  );
}

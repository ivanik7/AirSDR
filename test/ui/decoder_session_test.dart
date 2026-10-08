// SPDX-License-Identifier: GPL-3.0-or-later
//
// DecoderSession: preview/settings selection, backend availability gating,
// and the conservative "never touch the radio" invariants.
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
  @override
  Set<String> get availableIds => _available;
  @override
  bool select(String? id, Map<String, Object> versionedConfig) {
    selectCalls.add((id, Map<String, Object>.from(versionedConfig)));
    return id != null;
  }

  @override
  DecoderEvent? poll(int afterSequence) => null;
}

class _BackedRadio extends DemoRadioController {
  _BackedRadio(this._backend);
  final DecoderBackend? _backend;
  @override
  DecoderBackend? get decoderBackend => _backend;
}

void main() {
  test('default session previews voice with no backend wired', () {
    final radio = DemoRadioController();
    final session = DecoderSession(radio);
    expect(session.selectedId, DecoderSession.voiceId);
    expect(session.availableIds, {DecoderSession.voiceId});
    expect(session.isAvailable('sstv'), isFalse);
    expect(session.isAvailable('rtl_433'), isFalse);
    expect(session.isAvailable('adsb'), isFalse);
    radio.dispose();
  });

  test(
    'availableIds always includes voice and mirrors the real backend only',
    () {
      final backend = _FakeBackend({'sstv'});
      final radio = _BackedRadio(backend);
      final session = DecoderSession(radio);
      expect(session.availableIds, {DecoderSession.voiceId, 'sstv'});
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

  test('exclusive decoder preview cannot claim a running receiver', () async {
    final backend = _FakeBackend({'rtl_433'});
    final radio = _BackedRadio(backend);
    await radio.start();
    final session = DecoderSession(radio);
    session.selectPreview('rtl_433');
    expect(session.selectedId, 'rtl_433');
    expect(backend.selectCalls, hasLength(1));
    expect(backend.selectCalls.single.$1, isNull);
    await radio.stop();
    radio.dispose();
  });

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
      'settings': {'mode': 'auto'},
    });
    await radio.stop();
    radio.dispose();
  });

  test('switching back to voice tells the backend to stop any decoder', () {
    final backend = _FakeBackend({'rtl_433'});
    final radio = _BackedRadio(backend);
    final session = DecoderSession(radio);
    session.selectPreview('rtl_433');
    session.selectPreview(DecoderSession.voiceId);
    expect(session.selectedId, DecoderSession.voiceId);
    expect(backend.selectCalls.last.$1, isNull);
    expect(backend.selectCalls.last.$2, isEmpty);
    radio.dispose();
  });

  test('previewing a decoder never changes radio tuning/mode or mutes/'
      'starts it', () {
    final radio = DemoRadioController();
    final beforeFreq = radio.tunedFrequency;
    final beforeMode = radio.mode;
    final beforeMuted = radio.muted;
    final beforeRunning = radio.running;
    final session = DecoderSession(radio);
    for (final id in ['sstv', 'rtl_433', 'adsb', DecoderSession.voiceId]) {
      session.selectPreview(id);
    }
    expect(radio.tunedFrequency, beforeFreq);
    expect(radio.mode, beforeMode);
    expect(radio.muted, beforeMuted);
    expect(radio.running, beforeRunning);
    radio.dispose();
  });

  test('setSetting ignores unknown keys and disallowed values', () {
    final backend = _FakeBackend({'rtl_433'});
    final radio = _BackedRadio(backend);
    final session = DecoderSession(radio);
    session.selectPreview('rtl_433');
    session.setSetting('rtl_433', 'frequency_hz', 915000000);
    expect(session.currentSettings['frequency_hz'], 915000000);
    // Disallowed value: ignored, keeps the previous one.
    session.setSetting('rtl_433', 'frequency_hz', 999);
    expect(session.currentSettings['frequency_hz'], 915000000);
    // Unknown key: ignored entirely.
    session.setSetting('rtl_433', 'nonsense', 1);
    expect(session.currentSettings.containsKey('nonsense'), isFalse);
    radio.dispose();
  });

  test('setSetting on an unavailable decoder updates local state only', () {
    final backend = _FakeBackend(const {});
    final radio = _BackedRadio(backend);
    final session = DecoderSession(radio);
    session.selectPreview('rtl_433');
    backend.selectCalls.clear();
    session.setSetting('rtl_433', 'frequency_hz', 868000000);
    expect(session.currentSettings['frequency_hz'], 868000000);
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
    expect(session.settingsFor('sstv'), {'mode': 'auto'});
    expect(session.settingsFor('adsb'), isEmpty);
    expect(session.settingsFor('unknown-id'), isEmpty);
    radio.dispose();
  });

  test('applyStored restores a preset/channel decoder selection and '
      'normalizes an unknown id to voice', () {
    final backend = _FakeBackend({'sstv'});
    final radio = _BackedRadio(backend);
    final session = DecoderSession(radio);
    session.applyStored('sstv', {'mode': 'martin_m1'});
    expect(session.selectedId, 'sstv');
    expect(session.currentSettings['mode'], 'martin_m1');
    expect(backend.selectCalls.last.$1, isNull, reason: 'no running USB demod');

    session.applyStored('no-such-decoder', {'x': 1});
    expect(session.selectedId, DecoderSession.voiceId);
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
}

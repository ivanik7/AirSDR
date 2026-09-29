// SPDX-License-Identifier: GPL-3.0-or-later
// Mute / audio-device lifecycle of the DSP engine (task t_3cfa7a1d):
//  * every cold start is muted, even if the previous session saved `muted: false`;
//  * mute releases the Android playback device, unmute while running reopens it;
//  * losing the source (fatal error) or a failing source stop never leaves audio open.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/audio_output.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/runtime/dsp_protocol.dart';
import 'package:sdr_flutter/runtime/source_registry.dart';
import 'package:sdr_flutter/sdrpp/signal_path/source_handler.dart';

import 'fake_usb_source.dart';

class _RecordingAudio extends AudioOutput {
  int opens = 0;
  int closes = 0;
  bool active = false;

  @override
  String get name => 'recording';

  @override
  bool open(int sampleRate) {
    opens++;
    active = true;
    return true;
  }

  @override
  bool write(Float32List data, int frames) => active;

  @override
  void close() {
    closes++;
    active = false;
  }
}

/// A source whose stop() throws (e.g. an ioctl on a vanished device).
class _ThrowingStop implements SourceHandler {
  _ThrowingStop(this.core);
  final SourceCore core;
  @override
  void select() => core.setInputSampleRate(250000);
  @override
  void deselect() {}
  @override
  Future<void> start(SourceSink sink) async {}
  @override
  Future<void> stop() async => throw StateError('stop failed: no device');
  @override
  void tune(double frequencyHz) {}
  @override
  List<SourceSetting> get settings => const <SourceSetting>[];
  @override
  void applySetting(String id, Object value) {}
}

Future<void> _cmd(DspEngine e, Map<String, Object?> m) =>
    e.handle(<Object?, Object?>{...m, DspMsg.req: 1});

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('mute_lifecycle'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'cold start is muted even when the last session saved unmuted',
    () async {
      final opts = DspEngineOptions(configDir: tmp.path, audio: 'null');
      final first = DspEngine((_) {}, options: opts);
      expect(
        first.stateMap()['muted'],
        isTrue,
        reason: 'fresh install starts muted',
      );
      await _cmd(first, <String, Object?>{
        DspMsg.cmd: DspCmd.setMuted,
        'muted': false,
      });
      expect(first.stateMap()['muted'], isFalse);
      await _cmd(first, <String, Object?>{
        DspMsg.cmd: DspCmd.setVolume,
        'value': 0.4,
      });
      await first.shutdown();

      final second = DspEngine((_) {}, options: opts);
      try {
        expect(
          second.stateMap()['muted'],
          isTrue,
          reason: '"unmuted" must not survive a cold start',
        );
        expect(
          second.stateMap()['volume'],
          closeTo(1.0, 1e-9),
          reason: 'a hidden persisted volume must not leave audio quiet',
        );
      } finally {
        await second.shutdown();
      }
    },
  );

  test('mute holds no playback device; unmute while running opens it; mute survives stop/start', () async {
    final audio = _RecordingAudio();
    final engine = DspEngine((_) {}, audioOutput: audio);
    try {
      await engine.selectSource('synth', <Object?, Object?>{
        'sampleRate': 250000.0,
        'pump': 'realTime',
      });
      await engine.start();
      expect(
        audio.active,
        isFalse,
        reason: 'muted at start: Android playback must stay closed',
      );
      await _cmd(engine, <String, Object?>{
        DspMsg.cmd: DspCmd.setMuted,
        'muted': false,
      });
      expect(audio.active, isTrue);
      await _cmd(engine, <String, Object?>{
        DspMsg.cmd: DspCmd.setMuted,
        'muted': true,
      });
      expect(audio.active, isFalse);
      await engine.stop();
      await engine.start();
      expect(audio.active, isFalse, reason: 'restart keeps the muted state');
      await _cmd(engine, <String, Object?>{
        DspMsg.cmd: DspCmd.setMuted,
        'muted': false,
      });
      await engine.stop();
      expect(audio.active, isFalse);
      await engine.start();
      expect(audio.active, isTrue, reason: 'restart keeps the unmuted state');
      expect(audio.closes, audio.opens - 1);
    } finally {
      await engine.shutdown();
    }
  });

  test('fatal source loss while unmuted releases the audio device', () async {
    final audio = _RecordingAudio();
    final events = <Map<String, Object?>>[];
    final registry = SourceRegistry.withBuiltins();
    registerFakeUsbSources(registry);
    final engine = DspEngine(
      events.add,
      audioOutput: audio,
      registry: registry,
    );
    try {
      await engine.selectSource('usb', <Object?, Object?>{
        'deviceName': '/dev/bus/usb/001/002',
      });
      await _cmd(engine, <String, Object?>{
        DspMsg.cmd: DspCmd.setMuted,
        'muted': false,
      });
      await engine.start();
      expect(audio.active, isTrue);
      await _cmd(engine, <String, Object?>{
        DspMsg.cmd: DspCmd.sourceSetting,
        'id': 'simulateLoss',
        'value': true,
      });
      await pumpEventQueue();
      expect(engine.running, isFalse);
      expect(
        audio.active,
        isFalse,
        reason: 'unplugged dongle must not keep AAudio open',
      );
      expect(
        events.any((e) => e[DspMsg.evt] == DspEvt.error && e['fatal'] == true),
        isTrue,
      );
      expect(
        engine.stateMap()['muted'],
        isFalse,
        reason: 'device loss does not change mute',
      );
    } finally {
      await engine.shutdown();
    }
  });

  test(
    'a source stop that throws still releases audio and stops the engine',
    () async {
      final audio = _RecordingAudio();
      final registry = SourceRegistry.withBuiltins()
        ..register(
          'throwing',
          (p, ctx) => SourceInstance(_ThrowingStop(ctx.core)),
        );
      final engine = DspEngine((_) {}, audioOutput: audio, registry: registry);
      try {
        await engine.selectSource('throwing', const <Object?, Object?>{});
        await _cmd(engine, <String, Object?>{
          DspMsg.cmd: DspCmd.setMuted,
          'muted': false,
        });
        await engine.start();
        expect(audio.active, isTrue);
        await engine.stop();
        expect(engine.running, isFalse);
        expect(audio.active, isFalse);
      } finally {
        await engine.shutdown();
      }
    },
  );
}

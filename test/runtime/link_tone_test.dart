// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/audio_output.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/runtime/dsp_protocol.dart';
import 'package:sdr_flutter/runtime/source_registry.dart';

import 'fake_usb_source.dart';

class _CaptureOutput extends AudioOutput {
  final writes = <Float32List>[];
  int opens = 0;
  int closes = 0;
  bool active = false;
  @override
  String get name => 'capture-link';
  @override
  bool open(int sampleRate) {
    opens++;
    active = true;
    return true;
  }

  @override
  bool write(Float32List data, int frames) {
    if (!active) return false;
    writes.add(Float32List.fromList(data.sublist(0, frames * 2)));
    return true;
  }

  @override
  void close() {
    if (active) closes++;
    active = false;
  }
}

double _frequency(Float32List data) {
  var crossings = 0;
  for (var i = 2; i < data.length; i += 2) {
    if (data[i - 2] <= 0 && data[i] > 0) crossings++;
  }
  return crossings * 48000 / (data.length / 2);
}

void main() {
  late DspEngine engine;
  late _CaptureOutput audio;
  setUp(() async {
    audio = _CaptureOutput();
    final registry = SourceRegistry.withBuiltins();
    registerFakeUsbSources(registry);
    engine = DspEngine((_) {}, registry: registry, audioOutput: audio);
    await engine.selectSource('usb', {'deviceName': '/dev/bus/usb/001/002'});
  });
  tearDown(() async => engine.shutdown());

  test('cold start and manual stop/start are silent; reconnect is high, loss low and closes output', () async {
    engine.setMuted(false);
    await engine.start();
    expect(audio.writes, isEmpty);
    await engine.stop();
    await engine.start();
    expect(audio.writes, isEmpty);
    await engine.handle({DspMsg.cmd: DspCmd.releaseSource, 'deviceLost': true});
    expect(audio.writes.length, 1);
    final low = audio.writes.single;
    expect(_frequency(low), closeTo(440, 12));
    expect(low.length ~/ 2, inInclusiveRange(4800, 7200));
    expect(low.first, closeTo(0, 1e-6));
    expect(low.last, closeTo(0, 1e-3));
    expect(low.every((v) => v.abs() <= math.sqrt(1)), isTrue);
    expect(audio.active, isFalse);
    await engine.handle({DspMsg.cmd: DspCmd.releaseSource, 'deviceLost': true});
    expect(audio.writes.length, 1, reason: 'duplicate detach / ENODEV');
    await engine.selectSource('usb', {'deviceName': '/dev/bus/usb/001/003'});
    await engine.handle({DspMsg.cmd: DspCmd.start, 'reconnected': true});
    expect(audio.writes.length, 2);
    expect(_frequency(audio.writes.last), closeTo(880, 12));
  });

  test('muted loss does not open audio or write, even if detached', () async {
    await engine.start();
    await engine.handle({DspMsg.cmd: DspCmd.releaseSource, 'deviceLost': true});
    expect(audio.opens, 0);
    expect(audio.writes, isEmpty);
    await engine.selectSource('usb', {'deviceName': '/dev/bus/usb/001/003'});
    await engine.handle({DspMsg.cmd: DspCmd.start, 'reconnected': true});
    expect(audio.opens, 0);
    expect(audio.writes, isEmpty);
  });

  test(
    'synthetic source and failed/idle USB do not produce connection tones',
    () async {
      await engine.releaseSource();
      engine.setMuted(false);
      await engine.selectSource('synth', {
        'sampleRate': 250000.0,
        'pump': 'realTime',
      });
      await engine.handle({DspMsg.cmd: DspCmd.start, 'reconnected': true});
      await engine.handle({
        DspMsg.cmd: DspCmd.releaseSource,
        'deviceLost': true,
      });
      expect(audio.writes, isEmpty);
      await engine.selectSource('usb', {'deviceName': '/dev/bus/usb/001/003'});
      await engine.handle({
        DspMsg.cmd: DspCmd.releaseSource,
        'deviceLost': true,
      });
      expect(audio.writes, isEmpty);
    },
  );
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/audio_output.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/runtime/sdr_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _PreferredRadio extends DeviceProvider {
  final device = const SdrDeviceInfo(
    id: 'test:radio', name: 'test radio',
    sampleRates: [250000, 2400000, 3200000],
    gain: GainRange(min: 0, max: 0), hasAgc: false,
  );

  @override
  Future<List<SdrDeviceInfo>> listDevices() async => [device];
  @override
  bool owns(SdrDeviceInfo d) => d == device;
  @override
  Future<SdrDeviceInfo?> preferredDevice() async => device;
  @override
  Future<SourceSelection> open(SdrDeviceInfo d) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return const SourceSelection('synth', {'sampleRate': 2400000.0});
  }
}

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

void main() {
  test('preferred USB-like device does not inherit initial 8 MHz DSP rate', () async {
    final controller = SdrRadioController(
      providers: [_PreferredRadio()],
      options: const DspEngineOptions(audio: 'null'),
    );
    try {
      await controller.ready;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(controller.lastError, isNull);
      expect(controller.selectedDevice?.id, 'test:radio');
      expect(controller.sampleRate, 2400000);
    } finally {
      controller.dispose();
    }
  });

  test('audio device is only held while SDR source is running, including restart', () async {
    final audio = _RecordingAudio();
    final engine = DspEngine((_) {}, audioOutput: audio);
    try {
      expect(audio.active, isFalse, reason: 'initial idle app must not reserve audio playback');
      await engine.selectSource('synth', {'sampleRate': 250000.0, 'pump': 'realTime'});
      expect(audio.active, isFalse);
      await engine.start();
      expect(audio.active, isTrue);
      await engine.stop();
      expect(audio.active, isFalse, reason: 'Stop must release the Android playback device');
      await engine.start();
      expect(audio.active, isTrue, reason: 'restart must reopen the playback device');
      await engine.stop();
      expect(audio.active, isFalse);
      expect(audio.opens, greaterThanOrEqualTo(2));
      expect(audio.closes, audio.opens);
    } finally {
      await engine.shutdown();
    }
  });
}

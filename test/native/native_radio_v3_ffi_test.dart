// SPDX-License-Identifier: GPL-3.0-or-later
// Opt-in FFI smoke against a real, complete ABI v3 host library. Set
// SDRCORE_V3_PROBE_LIBRARY to a host libsdrcore.so build (sdr_version()==3).
// SDR_HW_WAV keeps the hardware WFM recording at that path for listening.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/native_radio_controller.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _SyntheticSource implements NativeDeviceSource {
  final device = const NativeDevice(
    SdrDeviceInfo(
      id: 'synthetic:1',
      name: 'Native synthetic',
      sampleRates: [2400000],
      gain: GainRange(min: 0, max: 49.6),
    ),
    2,
  );
  @override
  Stream<void> get changes => const Stream<void>.empty();
  @override
  Future<List<NativeDevice>> list() async => [device];
  @override
  Future<NativeDevice> open(NativeDevice selected) async => selected;
  @override
  Future<void> close(NativeDevice selected) async {}
}

void main() {
  final library = Platform.environment['SDRCORE_V3_PROBE_LIBRARY'];
  test(
    'real v3 synthetic source delivers bounded FFT and audio statistics',
    () async {
      final api = FfiNativeRadioApi.open(libraryPath: library);
      final h = api.create();
      try {
        api.openSynthetic(h, 2400000);
        expect(() => api.rtlTunerGains(h), throwsA(isA<SdrCoreError>()));
        api.controls(
          h,
          const NativeControls(
            centerHz: 100000000,
            offsetHz: 0,
            sampleRate: 2400000,
            mode: 1,
            bandwidthHz: 150000,
            gainTenthsDb: 200,
            agc: false,
            squelch: 0,
            squelchLevelDb: -50,
            autoOffsetDb: 0,
            volume: .5,
            muted: false,
          ),
        );
        api.display(h, const NativeDisplay(0, 2400000, 256));
        api.audioSink(h, 'null');
        api.start(h);
        NativeFft? row;
        NativeSnapshot? snapshot;
        for (var i = 0; i < 80; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          snapshot = api.snapshot(h);
          row ??= api.fft(h, row?.sequence ?? 0);
          if (row != null && snapshot.audioFrames > 0) break;
        }
        expect(snapshot!.state, 2);
        expect(snapshot.inputSamples, greaterThan(0));
        expect(snapshot.audioFrames, greaterThan(0));
        expect(row, isNotNull);
        expect(row!.bins.length, 256);
        expect(row.generation, snapshot.generation);
        expect(row.controlSequence, snapshot.controlSequence);
        api.stop(h);
        api.close(h);
      } finally {
        api.destroy(h);
      }
    },
    skip: library == null
        ? 'Set SDRCORE_V3_PROBE_LIBRARY to a v3 host build'
        : null,
  );

  test(
    'real v3 RadioController retunes and streams one bounded FFT channel',
    () async {
      final api = FfiNativeRadioApi.open(libraryPath: library);
      final controller = NativeRadioController(
        api: api,
        source: _SyntheticSource(),
        autoStart: false,
        pollInterval: const Duration(milliseconds: 200),
      );
      final rows = <FftRow>[];
      final sub = controller.fftRows.listen(rows.add);
      try {
        await controller.refreshDevices();
        controller.setFftWidth(128);
        await controller.start();
        expect(controller.running, isTrue);
        controller.setMode(DemodMode.nfm);
        controller.setTuning(centerFrequency: 99500000, vfoOffset: 12000);
        controller.setTuning(centerFrequency: 99512000, vfoOffset: 0);
        controller.setMuted(false);
        for (var i = 0; i < 100 && rows.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(controller.centerFrequency, 99512000);
        expect(controller.vfoOffset, 0);
        expect(controller.mode, DemodMode.nfm);
        expect(rows, isNotEmpty);
        expect(rows.last.width, 128);
        await controller.stop();
        expect(controller.linkState, DeviceLinkState.stoppedByUser);
      } finally {
        await sub.cancel();
        controller.dispose();
      }
    },
    skip: library == null
        ? 'Set SDRCORE_V3_PROBE_LIBRARY to a v3 host build'
        : null,
  );

  final hw = Platform.environment['SDR_HW_TEST'] == '1';
  test(
    'Blog V4 legacy index restores the exact native tuner gain on host',
    () async {
      final api = FfiNativeRadioApi.open(libraryPath: library);
      final devices = await HostNativeDeviceSource(api).list();
      final rtl = devices.where((d) => d.source == SdrSourceId.rtlsdr).first;
      final serial = RegExp(r'\[([^\[\]]+)\]$')
          .firstMatch(rtl.info.name)
          ?.group(1);
      expect(
        serial,
        isNotNull,
        reason: 'RTL serial needed for exact migration',
      );
      final h = api.create();
      late final int expected;
      try {
        api.openHostUsb(h, rtl.bus!, rtl.address!, rtl.source);
        expected = api.rtlTunerGains(h)[7];
        api.close(h);
      } finally {
        api.destroy(h);
      }
      final dir = Directory.systemTemp.createTempSync('n5_ffi_gain_');
      final name = 'Old RTL [$serial]';
      File('${dir.path}/config.json').writeAsStringSync(
        jsonEncode({
          'sources': {
            'rtl_sdr': {
              'device': name,
              'devices': {
                name: {'gain': 7},
              },
            },
          },
        }),
      );
      final controller = NativeRadioController(
        api: api,
        source: HostNativeDeviceSource(api),
        configDir: dir.path,
        autoStart: false,
      );
      try {
        await controller.refreshDevices();
        await controller.start();
        expect(controller.running, isTrue, reason: controller.lastError);
        expect((controller.gain * 10).round(), expected);
        await controller.stop();
        expect(File('${dir.path}/config.json').existsSync(), isTrue);
      } finally {
        controller.dispose();
        dir.deleteSync(recursive: true);
      }
    },
    skip: library == null || !hw ? 'Host RTL and SDR_HW_TEST=1 required' : null,
  );
  final hwFreq =
      double.tryParse(Platform.environment['SDR_HW_FREQ'] ?? '') ?? 100500000;
  test(
    'Blog V4 hardware: native WFM unmuted writes non-silent WAV, no IQ/PCM in Dart',
    () async {
      final api = FfiNativeRadioApi.open(libraryPath: library);
      final wav =
          Platform.environment['SDR_HW_WAV'] ??
          '${Directory.systemTemp.path}/n2_hw_${pid}_wfm.wav';
      final controller = NativeRadioController(
        api: api,
        source: HostNativeDeviceSource(api),
        autoStart: false,
        audioSink: 'wav:$wav',
      );
      try {
        await controller.refreshDevices();
        expect(controller.devices, isNotEmpty, reason: 'no host SDR found');
        controller.setMode(DemodMode.wfm);
        controller.setTuning(centerFrequency: hwFreq, vfoOffset: 0);
        controller.setGain(30);
        controller.setMuted(false);
        await controller.start();
        expect(controller.running, isTrue, reason: '${controller.lastError}');
        await Future<void>.delayed(const Duration(seconds: 8));
        final stats = Map<String, Object?>.of(controller.stats);
        await controller.stop();
        // ignore: avoid_print
        print('hw stats: $stats');
        expect(controller.lastError, isNull);
        expect(stats['audioFrames'] as int, greaterThan(48000 * 5));
        expect(stats['audioNonsilentFrames'] as int, greaterThan(48000 * 4));
        final bytes = File(wav).readAsBytesSync();
        var nonzero = 0;
        final data = ByteData.sublistView(bytes);
        for (var i = 44; i + 1 < bytes.length; i += 2) {
          if (data.getInt16(i, Endian.little) != 0) nonzero++;
        }
        expect(nonzero, greaterThan(48000 * 2 * 4));
      } finally {
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
    skip: library == null || !hw
        ? 'Set SDR_HW_TEST=1 and SDRCORE_V3_PROBE_LIBRARY with a host SDR'
        : null,
  );
}

// SPDX-License-Identifier: GPL-3.0-or-later
// NativeRadioController's exposure of the optional decoder extension.
// Verifies: default "no decoder" when no NativeDecoderApi is supplied
// (native 0 availability), safe open/close/dispose handling (no open
// native handle -> deselect-only, no crash), and that the controller never
// fabricates availability of its own accord.
import 'dart:async';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_decoder_api.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/native_radio_controller.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _StubSource implements NativeDeviceSource {
  final device = const NativeDevice(
    SdrDeviceInfo(
      id: 'synthetic:1',
      name: 'Test synthetic',
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
  Future<NativeDevice> open(NativeDevice d) async => d;
  @override
  Future<void> close(NativeDevice d) async {}
}

class _StubApi implements NativeRadioApi {
  int state = SdrState.idle;
  @override
  Pointer<SdrHandle> create() {
    state = SdrState.idle;
    return Pointer<SdrHandle>.fromAddress(99);
  }

  @override
  void destroy(Pointer<SdrHandle> h) {}
  @override
  void openSynthetic(Pointer<SdrHandle> h, int r) => state = SdrState.open;
  @override
  void openFile(Pointer<SdrHandle> h, int fd, int r) => state = SdrState.open;
  @override
  void openUsb(Pointer<SdrHandle> h, int fd, int s) => state = SdrState.open;
  @override
  void openHostUsb(Pointer<SdrHandle> h, int b, int a, int s) =>
      state = SdrState.open;
  @override
  List<SdrHostUsbDevice> hostDevices() => [];
  @override
  List<int> rtlTunerGains(Pointer<SdrHandle> h) => [];
  @override
  void controls(Pointer<SdrHandle> h, NativeControls c) {}
  @override
  void display(Pointer<SdrHandle> h, NativeDisplay d) {}
  @override
  void stereo(Pointer<SdrHandle> h, bool enabled) {}
  @override
  void audioSink(Pointer<SdrHandle> h, String s) {}
  @override
  void start(Pointer<SdrHandle> h) => state = SdrState.running;
  @override
  void stop(Pointer<SdrHandle> h) => state = SdrState.open;
  @override
  void close(Pointer<SdrHandle> h) => state = SdrState.idle;
  @override
  NativeSnapshot snapshot(Pointer<SdrHandle> h) => NativeSnapshot(
    state: state,
    source: 2,
    lastError: 0,
    sampleRate: 2400000,
    centerHz: 100000000,
    offsetHz: 0,
    mode: 1,
    bandwidthHz: 150000,
    gainTenthsDb: 200,
    squelchOpen: false,
    squelchReady: false,
    squelchMetricDb: 0,
    squelchThresholdDb: 0,
    generation: 1,
    controlSequence: 1,
    errorSequence: 0,
    inputSamples: 0,
    processedSamples: 0,
    droppedSamples: 0,
    audioFrames: 0,
    audioDroppedFrames: 0,
    audioNonsilentFrames: 0,
    fftOverwrites: 0,
  );
  @override
  NativeFft? fft(Pointer<SdrHandle> h, int afterSequence) => null;
}

class _FakeDecoderApi implements NativeDecoderApi {
  final selectCalls = <Pointer<SdrHandle>>[];
  final pollCalls = <Pointer<SdrHandle>>[];
  List<NativeDecoderDescriptor> list = const [
    NativeDecoderDescriptor(
      id: 'sstv',
      input: 1,
      exclusiveReceiver: false,
      requiredMode: 4,
      requiredRateHz: 24000,
      result: 3,
      available: true,
    ),
  ];
  @override
  List<NativeDecoderDescriptor> descriptors() => list;
  @override
  bool select(Pointer<SdrHandle> handle, String? id, String configJson) {
    selectCalls.add(handle);
    return true;
  }

  @override
  NativeDecoderEvent? poll(Pointer<SdrHandle> handle, int afterSequence) {
    pollCalls.add(handle);
    return null;
  }
}

Future<void> until(bool Function() check) async {
  for (var i = 0; i < 100; i++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out');
}

void main() {
  group('NativeRadioController.decoderBackend', () {
    test(
      'defaults to no available decoder ids when no NativeDecoderApi is '
      'supplied (optional extension absent, no fabricated availability)',
      () {
        final controller = NativeRadioController(
          api: _StubApi(),
          source: _StubSource(),
          autoStart: false,
        );
        try {
          expect(controller.decoderBackend.availableIds, isEmpty);
          expect(controller.decoderBackend.select(null, const {}), isTrue);
          expect(controller.decoderBackend.select('sstv', const {}), isFalse);
          expect(controller.decoderBackend.poll(0), isNull);
        } finally {
          controller.dispose();
        }
      },
    );

    test(
      'with a decoder API injected but no open native handle, select/poll '
      'are safe and never touch native (controller not started)',
      () {
        final decoderApi = _FakeDecoderApi();
        final controller = NativeRadioController(
          api: _StubApi(),
          source: _StubSource(),
          autoStart: false,
          decoderApi: decoderApi,
        );
        try {
          expect(controller.decoderBackend.availableIds, {'sstv'});
          expect(controller.decoderBackend.select(null, const {}), isTrue);
          expect(controller.decoderBackend.select('sstv', const {}), isFalse);
          expect(decoderApi.selectCalls, isEmpty);
          expect(controller.decoderBackend.poll(0), isNull);
          expect(decoderApi.pollCalls, isEmpty);
        } finally {
          controller.dispose();
        }
      },
    );

    test(
      'with an open native handle (running), select forwards to native',
      () async {
        final decoderApi = _FakeDecoderApi();
        final controller = NativeRadioController(
          api: _StubApi(),
          source: _StubSource(),
          autoStart: true,
          decoderApi: decoderApi,
        );
        try {
          await until(() => controller.running);
          expect(
            controller.decoderBackend.select('sstv', const {'mode': 'auto'}),
            isTrue,
          );
          expect(decoderApi.selectCalls, hasLength(1));
          controller.decoderBackend.poll(0);
          expect(decoderApi.pollCalls, hasLength(1));
        } finally {
          controller.dispose();
        }
      },
    );

    test(
      'after stop(), the handle is released and decoderBackend reverts to '
      'the safe no-handle behavior (no crash, no native calls)',
      () async {
        final decoderApi = _FakeDecoderApi();
        final controller = NativeRadioController(
          api: _StubApi(),
          source: _StubSource(),
          autoStart: true,
          decoderApi: decoderApi,
        );
        try {
          await until(() => controller.running);
          await controller.stop();
          decoderApi.selectCalls.clear();
          decoderApi.pollCalls.clear();
          expect(controller.decoderBackend.select('sstv', const {}), isFalse);
          expect(decoderApi.selectCalls, isEmpty);
          expect(controller.decoderBackend.poll(0), isNull);
          expect(decoderApi.pollCalls, isEmpty);
        } finally {
          controller.dispose();
        }
      },
    );

    test(
      'dispose() releases the handle; decoderBackend calls afterward are '
      'safe no-ops, never touching native',
      () async {
        final decoderApi = _FakeDecoderApi();
        final controller = NativeRadioController(
          api: _StubApi(),
          source: _StubSource(),
          autoStart: true,
          decoderApi: decoderApi,
        );
        await until(() => controller.running);
        controller.dispose();
        decoderApi.selectCalls.clear();
        decoderApi.pollCalls.clear();
        expect(controller.decoderBackend.select('sstv', const {}), isFalse);
        expect(controller.decoderBackend.poll(0), isNull);
        expect(decoderApi.selectCalls, isEmpty);
        expect(decoderApi.pollCalls, isEmpty);
      },
    );
  });
}

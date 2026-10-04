// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/native_radio_controller.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

const device = NativeDevice(
  SdrDeviceInfo(
    id: 'test:1',
    name: 'Test RTL',
    sampleRates: [2400000],
    gain: GainRange(min: 0, max: 49.6),
    hasAgc: false,
  ),
  SdrSourceId.rtlsdr,
  bus: 2,
  address: 3,
);

class FakeSource implements NativeDeviceSource {
  List<NativeDevice> devices = [device];
  final changesController = StreamController<void>.broadcast();
  final calls = <String>[];
  @override
  Stream<void> get changes => changesController.stream;
  @override
  Future<List<NativeDevice>> list() async => devices;
  @override
  Future<NativeDevice> open(NativeDevice d) async {
    calls.add('open');
    return d;
  }

  @override
  Future<void> close(NativeDevice d) async {
    calls.add('close');
  }
}

class FakeApi implements NativeRadioApi {
  final calls = <String>[];
  final applied = <NativeControls>[];
  final displays = <NativeDisplay>[];
  int state = SdrState.idle, generation = 0, controlSequence = 0;
  int error = 0, errorSequence = 0, fftSequence = 0;
  bool rejectControls = false, squelchReady = false;
  NativeControls? controlsValue;
  @override
  Pointer<SdrHandle> create() {
    calls.add('create');
    return Pointer.fromAddress(42);
  }

  @override
  void destroy(Pointer<SdrHandle> h) {
    calls.add('destroy');
  }

  @override
  void openSynthetic(Pointer<SdrHandle> h, int r) {
    state = SdrState.open;
    calls.add('synth');
  }

  @override
  void openFile(Pointer<SdrHandle> h, int fd, int r) {
    state = SdrState.open;
  }

  @override
  void openUsb(Pointer<SdrHandle> h, int fd, int s) {
    state = SdrState.open;
  }

  @override
  void openHostUsb(Pointer<SdrHandle> h, int b, int a, int s) {
    state = SdrState.open;
    calls.add('host:$b:$a:$s');
  }

  @override
  List<SdrHostUsbDevice> hostDevices() => [];
  @override
  void controls(Pointer<SdrHandle> h, NativeControls c) {
    if (rejectControls) throw SdrCoreError(SdrResult.unsupported);
    controlsValue = c;
    applied.add(c);
    controlSequence++;
    calls.add('controls');
  }

  @override
  void display(Pointer<SdrHandle> h, NativeDisplay d) {
    displays.add(d);
    controlSequence++;
    calls.add('display');
  }

  @override
  void audioSink(Pointer<SdrHandle> h, String s) {
    calls.add('sink:$s');
  }

  @override
  void start(Pointer<SdrHandle> h) {
    state = SdrState.running;
    generation++;
    calls.add('start');
  }

  @override
  void stop(Pointer<SdrHandle> h) {
    state = SdrState.open;
    calls.add('stop');
  }

  @override
  void close(Pointer<SdrHandle> h) {
    state = SdrState.idle;
    calls.add('close');
  }

  @override
  NativeSnapshot snapshot(Pointer<SdrHandle> h) => NativeSnapshot(
    state: state,
    source: 3,
    lastError: error,
    sampleRate: 2400000,
    centerHz: controlsValue?.centerHz ?? 0,
    offsetHz: controlsValue?.offsetHz ?? 0,
    mode: controlsValue?.mode ?? 1,
    bandwidthHz: controlsValue?.bandwidthHz ?? 150000,
    gainTenthsDb: controlsValue?.gainTenthsDb ?? 200,
    squelchOpen: true,
    squelchReady: squelchReady,
    squelchMetricDb: -15,
    squelchThresholdDb: -30,
    generation: generation,
    controlSequence: controlSequence,
    errorSequence: errorSequence,
    inputSamples: 240000,
    processedSamples: 240000,
    droppedSamples: 0,
    audioFrames: 4800,
    audioDroppedFrames: 0,
    audioNonsilentFrames: 4700,
    fftOverwrites: 3,
  );
  @override
  NativeFft? fft(Pointer<SdrHandle> h, int afterSequence) {
    calls.add('fft:$afterSequence');
    if (fftSequence <= afterSequence) return null;
    final d = displays.last;
    return NativeFft(
      fftSequence,
      generation,
      controlSequence,
      98700000,
      101300000,
      Float32List(d.width)..fillRange(0, d.width, -40),
    );
  }
}

Future<void> until(bool Function() check) async {
  for (var i = 0; i < 100; i++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for native controller');
}

void main() {
  test('v3 Dart struct sizes match the compiled C ABI', () {
    expect(FfiNativeRadioApi.layoutSizes, [72, 24, 152, 64, 236]);
  });

  test('ABI 2 library cannot be mistaken for an N2 receiver', () {
    final path = Platform.environment['SDRCORE_HOST_LIBRARY'];
    if (path == null) return;
    expect(
      () => FfiNativeRadioApi.open(libraryPath: path),
      throwsA(isA<UnsupportedError>()),
    );
  });

  late FakeApi api;
  late FakeSource source;
  NativeRadioController? radio;
  setUp(() {
    api = FakeApi();
    source = FakeSource();
  });
  tearDown(() async {
    radio?.dispose();
    radio = null;
    await source.changesController.close();
  });
  NativeRadioController create({bool autoStart = true}) {
    return radio = NativeRadioController(
      api: api,
      source: source,
      autoStart: autoStart,
      pollInterval: const Duration(milliseconds: 20),
      fftInterval: const Duration(milliseconds: 35),
      discoveryInterval: const Duration(seconds: 30),
    );
  }

  test(
    'opens v3 once, maps controls, closes before releasing the source',
    () async {
      final r = create();
      await until(() => r.running);
      expect(api.calls, [
        'create',
        'host:2:3:3',
        'controls',
        'display',
        'sink:null',
        'start',
      ]);
      expect(api.applied.single.muted, isTrue);
      expect(r.linkState, DeviceLinkState.receiving);
      r.setMode(DemodMode.usb);
      r.setBandwidth(2600);
      r.setTuning(centerFrequency: 100200000, vfoOffset: 2500);
      r.setTuning(centerFrequency: 100202500, vfoOffset: 0);
      r.setSquelchType(SquelchType.auto);
      r.setMuted(false);
      expect(api.applied.last.centerHz, 100202500);
      expect(api.applied.last.offsetHz, 0);
      expect(api.applied.last.mode, DemodMode.usb.id);
      expect(api.applied.last.bandwidthHz, 2600);
      expect(api.applied.last.squelch, 2);
      expect(api.applied.last.muted, isFalse);
      await r.stop();
      expect(api.calls.sublist(api.calls.length - 3), [
        'stop',
        'close',
        'destroy',
      ]);
      expect(source.calls.last, 'close');
      expect(r.linkState, DeviceLinkState.stoppedByUser);
      await r.refreshDevices();
      expect(r.running, isFalse);
    },
  );

  test(
    'FFT is screen-width bounded and stale generations are dropped',
    () async {
      final r = create();
      await until(() => r.running);
      final rows = <FftRow>[];
      final sub = r.fftRows.listen(rows.add);
      r.setFftWidth(9000);
      expect(api.displays.last.width, nativeMaxFftWidth);
      api.fftSequence = 1;
      await until(() => rows.length == 1);
      expect(rows.single.width, nativeMaxFftWidth);
      api.generation++;
      api.fftSequence = 2;
      await Future<void>.delayed(const Duration(milliseconds: 55));
      expect(rows.length, 1);
      await sub.cancel();
    },
  );

  test(
    'new tune clears scanner squelch readiness until new detector snapshot',
    () async {
      final r = create();
      await until(() => r.running);
      r.setMode(DemodMode.nfm);
      r.setSquelchType(SquelchType.auto);
      api.squelchReady = true;
      await until(() => r.autoSquelchStatus != null);
      r.setTuning(centerFrequency: 99500000, vfoOffset: 0);
      expect(r.autoSquelchStatus, isNull);
      api.squelchReady = false;
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(r.autoSquelchStatus, isNull);
      api.squelchReady = true;
      await until(() => r.autoSquelchStatus != null);
    },
  );

  test(
    'unsupported native controls roll back instead of appearing enabled',
    () async {
      final r = create();
      await until(() => r.running);
      api.rejectControls = true;
      r.setGain(35);
      r.setMuted(false);
      r.setMode(DemodMode.nfm);
      expect(r.gain, 20);
      expect(r.muted, isTrue);
      expect(r.mode, DemodMode.wfm);
      expect(r.lastError, contains('Native control failed'));
    },
  );

  test(
    'service promotion failure prevents native start and closes the claim',
    () async {
      radio = NativeRadioController(
        api: api,
        source: source,
        beforeStart: () async {
          throw StateError('foreground denied');
        },
        afterStop: () async {
          source.calls.add('service stop');
        },
      );
      await until(() => radio!.linkState == DeviceLinkState.failed);
      expect(api.calls, isNot(contains('start')));
      expect(api.calls, containsAllInOrder(['close', 'destroy']));
      expect(
        source.calls,
        containsAllInOrder(['open', 'close', 'service stop']),
      );
    },
  );

  test(
    'Stop while foreground promotion is pending never starts native DSP',
    () async {
      final promotion = Completer<void>();
      radio = NativeRadioController(
        api: api,
        source: source,
        beforeStart: () => promotion.future,
        autoStart: true,
      );
      await until(() => api.calls.contains('sink:null'));
      final stopping = radio!.stop();
      promotion.complete();
      await stopping;
      expect(api.calls, isNot(contains('start')));
      expect(api.calls, containsAllInOrder(['close', 'destroy']));
      expect(radio!.linkState, DeviceLinkState.stoppedByUser);
    },
  );

  test(
    'sticky error stops and releases; attach is required for auto-retry',
    () async {
      final r = create();
      await until(() => r.running);
      api.state = SdrState.error;
      api.error = SdrResult.deviceGone;
      api.errorSequence++;
      await until(
        () => !r.running && r.linkState == DeviceLinkState.disconnected,
      );
      expect(r.lastError, contains('-5'));
      expect(api.calls, containsAllInOrder(['stop', 'close', 'destroy']));
      final count = api.calls.where((c) => c == 'create').length;
      await r.refreshDevices();
      expect(api.calls.where((c) => c == 'create').length, count);
    },
  );
}

// SPDX-License-Identifier: GPL-3.0-or-later
// NativeRadioController's rtl_tcp network source: selection, link state,
// error mapping, discovery interaction and controls reapplication on
// reconnect. Uses a fake NativeRadioApi/NativeDeviceSource, same style as
// native_radio_controller_test.dart.
import 'dart:async';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/native_radio_controller.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

const usbDevice = NativeDevice(
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
  List<NativeDevice> devices = [];
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
  int state = SdrState.idle, generation = 0, controlSequence = 0;
  int error = 0, errorSequence = 0, fftSequence = 0;
  int rtlTcpLinkValue = 0;
  String? lastHost;
  int? lastPort;
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
    calls.add('usb');
  }

  @override
  void openHostUsb(Pointer<SdrHandle> h, int b, int a, int s) {
    state = SdrState.open;
    calls.add('host:$b:$a:$s');
  }

  @override
  void openRtlTcp(Pointer<SdrHandle> h, String host, int port) {
    state = SdrState.open;
    lastHost = host;
    lastPort = port;
    calls.add('rtlTcp:$host:$port');
  }

  @override
  int rtlTcpLink(Pointer<SdrHandle> h) {
    calls.add('rtlTcpLink');
    return rtlTcpLinkValue;
  }

  @override
  List<SdrHostUsbDevice> hostDevices() => [];
  @override
  List<int> rtlTunerGains(Pointer<SdrHandle> h) {
    calls.add('gains');
    return [0, 125, 280, 496];
  }

  @override
  void controls(Pointer<SdrHandle> h, NativeControls c) {
    controlsValue = c;
    applied.add(c);
    controlSequence++;
    calls.add('controls');
  }

  @override
  void display(Pointer<SdrHandle> h, NativeDisplay d) {
    controlSequence++;
    calls.add('display');
  }

  @override
  void stereo(Pointer<SdrHandle> h, bool enabled) {
    controlSequence++;
    calls.add('stereo:$enabled');
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
    source: SdrSourceId.rtlTcp,
    lastError: error,
    sampleRate: controlsValue?.sampleRate ?? 2400000,
    centerHz: controlsValue?.centerHz ?? 0,
    offsetHz: controlsValue?.offsetHz ?? 0,
    mode: controlsValue?.mode ?? 1,
    bandwidthHz: controlsValue?.bandwidthHz ?? 150000,
    gainTenthsDb: controlsValue?.gainTenthsDb ?? 200,
    squelchOpen: false,
    squelchReady: false,
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
    return null;
  }
}

Future<void> until(bool Function() check) async {
  for (var i = 0; i < 200; i++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for native controller');
}

void main() {
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

  test('NativeDevice.rtlTcp builds id/name/sample rates/gain/frequency range', () {
    final d = NativeDevice.rtlTcp('192.168.1.5', 1234);
    expect(d.info.id, 'rtltcp:192.168.1.5:1234');
    expect(d.info.name, 'rtl_tcp 192.168.1.5:1234');
    expect(d.info.sampleRates, [
      250000,
      1024000,
      1536000,
      1792000,
      1920000,
      2048000,
      2160000,
      2400000,
      2560000,
      2880000,
      3200000,
    ]);
    expect(d.info.hasAgc, isFalse);
    expect(d.info.maxFrequency, lessThanOrEqualTo(4294967295));
    expect(d.source, SdrSourceId.rtlTcp);
    expect(d.isNetwork, isTrue);
  });

  test('NativeDevice.rtlTcp brackets an IPv6 host in the display name', () {
    final d = NativeDevice.rtlTcp('::1', 1234);
    expect(d.info.name, 'rtl_tcp [::1]:1234');
    expect(d.info.id, 'rtltcp:::1:1234');
  });

  test(
    'selectNetworkSource validates host/port synchronously before queueing',
    () {
      final r = create(autoStart: false);
      expect(() => r.selectNetworkSource('', 1234), throwsArgumentError);
      expect(() => r.selectNetworkSource('host', 0), throwsArgumentError);
      expect(() => r.selectNetworkSource('host', 65536), throwsArgumentError);
    },
  );

  test(
    'selectNetworkSource calls openRtlTcp (not openUsb/openSynthetic/source.open) on start',
    () async {
      final r = create(autoStart: false);
      await r.refreshDevices();
      await r.selectNetworkSource('192.168.1.10', 1234);
      expect(r.networkSelected, isTrue);
      expect(r.selectedDevice?.id, 'rtltcp:192.168.1.10:1234');
      await r.start();
      await until(() => r.running);
      expect(api.calls, contains('rtlTcp:192.168.1.10:1234'));
      expect(api.calls, isNot(contains('usb')));
      expect(api.calls, isNot(contains('synth')));
      expect(api.calls, isNot(anyElement(startsWith('host:'))));
      expect(source.calls, isNot(contains('open')));
    },
  );

  test('selectNetworkSource does not auto-start', () async {
    final r = create(autoStart: true);
    await r.refreshDevices();
    await r.selectNetworkSource('192.168.1.10', 1234);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(r.running, isFalse);
    expect(api.calls, isNot(contains('start')));
  });

  test(
    'discovery tick with a USB device present does not replace the network '
    'selection nor auto-start USB',
    () async {
      final r = create(autoStart: true);
      await r.refreshDevices();
      await r.selectNetworkSource('192.168.1.10', 1234);
      source.devices = [usbDevice];
      await r.refreshDevices();
      expect(r.networkSelected, isTrue);
      expect(r.selectedDevice?.id, 'rtltcp:192.168.1.10:1234');
      expect(r.running, isFalse);
      expect(api.calls, isNot(contains('usb')));
      expect(api.calls, isNot(anyElement(startsWith('host:'))));
      // devices getter stays USB-only.
      expect(r.devices.map((d) => d.id), ['test:1']);
    },
  );

  test(
    'link state is connecting until rtlTcpLink()==1, then receiving',
    () async {
      final r = create(autoStart: false);
      await r.refreshDevices();
      await r.selectNetworkSource('192.168.1.10', 1234);
      api.rtlTcpLinkValue = 0;
      await r.start();
      await until(() => r.running);
      expect(r.linkState, DeviceLinkState.connecting);
      await until(() => r.stats['rtlTcpLink'] == 'connecting');
      expect(r.stats['rtlTcpLink'], 'connecting');
      api.rtlTcpLinkValue = 1;
      await until(() => r.linkState == DeviceLinkState.receiving);
      expect(r.stats['rtlTcpLink'], 'linked');
    },
  );

  test('tcpTimeout/tcpRefused/tcpProtocol/deviceGone map to readable messages', () async {
    Future<String?> runError(int code, {required bool expectDisconnected}) async {
      api = FakeApi();
      source = FakeSource();
      final r = create(autoStart: false);
      await r.refreshDevices();
      await r.selectNetworkSource('192.168.1.10', 1234);
      await r.start();
      await until(() => r.running);
      api.state = SdrState.error;
      api.error = code;
      api.errorSequence++;
      await until(() => !r.running);
      if (expectDisconnected) {
        expect(r.linkState, DeviceLinkState.disconnected);
      } else {
        expect(r.linkState, DeviceLinkState.failed);
      }
      return r.lastError;
    }

    expect(
      await runError(SdrResult.tcpTimeout, expectDisconnected: false),
      contains('timed out'),
    );
    expect(
      await runError(SdrResult.tcpRefused, expectDisconnected: false),
      contains('refused'),
    );
    expect(
      await runError(SdrResult.tcpProtocol, expectDisconnected: false),
      contains('invalid header'),
    );
    expect(
      await runError(SdrResult.deviceGone, expectDisconnected: true),
      contains('disconnected'),
    );
  });

  test('no automatic reconnect after a network error', () async {
    final r = create(autoStart: false);
    await r.refreshDevices();
    await r.selectNetworkSource('192.168.1.10', 1234);
    await r.start();
    await until(() => r.running);
    api.state = SdrState.error;
    api.error = SdrResult.tcpRefused;
    api.errorSequence++;
    await until(() => !r.running);
    final createCount = api.calls.where((c) => c == 'create').length;
    // Advance well past several poll/discovery intervals.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await r.refreshDevices();
    expect(api.calls.where((c) => c == 'create').length, createCount);
    expect(r.running, isFalse);
  });

  test('stop() then no reconnect (manual stop never reconnects)', () async {
    final r = create(autoStart: false);
    await r.refreshDevices();
    await r.selectNetworkSource('192.168.1.10', 1234);
    await r.start();
    await until(() => r.running);
    await r.stop();
    expect(r.running, isFalse);
    expect(r.linkState, DeviceLinkState.stoppedByUser);
    final createCount = api.calls.where((c) => c == 'create').length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await r.refreshDevices();
    expect(api.calls.where((c) => c == 'create').length, createCount);
    expect(r.running, isFalse);
  });

  test(
    'retryDevice reconnects reapplying the latest tuning/gain controls',
    () async {
      final r = create(autoStart: false);
      await r.refreshDevices();
      await r.selectNetworkSource('192.168.1.10', 1234);
      await r.start();
      await until(() => r.running);
      r.setTuning(centerFrequency: 105300000, vfoOffset: 0);
      r.setGain(30);
      api.state = SdrState.error;
      api.error = SdrResult.tcpTimeout;
      api.errorSequence++;
      await until(() => !r.running);
      await r.retryDevice();
      await until(() => r.running);
      expect(api.applied.last.centerHz, 105300000);
      expect(api.applied.last.gainTenthsDb, 300);
      expect(api.calls, contains('rtlTcp:192.168.1.10:1234'));
    },
  );

  test(
    'selectUsbSource clears the network selection and returns to USB autostart',
    () async {
      final r = create(autoStart: true);
      source.devices = [];
      await r.refreshDevices();
      await r.selectNetworkSource('192.168.1.10', 1234);
      expect(r.networkSelected, isTrue);
      source.devices = [usbDevice];
      await r.selectUsbSource();
      expect(r.networkSelected, isFalse);
      await r.refreshDevices();
      await until(() => r.running);
      expect(r.selectedDevice?.id, 'test:1');
      expect(api.calls, contains('host:2:3:3'));
    },
  );

  test('sample-rate change is restricted to the rtl_tcp sample rate list', () async {
    final r = create(autoStart: false);
    await r.refreshDevices();
    await r.selectNetworkSource('192.168.1.10', 1234);
    await r.start();
    await until(() => r.running);
    final before = r.sampleRate;
    r.setSampleRate(999999); // not in the rtl_tcp list
    expect(r.sampleRate, before);
    r.setSampleRate(1920000); // in the rtl_tcp list
    expect(r.sampleRate, 1920000);
  });
}

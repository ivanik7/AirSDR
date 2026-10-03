// SPDX-License-Identifier: GPL-3.0-or-later
//
// Unit tests for HostIqRadioController against a fake SdrCoreV2Bindings +
// SdrCoreHostBindings implementation. No real native library involved: the
// fake enforces the same IDLE/OPEN/RUNNING state machine as sdrcore.h so a
// wrong call order from the controller fails here, not only against real
// hardware (test/platform/host_iq_hw_test.dart).
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/platform/linux/host_iq_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

/// RTL-SDR Blog V4 reports the generic RTL2832U OEM id (0bda:2838) that
/// isSupportedUsbSdr() recognizes via librtlsdr's known_devices[] table.
const int _rtlVid = 0x0bda;
const int _rtlPid = 0x2838;

SdrHostUsbDevice _device({
  int bus = 9,
  int address = 10,
  String? serial = 'SERIAL1',
  String path = '/dev/bus/usb/009/010',
}) => SdrHostUsbDevice(
  vendorId: _rtlVid,
  productId: _rtlPid,
  bus: bus,
  address: address,
  path: path,
  manufacturer: 'RTLSDRBlog',
  product: 'Blog V4',
  serial: serial,
);

class _FakeHandle {
  int state = SdrState.idle;
  int source = 0;
  int freq = 0;
  int rate = 0;
  int gain = 0;
  int lastError = 0;
}

/// Fake ABI 2 + host USB bindings with the same state-machine rules as the
/// real native core (native/include/sdrcore.h, sdrcore_host.h).
class FakeHostBindings
    implements SdrCoreBindings, SdrCoreV2Bindings, SdrCoreHostBindings {
  final List<SdrHostUsbDevice> devices = <SdrHostUsbDevice>[];
  final Set<String> accessDeniedPaths = <String>{};
  final List<String> calls = <String>[];
  final Map<int, _FakeHandle> _handles = <int, _FakeHandle>{};
  int _nextAddr = 1;
  int? _liveAddr;

  @override
  bool get hasHostUsb => true;

  @override
  int version() => 2;

  @override
  Pointer<SdrHandle> create() {
    final addr = _nextAddr++;
    _handles[addr] = _FakeHandle();
    _liveAddr = addr;
    calls.add('create');
    return Pointer<SdrHandle>.fromAddress(addr);
  }

  @override
  void destroy(Pointer<SdrHandle> handle) {
    _handles.remove(handle.address);
    if (_liveAddr == handle.address) _liveAddr = null;
    calls.add('destroy');
  }

  @override
  List<SdrHostUsbDevice> hostUsbList() => List<SdrHostUsbDevice>.of(devices);

  @override
  int hostOpenUsb(Pointer<SdrHandle> handle, int bus, int address, int source) {
    final h = _handles[handle.address];
    if (h == null) return SdrResult.invalidArgument;
    final dev = devices
        .where((d) => d.bus == bus && d.address == address)
        .firstOrNull;
    if (dev == null) return SdrResult.hostNotFound;
    if (accessDeniedPaths.contains(dev.path)) return SdrResult.hostAccessDenied;
    if (h.state != SdrState.idle) return SdrResult.invalidState;
    h.state = SdrState.open;
    h.source = source;
    calls.add('open:$bus:$address:$source');
    return SdrResult.ok;
  }

  @override
  int openUsb(Pointer<SdrHandle> handle, int fd, int source) =>
      SdrResult.unsupported;
  @override
  int openFile(Pointer<SdrHandle> handle, int fd, int rate) =>
      SdrResult.unsupported;
  @override
  int openSynthetic(Pointer<SdrHandle> handle, int rate) =>
      SdrResult.unsupported;

  @override
  int configure(Pointer<SdrHandle> handle, int freq, int rate, int gain) {
    final h = _handles[handle.address];
    if (h == null) return SdrResult.invalidArgument;
    if (h.state != SdrState.open) return SdrResult.invalidState;
    h.freq = freq;
    h.rate = rate;
    h.gain = gain;
    calls.add('configure:$freq:$rate:$gain');
    return SdrResult.ok;
  }

  @override
  int start(Pointer<SdrHandle> handle) {
    final h = _handles[handle.address];
    if (h == null) return SdrResult.invalidArgument;
    if (h.state != SdrState.open) return SdrResult.invalidState;
    h.state = SdrState.running;
    calls.add('start');
    return SdrResult.ok;
  }

  @override
  int stop(Pointer<SdrHandle> handle) {
    final h = _handles[handle.address];
    if (h == null) return SdrResult.invalidArgument;
    if (h.state != SdrState.running && h.state != SdrState.error) {
      return SdrResult.invalidState;
    }
    h.state = SdrState.open;
    calls.add('stop');
    return SdrResult.ok;
  }

  @override
  int close(Pointer<SdrHandle> handle) {
    final h = _handles[handle.address];
    if (h == null) return SdrResult.invalidArgument;
    if (h.state == SdrState.idle) return SdrResult.invalidState;
    h.state = SdrState.idle;
    calls.add('close');
    return SdrResult.ok;
  }

  @override
  SdrCoreStats stats(Pointer<SdrHandle> handle) {
    final h = _handles[handle.address];
    if (h == null) throw SdrCoreError(SdrResult.invalidArgument);
    return SdrCoreStats(
      h.state,
      h.source,
      0,
      0,
      0,
      h.lastError,
      h.rate,
      h.freq,
      h.gain,
      0,
    );
  }

  /// Puts the live (most recently created, not yet destroyed) handle into
  /// SDR_ERROR, as a real driver failure would.
  void injectError(int errorCode) {
    final addr = _liveAddr;
    if (addr == null) return;
    final h = _handles[addr]!;
    h.state = SdrState.error;
    h.lastError = errorCode;
  }

  int get destroyCount => calls.where((c) => c == 'destroy').length;
}

Future<void> _pumpUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) {
      fail('timed out waiting for condition (elapsed ${sw.elapsed})');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('HostIqRadioController', () {
    late FakeHostBindings fake;
    HostIqRadioController? controller;

    setUp(() {
      fake = FakeHostBindings();
    });

    tearDown(() {
      controller?.dispose();
      controller = null;
    });

    test('auto-starts on cold start with the expected native call order', () async {
      fake.devices.add(_device());
      controller = HostIqRadioController(
        core: SdrCore.withBindings(fake),
        pollInterval: const Duration(milliseconds: 20),
        statsInterval: const Duration(milliseconds: 20),
        retuneDebounce: const Duration(milliseconds: 20),
      );
      await _pumpUntil(() => controller!.running);
      expect(fake.calls, [
        'create',
        'open:9:10:3', // SdrSourceId.rtlsdr == 3
        'configure:100000000:2400000:200', // default 100 MHz / 2.4 MSPS / 20 dB
        'start',
      ]);
      expect(controller!.linkState, DeviceLinkState.receiving);
      expect(controller!.centerFrequency, 100000000);
      expect(controller!.vfoOffset, 0);
    });

    test('retune while running debounces to a single stop/configure/start and recenters', () async {
      fake.devices.add(_device());
      controller = HostIqRadioController(
        core: SdrCore.withBindings(fake),
        pollInterval: const Duration(seconds: 5),
        statsInterval: const Duration(milliseconds: 20),
        retuneDebounce: const Duration(milliseconds: 40),
      );
      await _pumpUntil(() => controller!.running);
      final before = fake.calls.length;

      // Two rapid updates simulate a drag; only the last should apply.
      controller!.setTuning(centerFrequency: 101000000, vfoOffset: 20000);
      controller!.setTuning(centerFrequency: 101000000, vfoOffset: 50000);
      // Immediate store+notify: UI sees the raw values right away.
      expect(controller!.centerFrequency, 101000000);
      expect(controller!.vfoOffset, 50000);

      await _pumpUntil(
        () => fake.calls.length > before,
        timeout: const Duration(seconds: 2),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(fake.calls.sublist(before), [
        'stop',
        'configure:101050000:2400000:200',
        'start',
      ]);
      // Recentered: AGENTS.md invariant (vfoOffset == 0 at rest).
      expect(controller!.centerFrequency, 101050000);
      expect(controller!.vfoOffset, 0);
      expect(controller!.running, isTrue);
    });

    test(
      'retune while stopped stores the value without any native call',
      () async {
        fake.devices.add(_device());
        controller = HostIqRadioController(
          core: SdrCore.withBindings(fake),
          autoStart: false,
          pollInterval: const Duration(seconds: 5),
          statsInterval: const Duration(seconds: 5),
          retuneDebounce: const Duration(milliseconds: 20),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(controller!.running, isFalse);
        expect(fake.calls, isEmpty);

        controller!.setTuning(centerFrequency: 95000000, vfoOffset: 1000);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(fake.calls, isEmpty);
        expect(controller!.centerFrequency, 95000000);
        expect(controller!.vfoOffset, 1000);
      },
    );

    test(
      'gain is clamped to the device range and restarts the session',
      () async {
        fake.devices.add(_device());
        controller = HostIqRadioController(
          core: SdrCore.withBindings(fake),
          pollInterval: const Duration(seconds: 5),
          statsInterval: const Duration(milliseconds: 20),
          retuneDebounce: const Duration(milliseconds: 30),
        );
        await _pumpUntil(() => controller!.running);
        final before = fake.calls.length;

        controller!.setGain(1000); // far above RTL-SDR's 49.6 dB max
        expect(controller!.gain, 49.6);

        await _pumpUntil(
          () => fake.calls.length > before,
          timeout: const Duration(seconds: 2),
        );
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(fake.calls.sublist(before), [
          'stop',
          'configure:100000000:2400000:496', // 49.6 dB * 10
          'start',
        ]);
      },
    );

    test('setSampleRate is ignored while running', () async {
      fake.devices.add(_device());
      controller = HostIqRadioController(
        core: SdrCore.withBindings(fake),
        pollInterval: const Duration(seconds: 5),
        statsInterval: const Duration(seconds: 5),
        retuneDebounce: const Duration(milliseconds: 20),
      );
      await _pumpUntil(() => controller!.running);
      final before = fake.calls.length;
      final rateBefore = controller!.sampleRate;

      controller!.setSampleRate(3200000);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(controller!.sampleRate, rateBefore);
      expect(fake.calls.length, before);
    });

    test('device vanishing while running disconnects and closes the session; '
        'reappearing restarts it once', () async {
      final dev = _device();
      fake.devices.add(dev);
      controller = HostIqRadioController(
        core: SdrCore.withBindings(fake),
        pollInterval: const Duration(milliseconds: 25),
        statsInterval: const Duration(milliseconds: 20),
        retuneDebounce: const Duration(milliseconds: 20),
      );
      await _pumpUntil(() => controller!.running);

      fake.devices.clear();
      await _pumpUntil(
        () => controller!.linkState == DeviceLinkState.disconnected,
      );
      expect(controller!.running, isFalse);
      expect(fake.calls.last, 'destroy');
      expect(fake.calls, containsAllInOrder(['stop', 'close', 'destroy']));

      final beforeReattach = fake.calls.length;
      fake.devices.add(dev); // same vid/pid/serial -> same stable id
      await _pumpUntil(() => controller!.running);
      expect(fake.calls.sublist(beforeReattach), [
        'create',
        'open:9:10:3',
        'configure:100000000:2400000:200',
        'start',
      ]);
    });

    test('native ERROR state (-5) disconnects the session', () async {
      fake.devices.add(_device());
      controller = HostIqRadioController(
        core: SdrCore.withBindings(fake),
        // Long hotplug poll: isolates the stats-driven disconnect from an
        // immediate automatic restart (the device is still in the list).
        pollInterval: const Duration(seconds: 30),
        statsInterval: const Duration(milliseconds: 15),
        retuneDebounce: const Duration(milliseconds: 20),
      );
      await _pumpUntil(() => controller!.running);

      fake.injectError(SdrResult.deviceGone);
      await _pumpUntil(
        () => controller!.linkState == DeviceLinkState.disconnected,
      );
      expect(controller!.running, isFalse);
      expect(fake.calls, containsAllInOrder(['stop', 'close', 'destroy']));
    });

    test(
      'user Stop sets stoppedByUser and is not auto-restarted by polling',
      () async {
        fake.devices.add(_device());
        controller = HostIqRadioController(
          core: SdrCore.withBindings(fake),
          pollInterval: const Duration(milliseconds: 20),
          statsInterval: const Duration(milliseconds: 20),
          retuneDebounce: const Duration(milliseconds: 20),
        );
        await _pumpUntil(() => controller!.running);

        await controller!.stop();
        expect(controller!.linkState, DeviceLinkState.stoppedByUser);
        expect(controller!.running, isFalse);
        final afterStop = fake.calls.length;

        // Several hotplug polls pass; nothing should restart automatically.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(fake.calls.length, afterStop);
        expect(controller!.linkState, DeviceLinkState.stoppedByUser);
      },
    );

    test(
      'access-denied open yields permissionDenied with a plugdev hint',
      () async {
        final dev = _device();
        fake.devices.add(dev);
        fake.accessDeniedPaths.add(dev.path);
        controller = HostIqRadioController(
          core: SdrCore.withBindings(fake),
          pollInterval: const Duration(milliseconds: 20),
          statsInterval: const Duration(milliseconds: 20),
          retuneDebounce: const Duration(milliseconds: 20),
        );
        await _pumpUntil(
          () => controller!.linkState == DeviceLinkState.permissionDenied,
        );
        expect(controller!.running, isFalse);
        expect(controller!.lastError, contains('plugdev'));

        // Known-bad device must not be retried on every poll tick.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(fake.calls.where((c) => c == 'create').length, 1);
      },
    );

    test('persists settings across instances via configDir', () async {
      final dir = Directory.systemTemp.createTempSync('host_iq_cfg_');
      addTearDown(() => dir.deleteSync(recursive: true));
      fake.devices.add(_device());

      controller = HostIqRadioController(
        core: SdrCore.withBindings(fake),
        configDir: dir.path,
        autoStart: false,
        pollInterval: const Duration(seconds: 5),
        statsInterval: const Duration(seconds: 5),
        retuneDebounce: const Duration(milliseconds: 10),
      );
      controller!.setTuning(centerFrequency: 92500000, vfoOffset: 0);
      controller!.setGain(30);
      controller!.setMode(DemodMode.nfm);
      controller!.setBandwidth(20000);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      controller!.dispose();

      final reloaded = HostIqRadioController(
        core: SdrCore.withBindings(FakeHostBindings()),
        configDir: dir.path,
        autoStart: false,
      );
      addTearDown(reloaded.dispose);
      expect(reloaded.centerFrequency, 92500000);
      expect(reloaded.gain, 30);
      expect(reloaded.mode, DemodMode.nfm);
      expect(reloaded.bandwidth, 20000);
      controller = null; // already disposed above
    });

    test('dispose releases the native handle exactly once', () async {
      fake.devices.add(_device());
      final c = HostIqRadioController(
        core: SdrCore.withBindings(fake),
        pollInterval: const Duration(milliseconds: 20),
        statsInterval: const Duration(milliseconds: 20),
        retuneDebounce: const Duration(milliseconds: 20),
      );
      await _pumpUntil(() => c.running);
      c.dispose();
      expect(fake.destroyCount, 1);
      expect(fake.calls.sublist(fake.calls.length - 3), [
        'stop',
        'close',
        'destroy',
      ]);
      controller = null;
    });

    test('tryCreate returns null without throwing when the host USB layer is absent', () {
      // SdrCore.open() on a non-Android/Linux target (or without the
      // library) throws; tryCreate must swallow that and return null.
      if (!Platform.isLinux) {
        expect(HostIqRadioController.tryCreate(), isNull);
      } else {
        // On Linux without SDRCORE_HOST_LIBRARY pointing at a real build,
        // DynamicLibrary.open('libsdrcore.so') is expected to fail too.
        expect(HostIqRadioController.tryCreate(), isNull);
      }
    });
  });
}

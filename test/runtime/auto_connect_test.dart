// SPDX-License-Identifier: GPL-3.0-or-later
// Auto-connect / hot re-plug / user Stop / cold-start mute of SdrRadioController (task
// t_3cfa7a1d), with the real DSP isolate, the real UsbDeviceProvider on a mocked Android USB
// plugin and a fake 'usb' source (fake_usb_source.dart) instead of the RTL/HackRF drivers.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/runtime/sdr_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';
import 'package:sdr_flutter/usb/android_usb.dart';
import 'package:sdr_flutter/usb/usb_device_provider.dart';

import 'fake_usb_source.dart';

Map<String, Object?> _dev(String name, int vid, int pid, [String? product]) =>
    <String, Object?>{
      'deviceName': name,
      'vid': vid,
      'pid': pid,
      'manufacturer': 'M',
      'product': product,
    };

final _rtl = _dev('/dev/bus/usb/001/002', 0x0bda, 0x2838, 'Blog V4');
final _rtlReplugged = _dev(
  '/dev/bus/usb/001/009',
  0x0bda,
  0x2838,
  'Blog V4',
); // new bus address
final _rtlOther = _dev(
  '/dev/bus/usb/001/010',
  0x0ccd,
  0x00d3,
  'Cinergy',
); // another known_devices[] entry
final _slowRtl = _dev('/dev/bus/usb/001/011', 0x0bda, 0x2838, 'Slow tuner');
final _hackrf = _dev('/dev/bus/usb/001/003', 0x1d50, 0x6089, 'HackRF One');
final _mouse = _dev('/dev/bus/usb/001/004', 0x046d, 0xc077);
final _airspy = _dev(
  '/dev/bus/usb/001/005',
  0x1d50,
  0x60a1,
); // known, but no driver

/// Mocked UsbSdrPlugin (Kotlin) on test channels.
class _FakePlugin {
  _FakePlugin(this.methods, this.events);

  final MethodChannel methods;
  final EventChannel events;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final List<Map<String, Object?>> devices = <Map<String, Object?>>[];
  final Set<String> deny = <String>{};
  final List<String> opens = <String>[];
  final List<String> closes = <String>[];
  Completer<void>? permissionResponse;
  Map<String, Object?>? initial;
  final StreamController<Object?> _events =
      StreamController<Object?>.broadcast();

  void install() {
    messenger.setMockMethodCallHandler(methods, (call) async {
      final args = call.arguments is Map
          ? (call.arguments as Map).cast<String, Object?>()
          : const <String, Object?>{};
      switch (call.method) {
        case 'listDevices':
          return devices;
        case 'open':
          final name = args['deviceName'] as String;
          opens.add(name);
          await permissionResponse?.future;
          final d = devices.where((e) => e['deviceName'] == name).firstOrNull;
          if (d == null) {
            throw PlatformException(
              code: 'NOT_FOUND',
              message: 'no device $name',
            );
          }
          if (deny.contains(name)) {
            throw PlatformException(
              code: 'PERMISSION_DENIED',
              message: 'denied',
            );
          }
          return <String, Object?>{
            'fd': 999999,
            'vid': d['vid'],
            'pid': d['pid'],
          };
        case 'close':
          closes.add(args['deviceName'] as String);
          return null;
        case 'hasPermission':
          return !deny.contains(args['deviceName']);
        case 'initialDevice':
          return initial;
      }
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (args, sink) => _events.stream.listen(sink.success),
      ),
    );
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
    _events.close();
  }

  void attach(Map<String, Object?> d) {
    devices.add(d);
    _events.add(<String, Object?>{'event': 'attached', 'device': d});
  }

  void detach(Map<String, Object?> d) {
    devices.removeWhere((e) => e['deviceName'] == d['deviceName']);
    _events.add(<String, Object?>{'event': 'detached', 'device': d});
  }

  /// A non-SDR device event (only makes the provider re-list, like a USB hub/mouse).
  void otherEvent() =>
      _events.add(<String, Object?>{'event': 'attached', 'device': _mouse});
}

// Generous: the first wait of a test includes spawning the DSP isolate, which takes several
// seconds when the full suite runs in parallel. Returns as soon as the condition holds.
String Function()? _describe; // current controller state, for timeout messages

Future<void> _until(
  bool Function() cond, {
  String? reason,
  int ms = 100000,
}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsedMilliseconds > ms) {
      fail(
        'timeout waiting for ${reason ?? 'condition'} (${_describe?.call() ?? ''})',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _settle([int ms = 300]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('test/autoconnect');
  const events = EventChannel('test/autoconnect/events');
  late _FakePlugin plugin;
  late Directory tmp;
  final controllers = <SdrRadioController>[];

  setUp(() {
    plugin = _FakePlugin(methods, events)..install();
    tmp = Directory.systemTemp.createTempSync('autoconnect');
  });

  tearDown(() async {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
    await _settle(50);
    plugin.uninstall();
    tmp.deleteSync(recursive: true);
  });

  SdrRadioController make() {
    final c = SdrRadioController(
      providers: <DeviceProvider>[
        UsbDeviceProvider(
          usb: AndroidUsb(methods: methods, events: events),
          enabled: true,
          abiSupported: true,
        ),
        SynthDeviceProvider(),
      ],
      options: DspEngineOptions(configDir: tmp.path, audio: 'null'),
      registerSources: registerFakeUsbSources,
      spawnTimeout: const Duration(seconds: 90),
    );

    controllers.add(c);
    _describe = () =>
        'link=${c.linkState} running=${c.running} device=${c.selectedDevice?.id} '
        'error=${c.lastError} opens=${plugin.opens} devices=${c.devices.map((d) => d.id).toList()}';
    return c;
  }

  test('cold start with a connected RTL-SDR: selected and receiving without Start, muted', () async {
    plugin.devices.addAll(<Map<String, Object?>>[_mouse, _rtl]);
    final c = make();
    await c.ready;
    await _until(() => c.running, reason: 'auto start');
    expect(c.selectedDevice?.id, 'usb:${_rtl['deviceName']}');
    expect(c.linkState, DeviceLinkState.receiving);
    expect(c.muted, isTrue, reason: 'cold start is muted');
    expect(plugin.opens, <String>[_rtl['deviceName'] as String]);
    await _settle();
    expect(c.lastState['muted'], isTrue);
    expect(c.lastState['sourceId'], 'usb');
  });

  test('auto-start centers a legacy persisted VFO offset without changing tuned frequency', () async {
    final old = DspEngine(
      (_) {},
      options: DspEngineOptions(configDir: tmp.path, audio: 'null'),
    );
    old.tune(center: 100000000, offset: 100000);
    expect(old.stateMap()['vfoOffset'], 100000);
    await old.shutdown();
    final restored = DspEngine(
      (_) {},
      options: DspEngineOptions(configDir: tmp.path, audio: 'null'),
    );
    expect(restored.stateMap()['vfoOffset'], 0);
    expect(restored.centerFrequency, 100100000);
    await restored.shutdown();
    final third = DspEngine(
      (_) {},
      options: DspEngineOptions(configDir: tmp.path, audio: 'null'),
    );
    expect(third.centerFrequency, 100100000);
    await third.shutdown();
    plugin.devices.add(_rtl);
    final c = make();
    await _until(() => c.running, reason: 'auto-start with old config');
    expect(
      c.centerFrequency,
      100100000,
      reason: 'state=${c.lastState} offset=${c.vfoOffset}',
    );
    expect(c.vfoOffset, 0);
    expect(c.tunedFrequency, c.centerFrequency);
    expect(c.lastState['vfoOffset'], 0);
  });

  test('HackRF is found by VID/PID; unsupported devices and the synth are never auto-picked', () async {
    plugin.devices.addAll(<Map<String, Object?>>[_mouse, _airspy, _hackrf]);
    final c = make();
    await _until(() => c.running, reason: 'auto start');
    expect(c.selectedDevice?.id, 'usb:${_hackrf['deviceName']}');
    expect(c.devices.map((d) => d.id), contains(SynthDeviceProvider.device.id));
  });

  test(
    'without any USB SDR: waits, synth stays manual, attach starts reception',
    () async {
      plugin.devices.add(_mouse);
      final c = make();
      await c.ready;
      await _settle();
      expect(c.running, isFalse);
      expect(c.linkState, DeviceLinkState.waiting);
      expect(plugin.opens, isEmpty);
      plugin.attach(_rtl);
      await _until(() => c.running, reason: 'start after attach');
      expect(c.selectedDevice?.id, 'usb:${_rtl['deviceName']}');
    },
  );

  test(
    'permission denied: clear status, no request loop, retry works',
    () async {
      plugin.devices.add(_rtl);
      plugin.deny.add(_rtl['deviceName'] as String);
      final c = make();
      await _until(
        () => c.linkState == DeviceLinkState.permissionDenied,
        reason: 'denied state',
      );
      expect(c.running, isFalse);
      expect(c.lastError, isNotNull);
      expect(plugin.opens.length, 1);
      // More USB traffic / manual refresh must not re-ask by itself.
      plugin.otherEvent();
      await c.refreshDevices();
      await _settle();
      expect(plugin.opens.length, 1, reason: 'no permission request loop');
      expect(c.linkState, DeviceLinkState.permissionDenied);
      // Retry button (user grants this time).
      plugin.deny.clear();
      await c.retryDevice();
      await _until(() => c.running, reason: 'running after retry');
      expect(plugin.opens.length, 2);
      expect(c.lastError, isNull);
    },
  );

  test(
    'permission denied, then the dongle is re-plugged: asks again and starts',
    () async {
      plugin.devices.add(_rtl);
      plugin.deny.add(_rtl['deviceName'] as String);
      final c = make();
      await _until(
        () => c.linkState == DeviceLinkState.permissionDenied,
        reason: 'denied state',
      );
      plugin.detach(_rtl);
      await _settle();
      plugin.deny.clear();
      plugin.attach(_rtlReplugged);
      await _until(() => c.running, reason: 'running after re-plug');
      expect(c.selectedDevice?.id, 'usb:${_rtlReplugged['deviceName']}');
    },
  );

  test('detach -> attach while receiving: resumes with the same settings and mute state', () async {
    plugin.devices.add(_rtl);
    final c = make();
    await _until(() => c.running, reason: 'auto start');
    await _settle();
    // User settings.
    c.setTuning(centerFrequency: 145500000, vfoOffset: 0);
    c.setMode(DemodMode.nfm);
    c.setBandwidth(20000);
    c.setSampleRate(1024000);
    c.setGain(33.8);
    c.setAgc(true);
    c.setVolume(0.35);
    c.setSquelchEnabled(true);
    c.setSquelchLevel(-42);
    c.setMuted(false);
    await _until(
      () => c.lastState['muted'] == false && c.lastState['agc'] == true,
      reason: 'settings applied',
    );
    await _settle();

    // Cable pulled: the source dies first (ENODEV), then Android reports the detach.
    c.setSourceSetting('simulateLoss', true);
    plugin.detach(_rtl);
    await _until(
      () => !c.running && c.linkState == DeviceLinkState.disconnected,
      reason: 'disconnected',
    );
    await _settle();
    expect(c.running, isFalse);
    expect(c.linkState, DeviceLinkState.disconnected);
    expect(c.lastState['running'], isFalse);
    // The DSP source of the lost dongle is disposed (no more ioctls on its dead fd; the audio
    // output is closed with it — see mute_lifecycle_test.dart). Kotlin closes the connection
    // itself on detach.
    expect(c.lastState['sourceId'], isNull);

    // Another supported RTL dongle on a new bus address.
    plugin.attach(_rtlOther);
    await _until(() => c.running, reason: 'resume after re-plug');
    expect(c.selectedDevice?.id, 'usb:${_rtlOther['deviceName']}');
    await _settle(500);
    expect(c.running, isTrue);
    expect(c.linkState, DeviceLinkState.receiving);
    expect(c.centerFrequency, 145500000);
    expect(c.vfoOffset, 0);
    expect(c.tunedFrequency, c.centerFrequency);
    expect(c.mode, DemodMode.nfm);
    expect(c.bandwidth, 20000);
    expect(c.sampleRate, 1024000);
    expect(c.gain, closeTo(33.8, 1e-9));
    expect(c.agc, isTrue);
    expect(c.volume, closeTo(0.35, 1e-9));
    expect(c.squelchEnabled, isTrue);
    expect(c.squelchLevel, -42);
    expect(
      c.muted,
      isFalse,
      reason: 'unmuted before the loss -> unmuted after',
    );
    // Same values really are in the DSP isolate / new source, not only in the UI snapshot.
    expect(c.lastState['centerFreq'], 145500000);
    expect(c.lastState['sampleRate'], 1024000);
    expect(c.lastState['gain'], closeTo(33.8, 1e-9));
    expect(c.lastState['agc'], isTrue);
    expect(c.lastState['muted'], isFalse);
    expect(c.lastError, isNull);
  });

  test('detach event alone (no ENODEV first) also stops cleanly; muted stays muted after re-plug', () async {
    plugin.devices.add(_rtl);
    final c = make();
    await _until(() => c.running, reason: 'auto start');
    plugin.detach(_rtl);
    await _until(
      () => c.linkState == DeviceLinkState.disconnected,
      reason: 'disconnected',
    );
    expect(c.running, isFalse);
    expect(
      c.selectedDevice,
      isNull,
      reason: 'the synth is not picked in place of the lost dongle',
    );
    plugin.attach(_rtl);
    await _until(() => c.running, reason: 'resume');
    await _settle();
    expect(c.muted, isTrue);
    expect(c.lastState['muted'], isTrue);
  });

  test('user Stop: no automatic restart until Start or a new attach', () async {
    plugin.devices.add(_rtl);
    final c = make();
    await _until(() => c.running, reason: 'auto start');
    await c.stop();
    expect(c.linkState, DeviceLinkState.stoppedByUser);
    await c.refreshDevices();
    plugin.otherEvent();
    await _settle();
    expect(
      c.running,
      isFalse,
      reason: 'refresh / unrelated USB events do not restart',
    );
    await c.retryDevice();
    await _settle();
    expect(c.running, isFalse, reason: 'retry is not Start');

    // Explicit Start.
    await c.start();
    expect(c.running, isTrue);

    // Stop, then the cable is re-plugged: a new connection starts reception again.
    await c.stop();
    plugin.detach(_rtl);
    await _settle();
    expect(c.running, isFalse);
    expect(c.linkState, DeviceLinkState.stoppedByUser);
    plugin.attach(_rtl);
    await _until(() => c.running, reason: 'start after new attach');
  });

  test(
    'Stop during the permission dialog releases the fd and does not auto-start',
    () async {
      plugin.devices.add(_rtl);
      plugin.permissionResponse = Completer<void>();
      final c = make();
      await _until(
        () => plugin.opens.isNotEmpty,
        reason: 'pending permission request',
      );
      final permissionResponse = plugin.permissionResponse!;
      final stopping = c.stop();
      permissionResponse.complete();
      await stopping;
      await _until(
        () => plugin.closes.isNotEmpty,
        reason: 'released after cancelled permission',
      );
      expect(c.running, isFalse);
      expect(c.linkState, DeviceLinkState.stoppedByUser);
      await c.refreshDevices();
      expect(c.running, isFalse);
    },
  );

  test(
    'Stop during tuner startup does not leave the DSP or audio running',
    () async {
      plugin.devices.add(_slowRtl);
      final c = make();
      await _until(
        () => c.lastState['sourceId'] == 'usb',
        reason: 'source selected',
      );
      await c.stop();
      await _settle(700);
      expect(c.running, isFalse);
      expect(
        c.lastState['running'],
        isFalse,
        reason: 'DSP must be stopped too, not just the UI',
      );
      expect(c.linkState, DeviceLinkState.stoppedByUser);
    },
  );

  test(
    'mute is per session: a new controller on the same config starts muted',
    () async {
      plugin.devices.add(_rtl);
      final c = make();
      await _until(() => c.running, reason: 'auto start');
      c.setMuted(false);
      c.setVolume(0.6);
      await _until(() => c.lastState['muted'] == false, reason: 'unmuted');
      controllers.remove(c);
      c.dispose();
      await _settle(500);

      final c2 = make();
      await c2.ready;
      expect(c2.muted, isTrue);
      await _until(() => c2.running, reason: 'auto start 2');
      await _settle();
      expect(c2.muted, isTrue);
      expect(c2.lastState['muted'], isTrue);
      expect(
        c2.volume,
        closeTo(0.6, 1e-9),
        reason: 'volume is persisted, mute is not',
      );
    },
  );
}

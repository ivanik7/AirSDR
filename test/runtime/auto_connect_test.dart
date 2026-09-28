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

import 'fake_usb_plugin.dart';
import 'fake_usb_source.dart';

typedef _FakePlugin = FakeUsbPlugin;
final _rtl = fakeRtl;
final _rtlReplugged = fakeRtlReplugged;
final _rtlOther = fakeRtlOther;
final _slowRtl = fakeSlowRtl;
final _hackrf = fakeHackrf;
final _mouse = fakeMouse;
final _airspy = fakeAirspy;

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

  // Phone QA: a physical unplug showed a red DropdownButton assertion ("There should be
  // exactly one item with [DropdownButton]'s value") — the controller notified listeners
  // while selectedDevice still was the vanished dongle but devices no longer listed it.
  test('selectedDevice is always one of devices (or null) at every notification during unplug/re-plug', () async {
    plugin.devices.add(_rtl);
    final c = make();
    final violations = <String>[];
    c.addListener(() {
      final d = c.selectedDevice;
      if (d != null && !c.devices.contains(d)) {
        violations.add(
          'selected=${d.id} devices=${c.devices.map((e) => e.id).toList()} link=${c.linkState}',
        );
      }
    });
    await _until(() => c.running, reason: 'auto start');
    await _settle();

    // Cable pulled: ENODEV from the stream first, then the detach broadcast.
    c.setSourceSetting('simulateLoss', true);
    await _settle(50);
    plugin.detach(_rtl);
    await _until(
      () => c.linkState == DeviceLinkState.disconnected && c.selectedDevice == null,
      reason: 'disconnected',
    );
    // Stats / state events keep arriving while the device is gone.
    await _settle(700);
    plugin.attach(_rtlReplugged);
    await _until(() => c.running, reason: 'resume after re-plug');
    // Detach without a preceding ENODEV (the other order seen on the phone).
    plugin.detach(_rtlReplugged);
    await _until(
      () => c.linkState == DeviceLinkState.disconnected && c.selectedDevice == null,
      reason: 'disconnected 2',
    );
    await _settle(700);
    plugin.attach(_rtl);
    await _until(() => c.running, reason: 'resume 2');
    expect(c.selectedDevice?.id, 'usb:${_rtl['deviceName']}');
    expect(violations, isEmpty);
  });

  test('a vanished device cannot be selected manually from a stale menu', () async {
    plugin.devices.add(_rtl);
    final c = make();
    await _until(() => c.running, reason: 'auto start');
    await c.stop();
    final stale = c.selectedDevice!;
    plugin.detach(_rtl);
    await _until(() => c.selectedDevice == null, reason: 'deselected');
    await c.selectDevice(stale);
    await _settle();
    expect(c.selectedDevice, isNull);
    expect(plugin.opens, <String>[_rtl['deviceName'] as String]);
  });

  // Phone logs: a loose OTG plug bounced attach/detach every few seconds. Each attach is a
  // new connection (one open), each detach tears it down; the controller must follow without
  // errors in the invariant and settle on the last state.
  test('bouncing cable: one open per attach, ends consistent', () async {
    plugin.devices.add(_rtl);
    final c = make();
    await _until(() => c.running, reason: 'auto start');
    final bad = <String>[];
    c.addListener(() {
      final d = c.selectedDevice;
      if (d != null && !c.devices.contains(d)) bad.add(d.id);
    });
    for (var i = 0; i < 5; i++) {
      plugin.detach(_rtl);
      await _settle(20 + 30 * i);
      plugin.attach(_rtl);
      await _settle(20 + 30 * i);
    }
    await _until(() => c.running, reason: 'running after the bouncing stopped');
    await _settle(500);
    expect(bad, isEmpty);
    expect(c.selectedDevice?.id, 'usb:${_rtl['deviceName']}');
    expect(plugin.opens.length, lessThanOrEqualTo(6));
    plugin.detach(_rtl);
    await _until(
      () => c.linkState == DeviceLinkState.disconnected,
      reason: 'final detach',
    );
    await _settle(500);
    final n = plugin.opens.length;
    await _settle(1000);
    expect(plugin.opens.length, n, reason: 'no start attempts while unplugged');
    expect(c.running, isFalse);
  });

  test('device lost without a detach (ENODEV only): one stop, no start loop', () async {
    plugin.devices.add(_rtl);
    final c = make();
    await _until(() => c.running, reason: 'auto start');
    await _settle();
    c.setSourceSetting('simulateLoss', true);
    await _until(
      () => c.linkState == DeviceLinkState.disconnected,
      reason: 'disconnected',
    );
    plugin.otherEvent();
    await c.refreshDevices();
    await _settle(1500);
    expect(c.running, isFalse);
    expect(c.linkState, DeviceLinkState.disconnected);
    expect(plugin.opens.length, 1, reason: 'no automatic reopen loop on the lost device');
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

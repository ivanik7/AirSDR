// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/background_reception.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('sdr/background');
  final calls = <MethodCall>[];
  late DemoRadioController radio;
  late BackgroundReception bridge;

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    radio = DemoRadioController();
    bridge = BackgroundReception(
      radio,
      channel: channel,
      updateInterval: const Duration(milliseconds: 100),
    );
  });
  tearDown(() async {
    bridge.dispose();
    await radio.stop();
    radio.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('native controller owns foreground promotion and release', () async {
    await radio.start();
    await flush();
    expect(calls, isEmpty);
    await radio.stop();
    await flush();
    expect(calls, isEmpty);
  });

  test('notification Stop calls radio.stop and permits restart', () async {
    await radio.start();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'sdr/background',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('stopReception'),
          ),
          (_) {},
        );
    await flush();
    expect(radio.running, false);
    expect(calls, isEmpty);
    await radio.start();
    expect(radio.running, true);
  });

  test('rapid retunes coalesce notification updates', () async {
    await radio.start();
    radio.setTuning(centerFrequency: 101000000, vfoOffset: 0);
    radio.setTuning(centerFrequency: 102000000, vfoOffset: 0);
    radio.setTuning(centerFrequency: 103000000, vfoOffset: 0);
    radio.setMode(DemodMode.nfm);
    await flush();
    expect(calls, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 130));
    expect(calls.map((c) => c.method), ['update']);
    expect(calls.single.arguments, {'frequency': 103000000, 'mode': 'NFM'});
  });

  test(
    'failed notification update does not stop the native receiver',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            throw PlatformException(code: 'NO_SERVICE');
          });
      await radio.start();
      radio.setTuning(centerFrequency: 101000000, vfoOffset: 0);
      await Future<void>.delayed(const Duration(milliseconds: 130));
      await flush();
      expect(radio.running, true);
      expect(calls.map((c) => c.method), ['update']);
    },
  );

  test('asynchronous service failure stops the native receiver', () async {
    await radio.start();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'sdr/background',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('serviceFailed'),
          ),
          (_) {},
        );
    await flush();
    expect(radio.running, false);
    expect(calls, isEmpty);
  });
}

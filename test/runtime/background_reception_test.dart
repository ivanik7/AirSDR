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

  test('idle has no service; start and UI stop mirror reception', () async {
    await flush();
    expect(calls, isEmpty);
    await radio.start();
    await flush();
    expect(calls.map((c) => c.method), ['start']);
    expect(calls.single.arguments, {'frequency': 100000000, 'mode': 'WFM'});
    await radio.stop();
    await flush();
    expect(calls.map((c) => c.method), ['start', 'stop']);
  });

  test(
    'notification Stop uses same controller path, and restart works',
    () async {
      await radio.start();
      await flush();
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
      expect(calls.map((c) => c.method), ['start', 'stop']);
      await radio.start();
      await flush();
      expect(calls.last.method, 'start');
    },
  );

  test(
    'rapid retunes are coalesced; mode and final frequency delivered',
    () async {
      await radio.start();
      await flush();
      radio.setTuning(centerFrequency: 101000000, vfoOffset: 0);
      radio.setTuning(centerFrequency: 102000000, vfoOffset: 0);
      radio.setTuning(centerFrequency: 103000000, vfoOffset: 0);
      radio.setMode(DemodMode.nfm);
      await flush();
      expect(calls.length, 1);
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(calls.map((c) => c.method), ['start', 'update']);
      expect(calls.last.arguments, {'frequency': 103000000, 'mode': 'NFM'});
    },
  );

  test(
    'native service failure does not prevent stopping the receiver',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'start') {
              throw PlatformException(code: 'NO_SERVICE');
            }
            return null;
          });
      await radio.start();
      await flush();
      expect(radio.running, false);
      expect(calls.map((c) => c.method), ['start', 'stop']);
    },
  );

  test(
    'asynchronous foreground promotion failure stops the receiver',
    () async {
      await radio.start();
      await flush();
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
      expect(calls.map((c) => c.method), ['start', 'stop']);
    },
  );
}

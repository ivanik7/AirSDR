// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/platform/media_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('sdr/media');
  final calls = <MethodCall>[];
  late AndroidMediaStore store;

  setUp(() {
    calls.clear();
    store = AndroidMediaStore(channel: channel);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void setHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  test('invokes saveImage with exact arguments and defaults applied', () async {
    setHandler((call) async => 'Pictures/AirSDR/SSTV-1.png');
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    final location = await store.saveImage(
      bytes: bytes,
      displayName: 'SSTV-1.png',
    );

    expect(location, 'Pictures/AirSDR/SSTV-1.png');
    expect(calls, hasLength(1));
    expect(calls.single.method, 'saveImage');
    final args = calls.single.arguments as Map<Object?, Object?>;
    expect(args['bytes'], bytes);
    expect(args['displayName'], 'SSTV-1.png');
    expect(args['mimeType'], 'image/png');
    expect(args['album'], 'AirSDR');
  });

  test('passes through explicit mimeType and album', () async {
    setHandler((call) async => 'Pictures/Custom/img.jpg');

    final location = await store.saveImage(
      bytes: Uint8List.fromList([9]),
      displayName: 'img.jpg',
      mimeType: 'image/jpeg',
      album: 'Custom',
    );

    expect(location, 'Pictures/Custom/img.jpg');
    final args = calls.single.arguments as Map<Object?, Object?>;
    expect(args['mimeType'], 'image/jpeg');
    expect(args['album'], 'Custom');
  });

  test('null platform result throws StateError', () async {
    setHandler((call) async => null);

    expect(
      () =>
          store.saveImage(bytes: Uint8List.fromList([1]), displayName: 'a.png'),
      throwsA(isA<StateError>()),
    );
  });

  test('empty platform result throws StateError', () async {
    setHandler((call) async => '');

    expect(
      () =>
          store.saveImage(bytes: Uint8List.fromList([1]), displayName: 'a.png'),
      throwsA(isA<StateError>()),
    );
  });

  test('PlatformException from the channel propagates', () async {
    setHandler((call) async => throw PlatformException(code: 'save_failed'));

    expect(
      () =>
          store.saveImage(bytes: Uint8List.fromList([1]), displayName: 'a.png'),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'empty bytes throws ArgumentError without calling the channel',
    () async {
      setHandler((call) async => 'should not be reached');

      expect(
        () => store.saveImage(bytes: Uint8List(0), displayName: 'a.png'),
        throwsA(isA<ArgumentError>()),
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'empty displayName throws ArgumentError without calling the channel',
    () async {
      setHandler((call) async => 'should not be reached');

      expect(
        () => store.saveImage(bytes: Uint8List.fromList([1]), displayName: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(calls, isEmpty);
    },
  );

  test('displayName with a forward slash throws ArgumentError without calling the channel', () async {
    setHandler((call) async => 'should not be reached');

    expect(
      () => store.saveImage(
        bytes: Uint8List.fromList([1]),
        displayName: 'sub/dir.png',
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(calls, isEmpty);
  });

  test('displayName with a backslash throws ArgumentError without calling the channel', () async {
    setHandler((call) async => 'should not be reached');

    expect(
      () => store.saveImage(
        bytes: Uint8List.fromList([1]),
        displayName: 'sub\\dir.png',
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(calls, isEmpty);
  });
}

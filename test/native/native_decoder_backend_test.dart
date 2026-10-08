// SPDX-License-Identifier: GPL-3.0-or-later
// Pure-Dart tests of the DecoderBackend adapter, independent of any real
// native library. Verifies contract compliance: no fabricated availability,
// safe handling of an absent/closed handle, correct event mapping.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_decoder_api.dart';
import 'package:sdr_flutter/native/native_decoder_backend.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';

class FakeDecoderApi implements NativeDecoderApi {
  final descriptorsList = <NativeDecoderDescriptor>[];
  final selectCalls = <(Pointer<SdrHandle>, String?, String)>[];
  bool selectResult = true;
  NativeDecoderEvent? nextEvent;
  final pollCalls = <int>[];

  @override
  List<NativeDecoderDescriptor> descriptors() => descriptorsList;

  @override
  bool select(Pointer<SdrHandle> handle, String? id, String configJson) {
    selectCalls.add((handle, id, configJson));
    return selectResult;
  }

  @override
  NativeDecoderEvent? poll(Pointer<SdrHandle> handle, int afterSequence) {
    pollCalls.add(afterSequence);
    return nextEvent;
  }
}

void main() {
  group('NoDecoderBackend', () {
    test('reports no available ids and never fabricates support', () {
      const backend = NoDecoderBackend();
      expect(backend.availableIds, isEmpty);
    });
    test('deselect (null/empty id) trivially succeeds', () {
      const backend = NoDecoderBackend();
      expect(backend.select(null, const {}), isTrue);
      expect(backend.select('', const {}), isTrue);
    });
    test('selecting a real id fails', () {
      const backend = NoDecoderBackend();
      expect(backend.select('sstv', const {}), isFalse);
    });
    test('poll never yields an event', () {
      const backend = NoDecoderBackend();
      expect(backend.poll(0), isNull);
    });
  });

  group('NativeDecoderBackend', () {
    late FakeDecoderApi api;
    Pointer<SdrHandle>? handle;

    setUp(() {
      api = FakeDecoderApi();
      handle = null;
    });

    NativeDecoderBackend backend() => NativeDecoderBackend(api, () => handle);

    test('availableIds reflects only descriptors reporting available=true', () {
      api.descriptorsList.addAll([
        const NativeDecoderDescriptor(
          id: 'sstv',
          input: 1,
          exclusiveReceiver: false,
          requiredMode: 4,
          requiredRateHz: 24000,
          result: 3,
          available: true,
        ),
        const NativeDecoderDescriptor(
          id: 'adsb',
          input: 4,
          exclusiveReceiver: true,
          requiredMode: null,
          requiredRateHz: 2400000,
          result: 4,
          available: false, // Installed in the registry, but not built.
        ),
      ]);
      expect(backend().availableIds, {'sstv'});
    });

    test('availableIds is fetched once (registry is static per process)', () {
      final b = backend();
      api.descriptorsList.add(
        const NativeDecoderDescriptor(
          id: 'sstv',
          input: 1,
          exclusiveReceiver: false,
          requiredMode: 4,
          requiredRateHz: 24000,
          result: 3,
          available: true,
        ),
      );
      expect(b.availableIds, {'sstv'});
      api.descriptorsList.clear();
      expect(b.availableIds, {'sstv'}, reason: 'cached after first read');
    });

    test('select with no open handle: deselect succeeds, real id fails, '
        'native select is never called', () {
      final b = backend();
      expect(b.select(null, const {}), isTrue);
      expect(b.select('sstv', const {}), isFalse);
      expect(api.selectCalls, isEmpty);
    });

    test('select rejects an id absent from the available registry without '
        'calling into native', () {
      handle = Pointer<SdrHandle>.fromAddress(7);
      api.descriptorsList.add(
        const NativeDecoderDescriptor(
          id: 'sstv',
          input: 1,
          exclusiveReceiver: false,
          requiredMode: 4,
          requiredRateHz: 24000,
          result: 3,
          available: false,
        ),
      );
      final b = backend();
      expect(b.select('sstv', const {}), isFalse);
      expect(api.selectCalls, isEmpty);
    });

    test('select with an open handle forwards id and JSON-encoded config', () {
      handle = Pointer<SdrHandle>.fromAddress(7);
      api.descriptorsList.add(
        const NativeDecoderDescriptor(
          id: 'sstv',
          input: 1,
          exclusiveReceiver: false,
          requiredMode: 4,
          requiredRateHz: 24000,
          result: 3,
          available: true,
        ),
      );
      final b = backend();
      expect(b.select('sstv', const {'mode': 'auto'}), isTrue);
      expect(api.selectCalls.single.$2, 'sstv');
      expect(api.selectCalls.single.$3, '{"mode":"auto"}');
    });

    test('select deselect with an open handle still forwards null id', () {
      handle = Pointer<SdrHandle>.fromAddress(7);
      final b = backend();
      expect(b.select(null, const {}), isTrue);
      expect(api.selectCalls.single.$2, isNull);
    });

    test('poll with no open handle returns null without calling native', () {
      final b = backend();
      expect(b.poll(0), isNull);
      expect(api.pollCalls, isEmpty);
    });

    test('poll maps a native event to the Dart DecoderEvent contract', () {
      handle = Pointer<SdrHandle>.fromAddress(7);
      api.nextEvent = NativeDecoderEvent(
        sequence: 5,
        streamGeneration: 2,
        kind: 3, // SDR_DECODER_IMAGE_COMPLETE
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final b = backend();
      final event = b.poll(4);
      expect(event, isNotNull);
      expect(event!.sequence, 5);
      expect(event.streamGeneration, 2);
      expect(event.kind, DecoderResult.imageComplete);
      expect(event.payload, [1, 2, 3]);
      expect(api.pollCalls, [4]);
    });

    test('poll never fabricates a DecoderResult for an unknown native kind', () {
      handle = Pointer<SdrHandle>.fromAddress(7);
      api.nextEvent = NativeDecoderEvent(
        sequence: 1,
        streamGeneration: 1,
        kind: 999,
        payload: Uint8List.fromList(const []),
      );
      final b = backend();
      expect(b.poll(0), isNull);
    });

    test('poll passes NO_DATA through as null', () {
      handle = Pointer<SdrHandle>.fromAddress(7);
      api.nextEvent = null;
      final b = backend();
      expect(b.poll(10), isNull);
      expect(api.pollCalls, [10]);
    });
  });
}

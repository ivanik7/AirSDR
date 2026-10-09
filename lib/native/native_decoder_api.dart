// SPDX-License-Identifier: GPL-3.0-or-later
// Additive decoder extension on top of ABI v3. C layout:
// native/include/sdrcore_decoder_v1.h. Never routes IQ/PCM to Dart; only
// bounded typed events (JSON or small image segments) cross this boundary.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'sdr_core.dart';

/// native/include/sdrcore_decoder_v1.h SDR_DECODER_REVISION.
const sdrDecoderRevision = 1;

/// native/include/sdrcore_decoder_v1.h SDR_DECODER_MAX_PAYLOAD.
const sdrDecoderMaxPayload = 65536;

/// native/include/sdrcore_decoder_v1.h SDR_DECODER_NO_DATA.
const _sdrDecoderNoData = 1;

/// One registry entry reported by `sdr_decoder_descriptor`. Static metadata
/// is not availability by itself; only [available] means an installed
/// backend. `requiredMode`/`requiredRateHz` are null for the header's
/// UINT32_MAX/0 "independent/backend-dependent" sentinels.
final class NativeDecoderDescriptor {
  const NativeDecoderDescriptor({
    required this.id,
    required this.input,
    required this.exclusiveReceiver,
    required this.requiredMode,
    required this.requiredRateHz,
    required this.result,
    required this.available,
  });
  final String id;
  final int input;
  final bool exclusiveReceiver;
  final int? requiredMode;
  final int? requiredRateHz;
  final int result;
  final bool available;
}

/// One bounded event copied out of `sdr_decoder_poll`. [payload] is a
/// defensive copy, never a borrowed native pointer.
final class NativeDecoderEvent {
  const NativeDecoderEvent({
    required this.sequence,
    required this.streamGeneration,
    required this.kind,
    required this.payload,
    this.droppedEvents = 0,
  });
  final int sequence;
  final int streamGeneration;
  final int kind;
  final Uint8List payload;
  final int droppedEvents;
}

/// Dart surface of the optional sdrcore_decoder_v1 extension. A null
/// instance (see [FfiNativeDecoderApi.tryOpen]) means "not supported by
/// this native core"; callers must never fabricate availability.
abstract interface class NativeDecoderApi {
  /// Full registry, including entries with `available == false`.
  List<NativeDecoderDescriptor> descriptors();

  /// Only an id whose descriptor reports `available == true` may succeed;
  /// null/empty id deselects. `configJson` is UTF-8 JSON, schema versioned
  /// by decoder id. A failed select leaves the receiver, audio, prior
  /// decoder and tuning unchanged (native contract).
  bool select(Pointer<SdrHandle> handle, String? id, String configJson);

  /// Oldest queued event strictly newer than [afterSequence], or null for
  /// NO_DATA / any failure. Never retains a native pointer.
  NativeDecoderEvent? poll(Pointer<SdrHandle> handle, int afterSequence);
}

/// Additive native RDS control, independent of the selectable decoder ABI.
abstract interface class NativeRbdsControl {
  bool get rbdsAvailable;
  bool setRbds(Pointer<SdrHandle> handle, bool enabled);
}

// C layout: native/include/sdrcore_decoder_v1.h SdrDecoderDescriptor.
final class _Descriptor extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int revision;
  @Array(32)
  external Array<Uint8> id;
  @Uint32()
  external int input;
  @Uint32()
  external int exclusiveReceiver;
  @Uint32()
  external int requiredMode;
  @Uint32()
  external int requiredRateHz;
  @Uint32()
  external int result;
  @Uint32()
  external int available;
}

// C layout: native/include/sdrcore_decoder_v1.h SdrDecoderEvent.
final class _Event extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int revision;
  @Uint64()
  external int sequence;
  @Uint64()
  external int streamGeneration;
  @Uint32()
  external int kind;
  @Uint32()
  external int payloadBytes;
  @Uint64()
  external int droppedEvents;
}

String _idText(Array<Uint8> data) {
  final bytes = <int>[];
  for (var i = 0; i < 32 && data[i] != 0; i++) {
    bytes.add(data[i]);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Resolved only when every `sdr_decoder_*` symbol exists and
/// `sdr_decoder_version()` matches [sdrDecoderRevision]; otherwise the
/// optional extension is treated as absent (see [tryOpen]).
final class FfiNativeDecoderApi implements NativeDecoderApi, NativeRbdsControl {
  FfiNativeDecoderApi._(this._lib);

  final DynamicLibrary _lib;

  @override
  bool get rbdsAvailable => _lib.providesSymbol('sdr_rds_set_rbds');

  @override
  bool setRbds(Pointer<SdrHandle> handle, bool enabled) {
    if (!rbdsAvailable) return false;
    final call = _lib
        .lookupFunction<
          Int32 Function(Pointer<SdrHandle>, Uint32),
          int Function(Pointer<SdrHandle>, int)
        >('sdr_rds_set_rbds');
    return call(handle, enabled ? 1 : 0) == 0;
  }

  /// Exact ABI sizes verified against native/include/sdrcore_decoder_v1.h.
  static List<int> get layoutSizes => [sizeOf<_Descriptor>(), sizeOf<_Event>()];

  /// Returns null without throwing when the decoder extension is missing
  /// or at an incompatible revision; required ABI v3 symbols are never
  /// probed here (see [FfiNativeRadioApi] for that contract).
  static NativeDecoderApi? tryOpen(DynamicLibrary library) {
    if (!library.providesSymbol('sdr_decoder_version')) return null;
    final int Function() version = library
        .lookupFunction<Uint32 Function(), int Function()>(
          'sdr_decoder_version',
        );
    if (version() != sdrDecoderRevision) return null;
    for (final symbol in const <String>[
      'sdr_decoder_count',
      'sdr_decoder_descriptor',
      'sdr_decoder_select',
      'sdr_decoder_poll',
    ]) {
      if (!library.providesSymbol(symbol)) return null;
    }
    return FfiNativeDecoderApi._(library);
  }

  late final int Function(Pointer<Uint32>) _count = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint32>),
        int Function(Pointer<Uint32>)
      >('sdr_decoder_count');
  late final int Function(int, Pointer<_Descriptor>) _descriptor = _lib
      .lookupFunction<
        Int32 Function(Uint32, Pointer<_Descriptor>),
        int Function(int, Pointer<_Descriptor>)
      >('sdr_decoder_descriptor');
  late final int Function(
    Pointer<SdrHandle>,
    Pointer<Uint8>,
    int,
    Pointer<Uint8>,
    int,
  )
  _select = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<SdrHandle>,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint8>,
          Uint32,
        ),
        int Function(
          Pointer<SdrHandle>,
          Pointer<Uint8>,
          int,
          Pointer<Uint8>,
          int,
        )
      >('sdr_decoder_select');
  late final int Function(
    Pointer<SdrHandle>,
    int,
    Pointer<_Event>,
    Pointer<Uint8>,
    int,
  )
  _poll = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<SdrHandle>,
          Uint64,
          Pointer<_Event>,
          Pointer<Uint8>,
          Uint32,
        ),
        int Function(
          Pointer<SdrHandle>,
          int,
          Pointer<_Event>,
          Pointer<Uint8>,
          int,
        )
      >('sdr_decoder_poll');

  @override
  List<NativeDecoderDescriptor> descriptors() {
    final countPtr = calloc<Uint32>();
    try {
      if (_count(countPtr) != 0) return const [];
      final n = countPtr.value;
      // Sanity guard against a malformed/hostile native registry; never
      // fabricate entries beyond what count-only probing could plausibly be.
      if (n == 0 || n > 4096) return const [];
      final descPtr = calloc<_Descriptor>();
      try {
        final list = <NativeDecoderDescriptor>[];
        for (var i = 0; i < n; i++) {
          descPtr.ref.size = sizeOf<_Descriptor>();
          descPtr.ref.revision = sdrDecoderRevision;
          if (_descriptor(i, descPtr) != 0) continue;
          final d = descPtr.ref;
          list.add(
            NativeDecoderDescriptor(
              id: _idText(d.id),
              input: d.input,
              exclusiveReceiver: d.exclusiveReceiver != 0,
              requiredMode: d.requiredMode == 0xFFFFFFFF
                  ? null
                  : d.requiredMode,
              requiredRateHz: d.requiredRateHz == 0 ? null : d.requiredRateHz,
              result: d.result,
              available: d.available != 0,
            ),
          );
        }
        return list;
      } finally {
        calloc.free(descPtr);
      }
    } finally {
      calloc.free(countPtr);
    }
  }

  @override
  bool select(Pointer<SdrHandle> handle, String? id, String configJson) {
    final idBytes = (id == null || id.isEmpty) ? null : utf8.encode(id);
    if (idBytes != null && idBytes.length > 31) return false;
    final configBytes = utf8.encode(configJson);
    if (configBytes.length > sdrDecoderMaxPayload) return false;
    final idPtr = idBytes == null
        ? nullptr.cast<Uint8>()
        : calloc<Uint8>(idBytes.length);
    final configPtr = configBytes.isEmpty
        ? nullptr.cast<Uint8>()
        : calloc<Uint8>(configBytes.length);
    try {
      if (idBytes != null) idPtr.asTypedList(idBytes.length).setAll(0, idBytes);
      if (configBytes.isNotEmpty) {
        configPtr.asTypedList(configBytes.length).setAll(0, configBytes);
      }
      final code = _select(
        handle,
        idPtr,
        idBytes?.length ?? 0,
        configPtr,
        configBytes.length,
      );
      return code == 0;
    } finally {
      if (idBytes != null) calloc.free(idPtr);
      if (configBytes.isNotEmpty) calloc.free(configPtr);
    }
  }

  @override
  NativeDecoderEvent? poll(Pointer<SdrHandle> handle, int afterSequence) {
    final evPtr = calloc<_Event>();
    final payload = calloc<Uint8>(sdrDecoderMaxPayload);
    try {
      evPtr.ref.size = sizeOf<_Event>();
      evPtr.ref.revision = sdrDecoderRevision;
      final code = _poll(
        handle,
        afterSequence,
        evPtr,
        payload,
        sdrDecoderMaxPayload,
      );
      if (code == _sdrDecoderNoData) return null;
      if (code != 0) return null; // includes BUFFER_SMALL: never fabricated.
      final e = evPtr.ref;
      final n = e.payloadBytes;
      if (n > sdrDecoderMaxPayload) return null; // malformed: do not trust.
      return NativeDecoderEvent(
        sequence: e.sequence,
        streamGeneration: e.streamGeneration,
        kind: e.kind,
        payload: Uint8List.fromList(payload.asTypedList(n)),
        droppedEvents: e.droppedEvents,
      );
    } finally {
      calloc.free(evPtr);
      calloc.free(payload);
    }
  }
}

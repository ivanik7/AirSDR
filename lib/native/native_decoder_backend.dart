// SPDX-License-Identifier: GPL-3.0-or-later
// Adapts the optional native decoder extension (native_decoder_api.dart) to
// the Dart-only DecoderBackend contract (lib/ui/decoders/decoder_contract.dart,
// commit 0d19770). Pure routing: no DSP, no sample handling, no fabricated
// availability.
import 'dart:convert';
import 'dart:ffi';

import '../ui/decoders/decoder_contract.dart';
import 'native_decoder_api.dart';
import 'sdr_core.dart';

/// Used whenever no native decoder extension is available (older/incomplete
/// native core, or a build that has not implemented sdrcore_decoder_v1 yet):
/// fixed empty availability, deselect always succeeds, any real select
/// fails, poll never yields an event. Callers must not special-case this
/// type; it exists purely so [DecoderBackend] consumers never see null.
final class NoDecoderBackend implements DecoderBackend {
  const NoDecoderBackend();
  @override
  Set<String> get availableIds => const <String>{};
  @override
  bool select(String? id, Map<String, Object> versionedConfig) =>
      id == null || id.isEmpty; // Deselect is a trivial success; else fail.
  @override
  DecoderEvent? poll(int afterSequence) => null;
}

/// Backs [DecoderBackend] with the real sdrcore_decoder_v1 extension on one
/// v3 handle. [handle] returns the live handle or null while the receiver
/// is not open (not yet started, or stopped/closed/disposed); every call
/// against a null handle fails/returns nothing without throwing, matching
/// "optional additive extension, 0 native availability" and "a failed
/// select leaves receiver, audio, prior decoder and tuning unchanged".
final class NativeDecoderBackend implements DecoderBackend {
  NativeDecoderBackend(this._api, this._handle);

  final NativeDecoderApi _api;
  final Pointer<SdrHandle>? Function() _handle;
  Set<String>? _availableIds;

  /// Native backends are compiled into the registry; availability cannot
  /// change while this process runs, so the registry is fetched once.
  @override
  Set<String> get availableIds => _availableIds ??= {
    for (final d in _api.descriptors())
      if (d.available) d.id,
  };

  @override
  bool select(String? id, Map<String, Object> versionedConfig) {
    final h = _handle();
    if (h == null) {
      // No open receiver: a real selection cannot be serviced. Deselect
      // ("no decoder wanted") is harmless and reports success; anything
      // else must fail rather than silently pretend to succeed.
      return id == null || id.isEmpty;
    }
    if (id != null && id.isNotEmpty && !availableIds.contains(id)) {
      return false; // Only implemented engines may be selected.
    }
    final json = (id == null || id.isEmpty)
        ? '{}'
        : jsonEncode(versionedConfig);
    return _api.select(h, id, json);
  }

  @override
  DecoderEvent? poll(int afterSequence) {
    final h = _handle();
    if (h == null) return null;
    final event = _api.poll(h, afterSequence);
    if (event == null) return null;
    final kind = _resultFromNative(event.kind);
    if (kind == null) return null; // Unknown/malformed kind: never fabricate.
    return DecoderEvent(
      event.sequence,
      event.streamGeneration,
      kind,
      event.payload,
    );
  }
}

/// SdrDecoderResult (native/include/sdrcore_decoder_v1.h) -> DecoderResult
/// (lib/ui/decoders/decoder_contract.dart). Null for any value the Dart
/// contract does not define (defensive: never invent a DecoderResult).
DecoderResult? _resultFromNative(int kind) {
  switch (kind) {
    case 1:
      return DecoderResult.message;
    case 2:
      return DecoderResult.imageProgress;
    case 3:
      return DecoderResult.imageComplete;
    case 4:
      return DecoderResult.aircraft;
    default:
      return null;
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Low-rate UI/control contract. DSP and samples always remain in native C++.
import 'dart:typed_data';

import '../radio_controller.dart' show DemodMode;

/// Data decoder IDs are distinct from stable v3 demodulator choice IDs.
enum DecoderInput { audio, mpx, baseband, rawIq }

enum DecoderResult { none, message, imageProgress, imageComplete, aircraft }

class DecoderSetting {
  const DecoderSetting(this.key, this.defaultValue, {this.allowed = const []});
  final String key;
  final Object defaultValue;
  final List<Object> allowed;
}

class DecoderDescriptor {
  const DecoderDescriptor({
    required this.id,
    required this.label,
    required this.input,
    required this.exclusiveReceiver,
    required this.requiredMode,
    required this.requiredRateHz,
    required this.result,
    this.settings = const [],
    this.voice = false,
    this.demodMode,
    this.underlyingModes,
  });
  final String id, label;
  final DecoderInput input;
  final bool exclusiveReceiver, voice;

  /// A v3 demodulator adapter; never an optional data-decoder factory.
  final DemodMode? demodMode;

  /// Native v3 demod mode ID, or null if independent of demodulation.
  final int? requiredMode;

  /// Audio-tap decoders that run on one of several ordinary demodulators
  /// (OpenWebRX+ "underlying" modes). The choice is stored in the
  /// `underlying` setting and applied through the normal mode control;
  /// the decoder is only attached while the radio runs in that mode.
  final List<DemodMode>? underlyingModes;

  /// Native input sample rate; null until a real backend negotiates it.
  final int? requiredRateHz;
  final DecoderResult result;
  final List<DecoderSetting> settings;
}

/// Stable UI/storage ID for the existing native v3 demod path.
String decoderIdForMode(DemodMode mode) => 'demod:${mode.id}';

DemodMode? demodModeFromDecoderId(String? id) {
  for (final mode in DemodMode.values) {
    if (id == decoderIdForMode(mode)) return mode;
  }
  return null;
}

/// Voice descriptors adapt v3 setMode; data descriptors use the optional
/// native decoder extension. There is only one user-facing choice list.
/// Static data metadata is not backend availability.
final decoderCatalog = <DecoderDescriptor>[
  for (final mode in [
    DemodMode.nfm,
    DemodMode.wfm,
    DemodMode.am,
    DemodMode.usb,
    DemodMode.lsb,
    DemodMode.dsb,
    DemodMode.cw,
    DemodMode.raw,
  ])
    DecoderDescriptor(
      id: decoderIdForMode(mode),
      label: mode.label,
      input: DecoderInput.audio,
      exclusiveReceiver: false,
      requiredMode: mode.id,
      requiredRateHz: null,
      result: DecoderResult.none,
      voice: true,
      demodMode: mode,
      settings: mode == DemodMode.wfm
          ? const [
              DecoderSetting('rbds', false, allowed: [false, true]),
            ]
          : const [],
    ),
  // OpenWebRX+ `dmr` (STATUS-dmr.md §7): a voice mode decoded natively from
  // the VFO-centred baseband tap; AMBE voice replaces demod audio natively.
  // `slot_filter` is the upstream bitmask (1=TS1, 2=TS2, 3=both);
  // `color_code` -1 = off is a documented native addition.
  DecoderDescriptor(
    id: 'dmr',
    label: 'DMR',
    input: DecoderInput.baseband,
    exclusiveReceiver: false,
    requiredMode: null,
    requiredRateHz: null,
    result: DecoderResult.message,
    voice: true,
    settings: const [
      DecoderSetting('slot_filter', 3, allowed: [1, 2, 3]),
      DecoderSetting(
        'color_code',
        -1,
        allowed: [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      ),
      DecoderSetting('voice', true, allowed: [true, false]),
    ],
  ),
  // OpenWebRX+ `sstv`: underlying usb/lsb/nfm, 24 kHz audio, VIS auto-detect.
  // Upstream has no forced picture mode (STATUS-sstv-audit.md), so `mode`
  // only allows `auto`; stale `martin_m1`/`scottie_s1` values normalize to it.
  DecoderDescriptor(
    id: 'sstv',
    label: 'SSTV',
    input: DecoderInput.audio,
    exclusiveReceiver: false,
    requiredMode: null,
    requiredRateHz: 24000,
    result: DecoderResult.imageComplete,
    underlyingModes: const [DemodMode.usb, DemodMode.lsb, DemodMode.nfm],
    settings: const [
      DecoderSetting('mode', 'auto', allowed: ['auto']),
      DecoderSetting('underlying', 'usb', allowed: ['usb', 'lsb', 'nfm']),
    ],
  ),
  DecoderDescriptor(
    id: 'rtl_433',
    label: 'rtl_433',
    input: DecoderInput.baseband,
    exclusiveReceiver: false,
    requiredMode: null,
    requiredRateHz: null,
    result: DecoderResult.message,
    settings: const [], // v1 {"version":1,"settings":{}}; tuning is the VFO.
  ),
  DecoderDescriptor(
    id: 'adsb',
    label: 'ADS-B',
    input: DecoderInput.rawIq,
    exclusiveReceiver: false,
    requiredMode: null,
    requiredRateHz: 2400000,
    result: DecoderResult.aircraft,
  ),
];

DecoderDescriptor? decoderById(String id) {
  for (final descriptor in decoderCatalog) {
    if (descriptor.id == id) return descriptor;
  }
  return null;
}

class DecoderEvent {
  const DecoderEvent(
    this.sequence,
    this.streamGeneration,
    this.kind,
    this.payload, {
    this.droppedEvents = 0,
  });
  final int sequence, streamGeneration;
  final DecoderResult kind;

  /// Copied bounded payload; image bytes are not IQ or PCM samples.
  final Uint8List payload;

  /// Cumulative overflow of the native event FIFO since decoder selection.
  final int droppedEvents;
}

/// Optional additive native decoder extension, never a Dart DSP substitute.
/// Unsupported native cores return an empty availableIds and no events.
abstract interface class DecoderBackend {
  Set<String> get availableIds;

  /// Only implemented engines may be selected; failure must leave RX unchanged.
  bool select(String? id, Map<String, Object> versionedConfig);
  DecoderEvent? poll(int afterSequence);
}

/// Optional WFM metadata control; not a selectable data decoder.
abstract interface class RbdsDecoderBackend {
  bool get rbdsAvailable;
  bool setRbds(bool enabled);
}

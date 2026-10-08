// SPDX-License-Identifier: GPL-3.0-or-later
// Low-rate UI/control contract. DSP and samples always remain in native C++.
import 'dart:typed_data';

/// Data decoder IDs are NOT DemodMode IDs; voice remains the v3 radio path.
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
  });
  final String id, label;
  final DecoderInput input;
  final bool exclusiveReceiver, voice;

  /// Native v3 demod mode ID, or null if independent of demodulation.
  final int? requiredMode;

  /// Native input sample rate; null until a real backend negotiates it.
  final int? requiredRateHz;
  final DecoderResult result;
  final List<DecoderSetting> settings;
}

/// Static preview metadata is not backend availability. Query [DecoderBackend]
/// for the actual installed native engines before enabling any Start action.
const decoderCatalog = <DecoderDescriptor>[
  DecoderDescriptor(
    id: 'voice',
    label: 'Аудио',
    input: DecoderInput.audio,
    exclusiveReceiver: false,
    requiredMode: null,
    requiredRateHz: null,
    result: DecoderResult.none,
    voice: true,
  ),
  DecoderDescriptor(
    id: 'sstv',
    label: 'SSTV',
    input: DecoderInput.audio,
    exclusiveReceiver: false,
    requiredMode: 4,
    requiredRateHz: 24000,
    result: DecoderResult.imageComplete,
    settings: [
      DecoderSetting(
        'mode',
        'auto',
        allowed: ['auto', 'martin_m1', 'scottie_s1'],
      ),
    ],
  ),
  DecoderDescriptor(
    id: 'rtl_433',
    label: 'rtl_433',
    input: DecoderInput.rawIq,
    exclusiveReceiver: true,
    requiredMode: null,
    requiredRateHz: 250000,
    result: DecoderResult.message,
    settings: [
      DecoderSetting(
        'frequency_hz',
        433920000,
        allowed: [315000000, 433920000, 868000000, 915000000],
      ),
    ],
  ),
  DecoderDescriptor(
    id: 'adsb',
    label: 'ADS-B',
    input: DecoderInput.rawIq,
    exclusiveReceiver: true,
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
    this.payload,
  );
  final int sequence, streamGeneration;
  final DecoderResult kind;

  /// Copied bounded payload; image bytes are not IQ or PCM samples.
  final Uint8List payload;
}

/// Optional additive native decoder extension, never a Dart DSP substitute.
/// Unsupported native cores return an empty availableIds and no events.
abstract interface class DecoderBackend {
  Set<String> get availableIds;

  /// Only implemented engines may be selected; failure must leave RX unchanged.
  bool select(String? id, Map<String, Object> versionedConfig);
  DecoderEvent? poll(int afterSequence);
}

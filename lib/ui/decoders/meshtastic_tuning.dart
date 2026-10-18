// SPDX-License-Identifier: GPL-3.0-or-later
// Meshtastic firmware v2.8.1: MeshRadio.h::modemPresetToParams and
// RadioInterface.cpp::regions/applyModemConfig. Frequencies are receive-only.
import '../legacy/centered_receiver.dart';
class MeshtasticPreset {
  const MeshtasticPreset(this.name, this.bandwidthHz, this.sf, this.cr,
      {this.supported = true});
  final String name;
  final int bandwidthHz, sf, cr; // CR denominator: 5 means 4/5.
  // The OpenWebRX+ lorarx chain only searches SF 7..11 and the standard BW.
  final bool supported;
  String? get limitation => !supported
      ? 'Not supported by the OpenWebRX+ LoRa chain: SF$sf / '
          '${bandwidthHz / 1000} kHz'
      : null;
}

const meshtasticPresets = <MeshtasticPreset>[
  MeshtasticPreset('LongFast', 250000, 11, 5),
  MeshtasticPreset('LongSlow', 125000, 12, 8, supported: false),
  MeshtasticPreset('MediumSlow', 250000, 10, 5),
  MeshtasticPreset('MediumFast', 250000, 9, 5),
  MeshtasticPreset('ShortSlow', 250000, 8, 5),
  MeshtasticPreset('ShortFast', 250000, 7, 5),
  MeshtasticPreset('LongMod', 125000, 11, 8),
  MeshtasticPreset('ShortTurbo', 500000, 7, 5),
  MeshtasticPreset('LongTurbo', 500000, 11, 8),
  MeshtasticPreset('MediumTurbo', 500000, 9, 5),
  MeshtasticPreset('LiteFast', 125000, 9, 5),
  MeshtasticPreset('LiteSlow', 125000, 10, 5),
  MeshtasticPreset('NarrowFast', 62500, 7, 6),
  MeshtasticPreset('NarrowSlow', 62500, 8, 6),
  MeshtasticPreset('TinyFast', 15600, 7, 5, supported: false),
  MeshtasticPreset('TinySlow', 15600, 8, 6, supported: false),
];

class MeshtasticRegion {
  const MeshtasticRegion(this.code, this.startHz, this.endHz,
      {this.spacingHz = 0, this.paddingHz = 0, this.overrideSlot = 0,
      this.presets = const ['LongFast'], this.documentedCenterHz});
  final String code;
  final int startHz, endHz, spacingHz, paddingHz, overrideSlot;
  final List<String> presets;
  // Cross-checked with OpenWebRX+ band table. All other computed values
  // must be visibly marked unverified until checked against a second source.
  final int? documentedCenterHz;
}

const _standardPresets = [
  'LongFast', 'LongSlow', 'MediumSlow', 'MediumFast', 'ShortSlow',
  'ShortFast', 'LongMod', 'ShortTurbo', 'LongTurbo', 'MediumTurbo',
];
const meshtasticRegions = <MeshtasticRegion>[
  MeshtasticRegion('US', 902000000, 928000000,
      presets: _standardPresets, documentedCenterHz: 906875000),
  MeshtasticRegion('EU_433', 433000000, 434000000,
      presets: _standardPresets),
  MeshtasticRegion('EU_868', 869400000, 869650000,
      presets: ['LongFast', 'LongSlow', 'MediumSlow', 'MediumFast',
        'ShortSlow', 'ShortFast', 'LongMod'],
      documentedCenterHz: 869525000),
  MeshtasticRegion('EU_866', 865600000, 867600000,
      spacingHz: 400000, paddingHz: 37500,
      presets: ['LiteFast', 'LiteSlow']),
  MeshtasticRegion('EU_N_868', 869400000, 869650000,
      paddingHz: 10400, overrideSlot: 1,
      presets: ['NarrowFast', 'NarrowSlow']),
  MeshtasticRegion('CN', 470000000, 510000000, presets: _standardPresets),
  MeshtasticRegion('JP', 920500000, 923500000, presets: _standardPresets),
  MeshtasticRegion('ANZ', 915000000, 928000000, presets: _standardPresets),
  MeshtasticRegion('RU', 868700000, 869200000, presets: _standardPresets),
  // Kazakhstan (firmware issue #7204): KZ_433 433.075-434.775 MHz LPD and
  // KZ_863 863-868 MHz, both PROFILE_STD.
  MeshtasticRegion('KZ_433', 433075000, 434775000, presets: _standardPresets),
  MeshtasticRegion('KZ_863', 863000000, 868000000, presets: _standardPresets),
];

MeshtasticPreset meshtasticPreset(String name) => meshtasticPresets
    .firstWhere((p) => p.name == name, orElse: () =>
        throw ArgumentError.value(name, 'preset', 'Unknown Meshtastic preset'));

MeshtasticRegion meshtasticRegion(String code) => meshtasticRegions
    .firstWhere((r) => r.code == code, orElse: () =>
        throw ArgumentError.value(code, 'region', 'Unknown Meshtastic region'));

class MeshtasticChannel {
  const MeshtasticChannel(this.frequencyHz, this.slot, this.verified);
  final int frequencyHz, slot; // 1-based frequency slot.
  final bool verified;
  String get verificationLabel => verified ? '' : 'Unverified frequency';
}

/// Firmware djb2 uses a wrapping uint32 over the primary channel's name.
/// A blank channel name means the selected preset's display name.
MeshtasticChannel meshtasticChannelFrequency(MeshtasticRegion region,
    MeshtasticPreset preset, {String channelName = '', int? slot}) {
  if (!region.presets.contains(preset.name)) {
    throw ArgumentError('Preset ${preset.name} is not allowed in ${region.code}');
  }
  final width = region.spacingHz + 2 * region.paddingHz + preset.bandwidthHz;
  final count = ((region.endHz - region.startHz + region.spacingHz) /
      width).round();
  if (count <= 0) throw StateError('No frequency slots for ${region.code}');
  if (slot != null && (slot < 1 || slot > count)) {
    throw RangeError.range(slot, 1, count, 'slot');
  }
  var hash = 5381;
  for (final byte in (channelName.isEmpty ? preset.name : channelName).codeUnits) {
    if (byte > 127) throw ArgumentError('Channel name must be ASCII');
    hash = ((hash * 33) + byte) & 0xffffffff;
  }
  final selected = slot ?? (region.overrideSlot > 0
      ? region.overrideSlot : hash % count + 1);
  if (selected > count) throw StateError('Region override slot exceeds band');
  final frequency = region.startHz + preset.bandwidthHz ~/ 2 +
      region.paddingHz + (selected - 1) * width;
  final verified = slot == null && channelName.isEmpty &&
      preset.name == 'LongFast' &&
      region.documentedCenterHz == frequency;
  return MeshtasticChannel(frequency, selected, verified);
}

/// The receiver cannot synthesize missing IQ bandwidth or follow 2.4 GHz on
/// a Blog V4. Never silently substitute a narrower preset or tuner rate.
String? meshtasticInputLimit(MeshtasticPreset preset, int sampleRateHz,
    int vfoOffsetHz, {bool receiverSupportsFrequency = true}) {
  if (!preset.supported) return preset.limitation;
  if (!receiverSupportsFrequency) return 'Frequency outside receiver tuning range';
  if (sampleRateHz < 1000000) return 'Requires at least 1 MS/s source IQ';
  if (vfoOffsetHz.abs() + 500000 > sampleRateHz ~/ 2) {
    return 'The tuned 1 MHz window exceeds the source bandwidth';
  }
  return null;
}

/// Uses the ordinary VFO policy (range, band, step grid and recenter).
/// Returns the applied frequency because the receiver's step grid may snap a
/// firmware slot center; callers must not display a different tuned value.
int tuneMeshtasticRegion(CenteredReceiver receiver, MeshtasticRegion region,
    MeshtasticPreset preset, {String channelName = ''}) {
  final channel = meshtasticChannelFrequency(region, preset,
      channelName: channelName);
  receiver.tune(channel.frequencyHz.toDouble());
  return receiver.radio.tunedFrequency.round();
}

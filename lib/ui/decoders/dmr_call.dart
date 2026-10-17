// SPDX-License-Identifier: GPL-3.0-or-later
// Presentation-only DMR metadata. The native pipeline owns IQ and voice PCM.
class DmrCall {
  const DmrCall({
    required this.slot,
    required this.startedAt,
    required this.lastSeen,
    this.endedAt,
    this.source,
    this.target,
    this.type,
    this.privacy,
    this.colorCode,
    this.alias,
    this.latitude,
    this.longitude,
    this.voice,
  });

  final int slot;
  final DateTime startedAt, lastSeen;
  final DateTime? endedAt;
  final int? source, target, colorCode;
  final String? type, alias, voice;
  final bool? privacy;
  final double? latitude, longitude;

  Duration elapsed(DateTime now) => (endedAt ?? now).difference(startedAt);

  DmrCall end(DateTime when) => DmrCall(
    slot: slot,
    startedAt: startedAt,
    lastSeen: lastSeen,
    endedAt: when,
    source: source,
    target: target,
    type: type,
    privacy: privacy,
    colorCode: colorCode,
    alias: alias,
    latitude: latitude,
    longitude: longitude,
    voice: voice,
  );

  static DmrCall? fromEvent(
    Map<String, Object?> data,
    DateTime now,
    DmrCall? prior,
  ) {
    final slot = data['slot'];
    if (slot is! int || slot < 0 || slot > 1 || data['sync'] != 'voice') {
      return null;
    }
    int? id(String key) {
      final value = data[key];
      return value is int && value > 0 ? value : null;
    }

    final source = id('source');
    final target = id('target');
    final type = data['type'];
    final callType = type == 'group' || type == 'direct'
        ? type as String
        : null;
    final same =
        prior != null &&
        prior.source == source &&
        prior.target == target &&
        prior.type == callType;
    final color = data['color_code'];
    final lat = data['lat'];
    final lon = data['lon'];
    final alias = data['talkeralias'];
    final voice = data['voice'];
    return DmrCall(
      slot: slot,
      startedAt: same ? prior.startedAt : now,
      lastSeen: now,
      source: source,
      target: target,
      type: callType,
      privacy: data['privacy'] is bool ? data['privacy'] as bool : null,
      colorCode: color is int && color >= 0 && color <= 15 ? color : null,
      alias: alias is String && alias.isNotEmpty ? alias : null,
      latitude: lat is num ? lat.toDouble() : null,
      longitude: lon is num ? lon.toDouble() : null,
      voice: voice == 'ok' || voice == 'muted' || voice == 'unavailable'
          ? voice as String
          : null,
    );
  }
}

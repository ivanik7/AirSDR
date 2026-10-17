// SPDX-License-Identifier: GPL-3.0-or-later
// Presentation-only DMR metadata parsed from native `dmr/1` events
// (docs/status/dmr.md §7.4). Absent keys stay null: nothing is invented. The
// native pipeline owns IQ and voice PCM.
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
    this.durationMs,
  });

  final int slot;
  final DateTime startedAt, lastSeen;
  final DateTime? endedAt;
  final int? source, target, colorCode;
  final String? type, alias, voice;
  final bool? privacy;
  final double? latitude, longitude;

  /// Native duration: observed voice frames × 30 ms (not wall time).
  final int? durationMs;

  /// Wall-clock span between the first and last/ending event in Dart.
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
    durationMs: durationMs,
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
    final duration = data['duration_ms'];
    return DmrCall(
      slot: slot,
      startedAt: same ? prior.startedAt : now,
      lastSeen: now,
      source: source,
      target: target,
      type: callType,
      privacy: data['privacy'] is bool
          ? data['privacy'] as bool
          : (same ? prior.privacy : null),
      colorCode: color is int && color >= 0 && color <= 15 ? color : null,
      // Talker alias and GPS arrive in separate LC blocks; keep them for the
      // rest of the same call instead of flickering between events.
      alias: alias is String && alias.isNotEmpty
          ? alias
          : (same ? prior.alias : null),
      latitude: lat is num && lon is num
          ? lat.toDouble()
          : (same ? prior.latitude : null),
      longitude: lat is num && lon is num
          ? lon.toDouble()
          : (same ? prior.longitude : null),
      voice: voice == 'ok' || voice == 'muted' || voice == 'unavailable'
          ? voice as String
          : null,
      durationMs: duration is int && duration >= 0
          ? duration
          : (same ? prior.durationMs : null),
    );
  }
}

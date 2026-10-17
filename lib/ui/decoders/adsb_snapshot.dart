// SPDX-License-Identifier: GPL-3.0-or-later
// Low-rate ADS-B snapshot model. Tracking and expiry originate in dump1090.
import 'dart:math' as math;

class ReceiverLocation {
  const ReceiverLocation(this.latitude, this.longitude);
  final double latitude, longitude;

  static ReceiverLocation? parse(String latitude, String longitude) {
    final lat = double.tryParse(latitude.trim());
    final lon = double.tryParse(longitude.trim());
    if (lat == null ||
        lon == null ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      return null;
    }
    return ReceiverLocation(lat, lon);
  }
}

class AdsbAircraft {
  const AdsbAircraft({
    required this.icao,
    required this.lastSeen,
    required this.messages,
    this.callsign,
    this.squawk,
    this.altitudeFt,
    this.groundSpeedKt,
    this.trackDeg,
    this.verticalRateFpm,
    this.latitude,
    this.longitude,
    this.rssi,
  });
  final String icao;
  final DateTime lastSeen;
  final int messages;
  final String? callsign, squawk;
  final num? altitudeFt, groundSpeedKt, trackDeg, verticalRateFpm, rssi;
  final double? latitude, longitude;

  bool isStale(DateTime now) => now.difference(lastSeen).inSeconds >= 60;
  bool isExpired(DateTime now) => now.difference(lastSeen).inSeconds >= 300;
  double? distanceKm(ReceiverLocation location) {
    if (latitude == null || longitude == null) return null;
    const toRad = math.pi / 180;
    final dLat = (latitude! - location.latitude) * toRad;
    final dLon = (longitude! - location.longitude) * toRad;
    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(latitude! * toRad) *
            math.cos(location.latitude * toRad) *
            math.pow(math.sin(dLon / 2), 2);
    return 6371.0 * 2 * math.asin(math.sqrt(a.clamp(0, 1)));
  }

  static AdsbAircraft? parse(Map<String, dynamic> data) {
    final id = data['icao'];
    final seen = data['last_seen_ms'];
    final messages = data['messages'];
    if (id is! String ||
        !RegExp(r'^~?[0-9A-F]{6}$').hasMatch(id) ||
        seen is! int ||
        seen <= 0 ||
        messages is! int ||
        messages < 0) {
      return null;
    }
    bool text(String key) => !data.containsKey(key) || data[key] is String;
    bool number(String key) =>
        !data.containsKey(key) ||
        (data[key] is num && (data[key] as num).isFinite);
    if (!text('callsign') ||
        !text('squawk') ||
        (data['squawk'] != null &&
            !RegExp(r'^\d{4}$').hasMatch(data['squawk'] as String)) ||
        ![
          'altitude_ft',
          'ground_speed_kt',
          'track_deg',
          'vertical_rate_fpm',
          'rssi',
          'latitude',
          'longitude',
        ].every(number)) {
      return null;
    }
    final lat = data['latitude'];
    final lon = data['longitude'];
    if ((lat == null) != (lon == null) ||
        (lat is num && lat.abs() > 90) ||
        (lon is num && lon.abs() > 180)) {
      return null;
    }
    return AdsbAircraft(
      icao: id,
      lastSeen: DateTime.fromMillisecondsSinceEpoch(seen),
      messages: messages,
      callsign: data['callsign'] as String?,
      squawk: data['squawk'] as String?,
      altitudeFt: data['altitude_ft'] as num?,
      groundSpeedKt: data['ground_speed_kt'] as num?,
      trackDeg: data['track_deg'] as num?,
      verticalRateFpm: data['vertical_rate_fpm'] as num?,
      rssi: data['rssi'] as num?,
      latitude: (lat as num?)?.toDouble(),
      longitude: (lon as num?)?.toDouble(),
    );
  }
}

class AdsbSnapshot {
  const AdsbSnapshot(
    this.timestamp,
    this.inputRateHz,
    this.messageRate,
    this.crcFixed,
    this.aircraft,
  );
  final DateTime timestamp;
  final int inputRateHz, crcFixed;
  final double messageRate;
  final List<AdsbAircraft> aircraft;

  static AdsbSnapshot? parse(Map<String, dynamic> data) {
    final timestamp = data['timestamp_ms'];
    final rate = data['input_rate_hz'];
    final count = data['crc_fixed'];
    final messageRate = data['message_rate'];
    final list = data['aircraft'];
    if (data['version'] != 1 ||
        data['source'] != 'adsb' ||
        timestamp is! int ||
        timestamp <= 0 ||
        rate != 2400000 ||
        count is! int ||
        count < 0 ||
        messageRate is! num ||
        !messageRate.isFinite ||
        messageRate < 0 ||
        list is! List ||
        list.length > 128) {
      return null;
    }
    final parsed = <AdsbAircraft>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) return null;
      final aircraft = AdsbAircraft.parse(item);
      if (aircraft == null) return null;
      parsed.add(aircraft);
    }
    return AdsbSnapshot(
      DateTime.fromMillisecondsSinceEpoch(timestamp),
      rate,
      messageRate.toDouble(),
      count,
      List.unmodifiable(parsed),
    );
  }

  List<AdsbAircraft> visible(DateTime now) =>
      aircraft.where((item) => !item.isExpired(now)).toList();

  List<AdsbAircraft> sorted(ReceiverLocation? location, {DateTime? now}) {
    final result = visible(now ?? timestamp);
    result.sort((a, b) {
      if (location != null) {
        final left = a.distanceKm(location);
        final right = b.distanceKm(location);
        if (left != null && right != null) {
          final order = left.compareTo(right);
          if (order != 0) return order;
        } else if (left != null) {
          return -1;
        } else if (right != null) {
          return 1;
        }
      }
      final recency = b.lastSeen.compareTo(a.lastSeen);
      return recency != 0 ? recency : a.icao.compareTo(b.icao);
    });
    return result;
  }
}

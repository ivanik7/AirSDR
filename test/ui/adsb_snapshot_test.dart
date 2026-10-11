// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/decoders/adsb_snapshot.dart';

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1730000000000);
  Map<String, Object?> aircraft(
    String icao,
    int age, {
    double? lat,
    double? lon,
  }) => {
    'icao': icao,
    'last_seen_ms': now.millisecondsSinceEpoch - age * 1000,
    'messages': 7,
    'latitude': ?lat,
    'longitude': ?lon,
  };
  test(
    'validates a complete bounded native snapshot without inventing fields',
    () {
      final snapshot = AdsbSnapshot.parse({
        'version': 1,
        'source': 'adsb',
        'timestamp_ms': now.millisecondsSinceEpoch,
        'input_rate_hz': 2400000,
        'message_rate': 4.0,
        'crc_fixed': 0,
        'aircraft': [
          aircraft('ABC123', 4),
          aircraft('DEF012', 60, lat: 51.5, lon: -0.1),
        ],
      });
      expect(snapshot, isNotNull);
      expect(snapshot!.aircraft.first.callsign, isNull);
      expect(snapshot.aircraft.first.latitude, isNull);
      expect(snapshot.aircraft.first.isStale(now), isFalse);
      expect(snapshot.aircraft.last.isStale(now), isTrue);
      expect(snapshot.sorted(null).first.icao, 'ABC123');
      expect(
        snapshot.sorted(const ReceiverLocation(51.5, -0.1)).first.icao,
        'DEF012',
      );
      expect(
        snapshot.aircraft.last.distanceKm(const ReceiverLocation(51.5, -0.1)),
        0,
      );
    },
  );
  test('rejects malformed, partial and oversized snapshots', () {
    final base = <String, Object?>{
      'version': 1,
      'source': 'adsb',
      'timestamp_ms': now.millisecondsSinceEpoch,
      'input_rate_hz': 2400000,
      'message_rate': 0,
      'crc_fixed': 0,
      'aircraft': [aircraft('ABC123', 1)],
    };
    expect(
      AdsbSnapshot.parse({
        ...base,
        'aircraft': [aircraft('ABC123', 1, lat: 2)],
      }),
      isNull,
    );
    expect(
      AdsbSnapshot.parse({
        ...base,
        'aircraft': [aircraft('BAD', 1)],
      }),
      isNull,
    );
    expect(
      AdsbSnapshot.parse({
        ...base,
        'aircraft': List.filled(129, aircraft('ABC123', 1)),
      }),
      isNull,
    );
    expect(AdsbSnapshot.parse({...base, 'version': 2}), isNull);
    expect(AdsbSnapshot.parse({...base, 'message_rate': double.nan}), isNull);
    expect(
      AdsbSnapshot.parse({
        ...base,
        'aircraft': [aircraft('ABC123', 301)],
      }),
      isNotNull,
    );
    expect(
      AdsbSnapshot.parse(base)!.visible(now.add(const Duration(seconds: 301))),
      isEmpty,
    );
  });
  test('validates optional receiver location', () {
    expect(ReceiverLocation.parse('51.5', '-0.1'), isNotNull);
    expect(ReceiverLocation.parse('91', '0'), isNull);
    expect(ReceiverLocation.parse('', '0'), isNull);
  });
}

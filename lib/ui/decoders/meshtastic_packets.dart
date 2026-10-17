// SPDX-License-Identifier: GPL-3.0-or-later
// Meshtastic packet log and node list, fed only by real native `message`
// events of the selected `meshtastic` decoder (docs/status/meshtastic.md).
// Field names follow the native packet layer, which extends OpenWebRX+
// `owrx/meshtastic.py` output; display rules follow OpenWebRX+
// `htdocs/lib/MessagePanel.js` MeshtasticMessagePanel (f1e0d1a).
import 'dart:convert';

import 'meshtastic_keys.dart';

const meshtasticBroadcast = 0xffffffff;

/// OpenWebRX+ `MeshtasticMessagePanel.makeAddr`: `!` + 8 hex digits.
String meshtasticAddr(int addr) =>
    '!${(addr & 0xffffffff).toRadixString(16).padLeft(8, '0')}';

int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
double? _num(Object? v) => v is num ? v.toDouble() : null;
String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

/// One decoded (or undecryptable) packet. [json] is already scrubbed of
/// configured keys.
class MeshtasticPacket {
  MeshtasticPacket._(this.sequence, this.json, this.receivedAt);

  /// Returns null when [raw] is not a native Meshtastic event.
  static MeshtasticPacket? fromEvent(
    int sequence,
    Map<String, Object?> raw, {
    required DateTime receivedAt,
    Set<String> secrets = const {},
  }) {
    if (raw['mode'] != 'Meshtastic') return null;
    if (_int(raw['src']) == null || _int(raw['dst']) == null) return null;
    final clean = redactMeshtasticSecrets(raw, secrets)! as Map<String, Object?>;
    return MeshtasticPacket._(sequence, clean, receivedAt);
  }

  final int sequence;
  final Map<String, Object?> json;
  final DateTime receivedAt;

  int get src => _int(json['src'])!;
  int get dst => _int(json['dst'])!;
  int? get packetId => _int(json['packet_id']);
  int? get channelHash => _int(json['channel_hash']);
  int? get hopLimit => _int(json['hop_limit']);
  int? get hopStart => _int(json['hop_start']);
  int? get frequencyHz => _int(json['freq']);
  bool get wantAck => json['want_ack'] == true;
  bool get viaMqtt => json['via_mqtt'] == true;
  bool get encrypted => json['encrypted'] == true;
  String? get decrypt => _str(json['decrypt']);
  String? get type => _str(json['type']);
  String? get text => json['message'] is String ? json['message'] as String : null;
  Map<String, Object?>? get data => json['data'] is Map
      ? (json['data'] as Map).cast<String, Object?>()
      : null;
  Map<String, Object?> get phy => json['phy'] is Map
      ? (json['phy'] as Map).cast<String, Object?>()
      : const {};

  /// Native `timestamp` is UTC epoch milliseconds; falls back to arrival.
  DateTime get time {
    final ms = _int(json['timestamp']);
    return ms != null && ms > 0
        ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
        : receivedAt.toUtc();
  }

  bool get broadcast => dst == meshtasticBroadcast;

  /// Source label: node short name (OWRX+ `nickName`) or `!id`.
  String get from => _str(json['nickName']) ?? meshtasticAddr(src);

  /// Destination label: `ALL` for broadcast, else `dstNickName` or `!id`.
  String get to => broadcast
      ? 'ALL'
      : _str(json['dstNickName']) ?? meshtasticAddr(dst);

  /// OWRX+ data column: `type || longName || comment`, with an explicit
  /// state for packets that could not be decrypted.
  String get headline {
    if (encrypted) {
      if (json['pki_possible'] == true) {
        return 'Encrypted direct message (PKI, not decryptable)';
      }
      return decrypt == 'failed'
          ? 'Encrypted · channel hash matched, key did not decode'
          : 'Encrypted · unknown key';
    }
    return type ?? _str(json['longName']) ?? _str(json['comment']) ?? 'Packet';
  }

  /// `hop <used>/<start>` as in the native/OWRX+ `comment`.
  String? get hops {
    final start = hopStart, limit = hopLimit;
    if (start == null || limit == null) return null;
    return 'hop ${start - limit}/$start';
  }

  /// lorarx `bw` is Hz in its own JSON but kHz in native PhyMeta; accept both.
  String get phySummary {
    final p = phy;
    final bw = _num(p['bw']);
    final sf = _int(p['sf']);
    final cr = _int(p['cr']);
    return [
      if (sf != null) 'SF$sf',
      if (bw != null) 'BW ${_trim(bw > 1000 ? bw / 1000 : bw)} kHz',
      if (cr != null) 'CR 4/$cr',
    ].join(' · ');
  }

  /// lorarx reports an uncalibrated signal `level` in dB, not RSSI in dBm.
  String get signalSummary {
    final p = phy;
    final level = _num(p['level']);
    final snr = _num(p['snr']);
    return [
      if (level != null) 'level ${level.toStringAsFixed(1)} dB',
      if (snr != null) 'SNR ${snr.toStringAsFixed(1)} dB',
    ].join(' · ');
  }

  String get headerSummary => [
    if (packetId != null) 'id ${meshtasticAddr(packetId!).substring(1)}',
    ?hops,
    if (channelHash != null)
      'ch 0x${channelHash!.toRadixString(16).padLeft(2, '0')}',
    if (_str(json['channel']) != null) '"${json['channel']}"',
    if (wantAck) 'want ack',
    if (viaMqtt) 'via MQTT',
  ].join(' · ');

  /// OWRX+ `formatAttr` rows for `data`, flattened with unit conversions.
  List<(String, String)> get dataRows {
    final rows = <(String, String)>[];
    void walk(Map<String, Object?> m) {
      for (final e in m.entries) {
        final v = e.value;
        if (v is Map) {
          walk(v.cast<String, Object?>());
        } else {
          rows.add((e.key, formatMeshtasticAttr(e.key, v)));
        }
      }
    }

    final d = data;
    if (d != null) walk(d);
    if (json['raw'] is String) rows.add(('raw', json['raw'] as String));
    if (json['ciphertext'] is String) {
      rows.add(('ciphertext', json['ciphertext'] as String));
    }
    return rows;
  }

  String get formattedJson => const JsonEncoder.withIndent('  ').convert(json);
}

String _trim(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// OpenWebRX+ `MeshtasticMessagePanel.formatAttr` value conversions.
String formatMeshtasticAttr(String key, Object? v) {
  final n = _num(v);
  switch (key) {
    case 'time':
    case 'timestamp':
      if (n != null) {
        return DateTime.fromMillisecondsSinceEpoch((n * 1000).round(),
                isUtc: true)
            .toIso8601String()
            .replaceFirst('.000', '');
      }
    case 'latitude_i':
    case 'longitude_i':
      if (n != null) return '${n / 10000000.0}';
    case 'voltage':
    case 'ch1_voltage':
    case 'ch2_voltage':
      if (n != null) return '${n.toStringAsFixed(2)} V';
    case 'ch1_current':
    case 'ch2_current':
      if (n != null) return '${n.toStringAsFixed(3)} A';
    case 'battery_level':
    case 'channel_utilization':
    case 'air_util_tx':
    case 'relative_humidity':
      if (n != null) return '${n.toStringAsFixed(0)} %';
    case 'temperature':
      if (n != null) return '${n.toStringAsFixed(1)} °C';
    case 'barometric_pressure':
      if (n != null) return '${n.toStringAsFixed(1)} hPa';
    case 'macaddr':
      if (v is String) {
        try {
          return base64
              .decode(v)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join()
              .toUpperCase();
        } on FormatException {
          return v;
        }
      }
  }
  if (v is List) return v.join(', ');
  return '$v';
}

/// A node learned from decoded NODEINFO, POSITION or TELEMETRY packets.
class MeshtasticNode {
  MeshtasticNode(this.nodeNum);
  final int nodeNum;
  String? shortName, longName, hwModel, role;
  double? lat, lon;
  num? altitude;
  int? batteryLevel;
  double? voltage;
  double? snr;
  DateTime lastHeard = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  int packets = 0;

  String get id => meshtasticAddr(nodeNum);
  String get label => shortName ?? id;
}

/// Bounded newest-first packet log, text-message view and node list.
class MeshtasticLog {
  /// OpenWebRX+ trims its message panel to 250 rows (`clearMessages(250)`).
  static const packetLimit = 250;
  static const messageLimit = 250;

  /// Native parser node cache is capped at 2048; the UI keeps fewer.
  static const nodeLimit = 500;

  final List<MeshtasticPacket> _packets = [];
  final List<MeshtasticPacket> _messages = [];
  final Map<int, MeshtasticNode> _nodes = {};

  List<MeshtasticPacket> get packets => List.unmodifiable(_packets);
  List<MeshtasticPacket> get messages => List.unmodifiable(_messages);

  /// Most recently heard first.
  List<MeshtasticNode> get nodes =>
      _nodes.values.toList()
        ..sort((a, b) => b.lastHeard.compareTo(a.lastHeard));

  void add(MeshtasticPacket packet) {
    _packets.insert(0, packet);
    if (_packets.length > packetLimit) _packets.removeLast();
    if (!packet.encrypted && packet.text != null) {
      _messages.insert(0, packet);
      if (_messages.length > messageLimit) _messages.removeLast();
    }
    _updateNode(packet);
  }

  void _updateNode(MeshtasticPacket p) {
    if (p.encrypted) {
      // Header-only: refresh nodes we already know, never invent new ones.
      final known = _nodes[p.src];
      if (known != null) _heard(known, p);
      return;
    }
    final type = p.type;
    final data = p.data;
    final isNodeInfo = type == 'NODEINFO_APP';
    final isPosition = type == 'POSITION_APP';
    final isTelemetry = type == 'TELEMETRY_APP';
    var node = _nodes[p.src];
    if (node == null) {
      if (!isNodeInfo && !isPosition && !isTelemetry) {
        // Also learned from the native node-cache annotations.
        if (_str(p.json['nickName']) == null &&
            _str(p.json['longName']) == null) {
          return;
        }
      }
      node = _nodes[p.src] = MeshtasticNode(p.src);
      _heard(node, p);
      _evict();
    } else {
      _heard(node, p);
    }
    final j = p.json;
    node.shortName = _str(j['nickName']) ?? node.shortName;
    node.longName = _str(j['longName']) ?? node.longName;
    node.hwModel = _str(j['device']) ?? node.hwModel;
    node.role = _str(j['role']) ?? node.role;
    if (isNodeInfo && data != null) {
      node.shortName = _str(data['short_name']) ?? node.shortName;
      node.longName = _str(data['long_name']) ?? node.longName;
      node.hwModel = _str(data['hw_model']) ?? node.hwModel;
      node.role = _str(data['role']) ?? node.role;
    }
    if (_num(j['lat']) != null && _num(j['lon']) != null) {
      node.lat = _num(j['lat']);
      node.lon = _num(j['lon']);
      node.altitude = j['altitude'] is num ? j['altitude'] as num : node.altitude;
    }
    if (isTelemetry && data?['device_metrics'] is Map) {
      final m = (data!['device_metrics'] as Map).cast<String, Object?>();
      node.batteryLevel = _int(m['battery_level']) ?? node.batteryLevel;
      node.voltage = _num(m['voltage']) ?? node.voltage;
    }
  }

  void _heard(MeshtasticNode node, MeshtasticPacket p) {
    node.packets++;
    if (!p.time.isBefore(node.lastHeard)) node.lastHeard = p.time;
    node.snr = _num(p.phy['snr']) ?? node.snr;
  }

  void _evict() {
    while (_nodes.length > nodeLimit) {
      final oldest = _nodes.values.reduce(
        (a, b) => a.lastHeard.isBefore(b.lastHeard) ? a : b,
      );
      _nodes.remove(oldest.nodeNum);
    }
  }

  void clearPackets() {
    _packets.clear();
    _messages.clear();
  }

  void clear() {
    clearPackets();
    _nodes.clear();
  }

  bool get isEmpty => _packets.isEmpty && _nodes.isEmpty;
}

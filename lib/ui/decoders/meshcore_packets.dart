// SPDX-License-Identifier: GPL-3.0-or-later
// Session-local, bounded MeshCore events. Trust only verified native fields.
import 'dart:convert';

import 'meshcore_keys.dart';

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const <String, Object?>{};
String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

class MeshcorePacket {
  const MeshcorePacket._(this.sequence, this.json, this.receivedAt);
  static MeshcorePacket? fromEvent(
    int sequence,
    Map<String, Object?> raw, {
    required DateTime receivedAt,
    Set<String> secrets = const {},
  }) {
    if (raw['mode'] != 'MeshCore') return null;
    final clean = redactMeshcoreSecrets(raw, secrets) as Map<String, Object?>;
    return MeshcorePacket._(sequence, clean, receivedAt);
  }

  final int sequence;
  final Map<String, Object?> json;
  final DateTime receivedAt;
  Map<String, Object?> get header => _map(json['header']);
  Map<String, Object?> get payload => _map(json['payload']);
  Map<String, Object?> get phy => _map(json['phy']);
  String get type => _string(header['type_name']) ?? 'Packet';
  String? get text => payload['encrypted'] == false && type == 'GRP_TXT'
      ? _string(payload['text'])
      : null;
  bool get signedAdvert =>
      type == 'ADVERT' &&
      payload['signature_valid'] == true &&
      json['error'] == null;
  String? get publicKey => signedAdvert ? _string(payload['public_key']) : null;
  Map<String, Object?> get advert =>
      signedAdvert ? _map(payload['advert']) : const {};
  int? get frequencyHz => json['freq'] is int ? json['freq'] as int : null;
  DateTime get time {
    final ms = json['timestamp'];
    return ms is int && ms > 0
        ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
        : receivedAt.toUtc();
  }

  String get headline => json['error'] is String
      ? 'Packet error: ${json['error']}'
      : payload['encrypted'] == true
      ? '$type · encrypted'
      : type;
  String get formattedJson => const JsonEncoder.withIndent('  ').convert(json);
}

class MeshcoreNode {
  MeshcoreNode(this.publicKey, this.name, this.lastHeard);
  final String publicKey;
  String? name;
  DateTime lastHeard;
}

class MeshcoreLog {
  static const packetLimit = 250;
  static const messageLimit = 250;
  static const nodeLimit = 500;
  final List<MeshcorePacket> _packets = [];
  final List<MeshcorePacket> _messages = [];
  final Map<String, MeshcoreNode> _nodes = {};
  List<MeshcorePacket> get packets => List.unmodifiable(_packets);
  List<MeshcorePacket> get messages => List.unmodifiable(_messages);
  List<MeshcoreNode> get nodes =>
      _nodes.values.toList()
        ..sort((a, b) => b.lastHeard.compareTo(a.lastHeard));
  bool get isEmpty => _packets.isEmpty && _nodes.isEmpty;

  void add(MeshcorePacket packet) {
    _packets.insert(0, packet);
    if (_packets.length > packetLimit) _packets.removeLast();
    if (packet.text != null) {
      _messages.insert(0, packet);
      if (_messages.length > messageLimit) _messages.removeLast();
    }
    final key = packet.publicKey;
    if (key != null) {
      final node = _nodes.putIfAbsent(
        key,
        () => MeshcoreNode(key, null, packet.time),
      );
      node.name = _string(packet.advert['name']) ?? node.name;
      node.lastHeard = packet.time;
      if (_nodes.length > nodeLimit) {
        final oldest = nodes.last;
        _nodes.remove(oldest.publicKey);
      }
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
}

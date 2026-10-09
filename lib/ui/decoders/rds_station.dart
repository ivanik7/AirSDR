// SPDX-License-Identifier: GPL-3.0-or-later
// Low-rate RDS station metadata only; MPX and audio stay in the native core.
class RdsStation {
  final Map<String, Object?> fields = {};
  bool synced = false;
  num? bler;

  void clear() {
    fields.clear();
    synced = false;
    bler = null;
  }

  /// Native sends accumulated snapshots; merge partial packets defensively,
  /// as OpenWebRX+'s RdsParser does. Unknown fields remain absent.
  bool apply(Map<String, dynamic> event) {
    if (event['source'] != 'rds' || event['version'] != 1) return false;
    if (event['event'] == 'reset') {
      clear();
      return true;
    }
    if (event['event'] != 'state' || event['fields'] is! Map) return false;
    final incoming = event['fields'] as Map;
    if (incoming.keys.any((key) => key is! String)) return false;
    final pi = incoming['pi'];
    if (pi is String && fields['pi'] != null && fields['pi'] != pi) clear();
    fields.addAll(incoming.cast<String, Object?>());
    if (event['sync'] is bool) synced = event['sync'] as bool;
    if (event['bler'] is num) bler = event['bler'] as num;
    return true;
  }

  String? text(String key) =>
      fields[key] is String ? fields[key] as String : null;
}

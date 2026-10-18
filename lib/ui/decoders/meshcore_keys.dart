// SPDX-License-Identifier: GPL-3.0-or-later
// MeshCore private channel settings. The firmware public channel is implicit.
import 'dart:convert';

const meshcoreMaxChannels = 8;
const meshcorePublicKey = '8b3387e9c5cdea6ac9e5edbaa115cd72';
final _hex = RegExp(r'^(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{64})$');

String? meshcoreChannelNameError(String name) {
  final length = utf8.encode(name).length;
  if (length < 1 || length > 32) return 'Name must be 1–32 UTF-8 bytes';
  return null;
}

String? meshcoreSecretError(String secret) =>
    _hex.hasMatch(secret) ? null : 'Secret must be 32 or 64 hexadecimal digits';

/// Reject the entire invalid configuration; do not silently drop private keys.
Object? normalizeMeshcoreChannels(Object value) {
  if (value is! List || value.length > meshcoreMaxChannels) return null;
  final names = <String>{};
  final out = <Map<String, String>>[];
  for (final entry in value) {
    if (entry is! Map ||
        entry['name'] is! String ||
        entry['secret'] is! String) {
      return null;
    }
    final name = entry['name'] as String;
    final secret = entry['secret'] as String;
    if (meshcoreChannelNameError(name) != null ||
        meshcoreSecretError(secret) != null ||
        !names.add(name) ||
        secret.toLowerCase() == meshcorePublicKey) {
      return null;
    }
    out.add(Map.unmodifiable({'name': name, 'secret': secret}));
  }
  return List<Map<String, String>>.unmodifiable(out);
}

List<({String name, String secret})> meshcoreChannels(Object? value) => [
  if (value is List)
    for (final entry in value)
      if (entry is Map && entry['name'] is String && entry['secret'] is String)
        (name: entry['name'] as String, secret: entry['secret'] as String),
];

Set<String> meshcoreKeySecrets(Object? channels) => {
  for (final channel in meshcoreChannels(channels))
    channel.secret.toLowerCase(),
};

/// Native events never contain keys. Scrub configured hex if a faulty backend
/// inadvertently includes one, including embedded values in arbitrary fields.
Object? redactMeshcoreSecrets(Object? value, Set<String> secrets) {
  if (value is String) {
    return secrets.any((secret) => value.toLowerCase().contains(secret))
        ? '[redacted]'
        : value;
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        if (entry.key != 'secret' && entry.key != 'channels')
          entry.key.toString(): redactMeshcoreSecrets(entry.value, secrets),
    };
  }
  if (value is List) {
    return [
      for (final element in value) redactMeshcoreSecrets(element, secrets),
    ];
  }
  return value;
}

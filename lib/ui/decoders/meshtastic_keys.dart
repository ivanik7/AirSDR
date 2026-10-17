// SPDX-License-Identifier: GPL-3.0-or-later
// Channel PSK settings for the `meshtastic` decoder. Validation mirrors the
// native packet layer (native/src/meshtastic/meshtastic.cpp `resolve_key`,
// firmware Channels::getKey) so the UI rejects exactly what native rejects.
// Keys are user data: error texts and summaries never contain key text, and
// packet JSON is scrubbed of configured keys before it is stored or shown.
import 'dart:convert';
import 'dart:typed_data';

/// Firmware `MAX_NUM_CHANNELS`; native `parse_config_json` enforces it too.
const meshtasticMaxChannels = 8;

/// `ChannelSettings.name` max_size 12 including the NUL terminator.
const meshtasticMaxChannelNameBytes = 11;

/// The firmware default PSK (`AQ==` expands to this key).
final Uint8List _defaultPsk = Uint8List.fromList(const [
  0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59, //
  0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01,
]);

/// A resolved channel key. [bytes] is empty for "no encryption".
class MeshtasticKey {
  const MeshtasticKey._(this.bytes, this.input, this.shortIndex);
  final Uint8List bytes;

  /// The decoded user input before firmware expansion/padding.
  final Uint8List input;

  /// Firmware short-PSK index (0 = no encryption, 1 = default key, …), or
  /// null for a full AES key.
  final int? shortIndex;

  /// The user typed a private key rather than a public short index.
  bool get isPrivate => shortIndex == null;

  /// Describes the key kind without revealing any key material.
  String get kind => switch (shortIndex) {
    0 => 'no encryption',
    1 => 'default key',
    final int n => 'default key #$n',
    null => 'AES-${bytes.length * 8}',
  };
}

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  return -1;
}

int _b64Value(int c) {
  if (c >= 0x41 && c <= 0x5a) return c - 0x41;
  if (c >= 0x61 && c <= 0x7a) return c - 0x61 + 26;
  if (c >= 0x30 && c <= 0x39) return c - 0x30 + 52;
  if (c == 0x2b) return 62;
  if (c == 0x2f) return 63;
  return -1;
}

/// Native `b64_strict`: padded standard alphabet, as Python
/// `base64.b64decode(validate=True)`.
List<int>? _b64Strict(String s) {
  if (s.length % 4 != 0) return null;
  var pad = 0;
  while (pad < 2 && pad < s.length && s.codeUnitAt(s.length - 1 - pad) == 0x3d) {
    pad++;
  }
  final out = <int>[];
  var acc = 0, bits = 0;
  for (var i = 0; i < s.length - pad; i++) {
    final v = _b64Value(s.codeUnitAt(i));
    if (v < 0) return null;
    acc = ((acc << 6) | v) & 0xffffff;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.add((acc >> bits) & 0xff);
    }
  }
  return out;
}

/// Resolves user key text exactly like native `resolve_key`. Throws a
/// [FormatException] whose message never contains the input.
MeshtasticKey resolveMeshtasticKey(String text) {
  final raw = text.trim();
  final low = raw.toLowerCase();
  List<int>? bytes;
  if (low == 'default' || low == 'aq==') {
    bytes = const [1];
  } else {
    var candidate = low.startsWith('0x') ? raw.substring(2) : raw;
    candidate = candidate.replaceAll(RegExp('[:-]'), '');
    final isHex = candidate.length.isEven &&
        candidate.codeUnits.every((c) => _hexValue(c) >= 0);
    if (isHex) {
      bytes = [
        for (var i = 0; i < candidate.length; i += 2)
          _hexValue(candidate.codeUnitAt(i)) * 16 +
              _hexValue(candidate.codeUnitAt(i + 1)),
      ];
    } else {
      bytes = _b64Strict(raw);
      if (bytes == null) {
        throw const FormatException('Key is neither hex nor valid base64');
      }
    }
  }
  if (bytes.isEmpty) throw const FormatException('Key is empty');
  if (bytes.length > 32) {
    throw const FormatException('Key is longer than 32 bytes');
  }
  final input = Uint8List.fromList(bytes);
  if (bytes.length == 1) {
    final index = bytes.first;
    if (index == 0) return MeshtasticKey._(Uint8List(0), input, 0);
    final key = Uint8List.fromList(_defaultPsk);
    key[15] = (key[15] + index - 1) & 0xff;
    return MeshtasticKey._(key, input, index);
  }
  final key = Uint8List(bytes.length <= 16 ? 16 : 32)..setAll(0, bytes);
  return MeshtasticKey._(key, input, null);
}

/// Error text for a channel name, or null if valid.
String? meshtasticChannelNameError(String name) {
  if (utf8.encode(name).length > meshtasticMaxChannelNameBytes) {
    return 'Channel name is longer than $meshtasticMaxChannelNameBytes bytes';
  }
  return null;
}

/// Error text for key input, or null if valid. Never echoes the input.
String? meshtasticKeyError(String psk) {
  try {
    resolveMeshtasticKey(psk);
    return null;
  } on FormatException catch (e) {
    return e.message;
  }
}

/// `DecoderSetting.normalize` for `channels`: keeps valid `{name, psk}`
/// entries (in priority order, at most [meshtasticMaxChannels]); returns
/// null when the value is not a list at all.
Object? normalizeMeshtasticChannels(Object value) {
  if (value is! List) return null;
  final out = <Object>[];
  for (final entry in value) {
    if (out.length >= meshtasticMaxChannels) break;
    if (entry is! Map) continue;
    final name = entry['name'] ?? '';
    final psk = entry['psk'];
    if (name is! String || psk is! String) continue;
    if (meshtasticChannelNameError(name) != null) continue;
    if (meshtasticKeyError(psk) != null) continue;
    out.add(<String, Object>{'name': name, 'psk': psk.trim()});
  }
  return List<Object>.unmodifiable(out);
}

/// Typed view of the stored `channels` setting.
List<({String name, String psk})> meshtasticChannels(Object? value) => [
  if (value is List)
    for (final entry in value)
      if (entry is Map && entry['name'] is String && entry['psk'] is String)
        (name: entry['name'] as String, psk: entry['psk'] as String),
];

/// Text forms of configured private keys that must never be displayed.
/// Short indexes and the public default key are not secrets.
Set<String> meshtasticKeySecrets(Object? channels) {
  final secrets = <String>{};
  for (final channel in meshtasticChannels(channels)) {
    final MeshtasticKey key;
    try {
      key = resolveMeshtasticKey(channel.psk);
    } on FormatException {
      continue;
    }
    if (!key.isPrivate) continue;
    String hex(List<int> b) =>
        b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    for (final form in {
      channel.psk.trim().toLowerCase(),
      hex(key.input),
      hex(key.bytes),
      base64.encode(key.input).toLowerCase(),
      base64.encode(key.bytes).toLowerCase(),
    }) {
      if (form.length >= 6) secrets.add(form);
    }
  }
  return secrets;
}

/// Replaces every JSON string that contains a configured key with
/// `[redacted]`. Native events never carry keys; this guards the UI anyway.
Object? redactMeshtasticSecrets(Object? value, Set<String> secrets) {
  if (secrets.isEmpty) return value;
  if (value is String) {
    final low = value.toLowerCase();
    return secrets.any(low.contains) ? '[redacted]' : value;
  }
  if (value is Map) {
    return <String, Object?>{
      for (final e in value.entries)
        e.key.toString(): redactMeshtasticSecrets(e.value, secrets),
    };
  }
  if (value is List) {
    return [for (final v in value) redactMeshtasticSecrets(v, secrets)];
  }
  return value;
}

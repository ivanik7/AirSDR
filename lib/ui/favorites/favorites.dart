// SPDX-License-Identifier: GPL-3.0-or-later
// Favorites only: no receiver, DSP or background monitoring state.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../decoders/decoder_contract.dart'
    show decoderById, decoderIdForMode, demodModeFromDecoderId;
export '../decoders/decoder_contract.dart'
    show decoderIdForMode, demodModeFromDecoderId;
import '../radio_controller.dart';

const favoriteCategories = ['Все', 'FM', 'AIR', 'VHF', 'MAR', 'UHF'];

/// Sentinel for [Favorite.copyWith]'s `decoderId`: "leave the decoder
/// selection (and its settings) exactly as it is", distinct from a real
/// `null` which explicitly clears the decoder back to plain voice/audio.
const Object _unchangedDecoder = Object();

/// `id` valid for a known decoder (voice/demod-mode id or a real data
/// decoder), else null (an unknown/removed/obsolete decoder id never
/// survives into a live [Favorite]). The historical literal `'voice'` id
/// is explicitly obsolete under the unified catalog — plain voice is
/// `decoderId == null` (the stored [Favorite.mode] governs), never a
/// stored `'voice'` string.
String? _normalizeDecoderId(Object? id) {
  if (id is! String || id == 'voice') return null;
  if (demodModeFromDecoderId(id) != null) return id;
  return decoderById(id) != null ? id : null;
}

/// Resolves [raw] against decoder [decoderId]'s declared settings
/// (decoder_contract.dart `DecoderSetting`): a present, allowed value is
/// kept, anything missing/invalid/unknown falls back to the setting's
/// default. Always returns a fresh map (copy isolation — callers never get
/// back a reference they handed in, and no two [Favorite]s can end up
/// sharing one mutable settings map).
Map<String, Object> _normalizeDecoderSettings(
  String? decoderId,
  Map<String, Object?>? raw,
) {
  final descriptor = decoderId == null ? null : decoderById(decoderId);
  if (descriptor == null) return const <String, Object>{};
  return <String, Object>{
    for (final spec in descriptor.settings)
      spec.key:
          (raw != null &&
              raw[spec.key] != null &&
              (spec.allowed.isEmpty || spec.allowed.contains(raw[spec.key])))
          ? raw[spec.key]!
          : spec.defaultValue,
  };
}

@immutable
class Favorite {
  const Favorite({
    required this.id,
    required this.frequencyHz,
    required this.name,
    required this.mode,
    required this.category,
    this.enabled = true,
    this.builtIn = false,
    this.decoderId,
    this.decoderSettings = const <String, Object>{},
  });
  final String id;
  final int frequencyHz;
  final String name;
  final DemodMode mode;
  final String category;
  final bool enabled;
  final bool builtIn;

  /// Decoder previewed/applied with this preset (decoder_contract.dart
  /// `DecoderDescriptor.id`), or null for the plain voice/audio path. Never
  /// an id the live [decoderCatalog] (via [decoderById]) doesn't recognize —
  /// storage v3 normalizes that away on load (see [FavoritesRepository]).
  final String? decoderId;

  /// Fully resolved settings of [decoderId] (every declared key present,
  /// defaulted where unset). Empty when [decoderId] is null. Own map
  /// instance per [Favorite] — never shared with another instance or with
  /// caller-owned storage.
  final Map<String, Object> decoderSettings;

  /// Decoder-catalog choice to show for this preset in the unified preset
  /// editor's single decoder dropdown: the stored [decoderId] when there
  /// is one, otherwise the explicit voice/demod-mode id for [mode]
  /// ([decoderIdForMode]) — never a "no decoder" sentinel, so the dropdown
  /// always has a concrete, valid selection without mutating stored data.
  /// A built-in constructed with `decoderId: null` (storage-untouched)
  /// still resolves to a real choice here purely for display.
  String get decoderChoice => decoderId ?? decoderIdForMode(mode);

  Favorite copyWith({
    String? name,
    DemodMode? mode,
    String? category,
    bool? enabled,
    Object? decoderId = _unchangedDecoder,
    Map<String, Object>? decoderSettings,
  }) {
    final unchanged = identical(decoderId, _unchangedDecoder);
    final newDecoderId = unchanged
        ? this.decoderId
        : _normalizeDecoderId(decoderId);
    // An explicit voice/demod-mode decoder id always pins the mode it
    // encodes — it can never contradict `mode` (see decoderIdForMode's
    // doc). A data decoder id or no decoder at all leaves `mode`
    // resolution exactly as before (new value, else unchanged).
    final explicitMode = demodModeFromDecoderId(newDecoderId);
    final newMode = explicitMode ?? (mode ?? this.mode);
    final newSettings = unchanged
        ? _normalizeDecoderSettings(
            newDecoderId,
            decoderSettings ?? this.decoderSettings,
          )
        : _normalizeDecoderSettings(newDecoderId, decoderSettings);
    return Favorite(
      id: id,
      frequencyHz: frequencyHz,
      name: name ?? this.name,
      mode: newMode,
      category: category ?? this.category,
      enabled: enabled ?? this.enabled,
      builtIn: builtIn,
      decoderId: newDecoderId,
      decoderSettings: newSettings,
    );
  }

  Map<String, Object> toJson() {
    final json = <String, Object>{
      'id': id,
      'frequencyHz': frequencyHz,
      'name': name,
      'mode': mode.label,
      'category': category,
      'enabled': enabled,
      'builtIn': builtIn,
    };
    final decoder = decoderId;
    if (decoder != null) {
      json['decoderId'] = decoder;
      json['decoderSettingsVersion'] =
          FavoritesRepository.decoderSettingsSchemaVersion;
      json['decoderSettings'] = decoderSettings;
    }
    return json;
  }
}

// Default presets offered once to every install. IDs are stable: a default
// the user deleted is remembered in `seenDefaults` and never re-added.
const builtInFavorites = <Favorite>[
  Favorite(
    id: 'builtin-fm',
    frequencyHz: 100000000,
    mode: DemodMode.wfm,
    name: 'FM Radio',
    category: 'FM',
    builtIn: true,
  ),
  Favorite(
    id: 'builtin-air',
    frequencyHz: 125000000,
    mode: DemodMode.am,
    name: 'Air Traffic',
    category: 'AIR',
    builtIn: true,
  ),
  Favorite(
    id: 'builtin-ism',
    frequencyHz: 433000000,
    mode: DemodMode.am,
    name: 'ISM Band',
    category: 'UHF',
    builtIn: true,
  ),
];

/// The 12-entry archive pool of storage v1 (`builtin-<index>`): name, mode,
/// category as shipped. Used only to migrate old saves.
const _legacyPool = <(String, DemodMode, String)>[
  ('Симплекс 2м', DemodMode.nfm, 'VHF'),
  ('PMR вызов', DemodMode.nfm, 'UHF'),
  ('Вышка / TWR', DemodMode.am, 'AIR'),
  ('Guard 121.5', DemodMode.am, 'AIR'),
  ('Морской 16', DemodMode.nfm, 'MAR'),
  ('FM радио', DemodMode.wfm, 'FM'),
  ('GMRS 1', DemodMode.nfm, 'UHF'),
  ('PMR446 1', DemodMode.nfm, 'UHF'),
  ('Погода WX', DemodMode.nfm, 'MAR'),
  ('ACARS', DemodMode.am, 'AIR'),
  ('Служебный', DemodMode.nfm, 'VHF'),
  ('Радио 88.6', DemodMode.wfm, 'FM'),
];
final _legacyId = RegExp(r'^builtin-(\d+)$');
final _userId = RegExp(r'^user-(\d+)$');

class FavoritesRepository extends ChangeNotifier {
  FavoritesRepository();
  static const storageKey = 'single_vfo_favorites_v1';

  /// v1: 12 archive built-ins re-added on every load. v2: [builtInFavorites]
  /// plus `seenDefaults` (defaults already offered, deleted ones included).
  /// v3: per-entry optional decoder selection (`decoderId` +
  /// `decoderSettingsVersion` + `decoderSettings`); v1/v2 entries (no
  /// decoder keys), an entry with an unrecognized `decoderId`, and an entry
  /// whose `decoderSettingsVersion` does not match
  /// [decoderSettingsSchemaVersion] all load as plain voice/audio (decoder
  /// cleared) rather than being rejected or guessed at — only the decoder
  /// attachment is dropped, the preset itself survives.
  static const storageVersion = 3;

  /// Schema version of a single entry's `decoderSettings` map. Bumped
  /// whenever the *shape* of a decoder's settings changes in a
  /// backward-incompatible way (not merely a new decoder/catalog entry);
  /// an entry stamped with a different version is treated as an unknown/
  /// invalid decoder attachment on load (see [storageVersion]).
  static const decoderSettingsSchemaVersion = 1;

  final List<Favorite> _entries = [...builtInFavorites];
  final Set<String> _seenDefaults = {for (final f in builtInFavorites) f.id};
  List<Favorite> get entries => List.unmodifiable(_entries);
  List<Favorite> filtered(String category) => List.unmodifiable(
    _entries.where((f) => category == 'Все' || f.category == category),
  );
  bool _changed = false;
  int _nextId = 0;
  Future<void> _pending = Future.value();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (_changed) return; // user actions before asynchronous load always win
    try {
      final encoded = prefs.getString(storageKey);
      if (encoded == null) return;
      final data = jsonDecode(encoded) as Map<String, dynamic>;
      final version = (data['version'] as num?)?.toInt() ?? 1;
      final saved = data['entries'] as List;
      var nextId = (data['nextId'] as num?)?.toInt() ?? 0;
      for (final raw in saved) {
        final id = (raw as Map<String, dynamic>)['id'];
        final n = id is String ? _userId.firstMatch(id) : null;
        if (n != null) nextId = max(nextId, int.parse(n.group(1)!) + 1);
      }
      final parsed = <Favorite>[];
      for (final raw in saved) {
        final m = raw as Map<String, dynamic>;
        var id = m['id'] as String;
        final hz = m['frequencyHz'] as int;
        final mode = DemodMode.values.firstWhere((v) => v.label == m['mode']);
        final category = m['category'] as String;
        final name = m['name'] as String;
        if (!favoriteCategories.contains(category) ||
            category == 'Все' ||
            hz <= 0 ||
            hz > 999999999999 ||
            parsed.any((e) => e.id == id || e.frequencyHz == hz)) {
          continue;
        }
        var builtIn = id.startsWith('builtin-');
        final legacy = version < 2 ? _legacyId.firstMatch(id) : null;
        if (legacy != null) {
          // Old archive built-in: drop it unless the user edited its name,
          // mode or category (the bookmark toggle is not an edit) — then it
          // is the user's own preset now.
          final i = int.parse(legacy.group(1)!);
          if (i < _legacyPool.length &&
              _legacyPool[i] == (name, mode, category)) {
            continue;
          }
          id = 'user-${nextId++}';
          builtIn = false;
        }
        // Storage v3: a recognized decoder id stamped with the current
        // settings schema version; anything else (v1/v2 entries without
        // the keys at all, an unknown id, a mismatched settings version)
        // normalizes to "no decoder" — never an unknown/invalid decoder
        // reaching the UI, and never dropping the favorite itself for it.
        final rawDecoderId = m['decoderId'];
        final decoderVersion = (m['decoderSettingsVersion'] as num?)?.toInt();
        final decoderId =
            rawDecoderId is String &&
                decoderVersion == decoderSettingsSchemaVersion
            ? _normalizeDecoderId(rawDecoderId)
            : null;
        final rawSettings = m['decoderSettings'];
        final decoderSettings = _normalizeDecoderSettings(
          decoderId,
          rawSettings is Map
              ? rawSettings.map((k, v) => MapEntry(k.toString(), v as Object?))
              : null,
        );
        // A recognized explicit voice/demod-mode decoder id always pins
        // the receive mode it encodes (decoderIdForMode) — it overrides a
        // stored `mode` that happens to disagree. Legacy data (no
        // decoderId at all, or the obsolete literal `'voice'`, both of
        // which normalize `decoderId` to null above) has no such pin: the
        // stored `mode` stays authoritative exactly as before storage v3
        // ever had decoders. A data-decoder id (sstv/rtl_433/adsb) never
        // encodes a mode either, so it also leaves the stored mode as-is.
        final explicitMode = demodModeFromDecoderId(decoderId);
        parsed.add(
          Favorite(
            id: id,
            frequencyHz: hz,
            name: name,
            mode: explicitMode ?? mode,
            category: category,
            enabled: m['enabled'] == true,
            builtIn: builtIn,
            decoderId: decoderId,
            decoderSettings: decoderSettings,
          ),
        );
      }
      final seen = <String>{
        if (version >= 2)
          for (final s in (data['seenDefaults'] as List? ?? const []))
            s as String,
      };
      // Offer each default exactly once, before the user's presets; skip it
      // if the user already has that frequency. Deleted defaults stay seen.
      final fresh = <Favorite>[
        for (final item in builtInFavorites)
          if (!seen.contains(item.id) &&
              !parsed.any(
                (e) => e.id == item.id || e.frequencyHz == item.frequencyHz,
              ))
            item,
      ];
      final migrated =
          version < storageVersion ||
          builtInFavorites.any((item) => !seen.contains(item.id));
      seen.addAll(builtInFavorites.map((f) => f.id));
      if (_changed) return;
      _entries
        ..clear()
        ..addAll(fresh)
        ..addAll(parsed);
      _seenDefaults
        ..clear()
        ..addAll(seen);
      _nextId = nextId;
      if (migrated) _write();
      notifyListeners();
    } catch (_) {
      // Corrupt data must not destroy the default presets.
    }
  }

  void _write() {
    final encoded = jsonEncode({
      'version': storageVersion,
      'nextId': _nextId,
      'seenDefaults': _seenDefaults.toList(),
      'entries': _entries.map((e) => e.toJson()).toList(),
    });
    _pending = _pending.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, encoded);
    });
  }

  void _save() {
    _changed = true;
    _write();
    notifyListeners();
  }

  Future<void> flush() => _pending;

  void toggle(String id) {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i < 0) throw ArgumentError.value(id, 'id');
    _entries[i] = _entries[i].copyWith(enabled: !_entries[i].enabled);
    _save();
  }

  Favorite add({
    required int frequencyHz,
    required String name,
    required DemodMode mode,
    required String category,
    int minHz = 1,
    int maxHz = 999999999999,
    String? decoderId,
    Map<String, Object>? decoderSettings,
  }) {
    _validate(frequencyHz, name, category, minHz, maxHz);
    if (_entries.any((e) => e.frequencyHz == frequencyHz)) {
      throw ArgumentError.value(frequencyHz, 'frequencyHz', 'Already saved');
    }
    final normalizedId = _normalizeDecoderId(decoderId);
    // A newly saved explicit voice/demod-mode choice always wins over a
    // caller-passed `mode` that disagrees with it — see decoderIdForMode.
    final explicitMode = demodModeFromDecoderId(normalizedId);
    final f = Favorite(
      id: 'user-${_nextId++}',
      frequencyHz: frequencyHz,
      name: name.trim(),
      mode: explicitMode ?? mode,
      category: category,
      decoderId: normalizedId,
      decoderSettings: _normalizeDecoderSettings(normalizedId, decoderSettings),
    );
    _entries.add(f);
    _save();
    return f;
  }

  /// [decoderId]/[decoderSettings] default to leaving the preset's current
  /// decoder selection untouched; pass `decoderId: null` explicitly to clear
  /// it back to plain voice/audio.
  void edit(
    String id, {
    required String name,
    required DemodMode mode,
    required String category,
    Object? decoderId = _unchangedDecoder,
    Map<String, Object>? decoderSettings,
  }) {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i < 0) throw ArgumentError.value(id, 'id');
    _validate(_entries[i].frequencyHz, name, category, 1, 999999999999);
    _entries[i] = _entries[i].copyWith(
      name: name.trim(),
      mode: mode,
      category: category,
      decoderId: decoderId,
      decoderSettings: decoderSettings,
    );
    _save();
  }

  void delete(String id) {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i < 0) throw ArgumentError.value(id, 'id');
    // Built-in defaults are deletable too; `_seenDefaults` keeps them gone.
    _entries.removeAt(i);
    _save();
  }

  static void _validate(
    int hz,
    String name,
    String category,
    int min,
    int max,
  ) {
    if (hz < min || hz > max || hz <= 0 || hz > 999999999999) {
      throw ArgumentError.value(hz, 'frequencyHz');
    }
    if (name.trim().isEmpty || name.trim().length > 60) {
      throw ArgumentError.value(name, 'name');
    }
    if (!favoriteCategories.contains(category) || category == 'Все') {
      throw ArgumentError.value(category, 'category');
    }
  }
}

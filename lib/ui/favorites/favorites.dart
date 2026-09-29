// SPDX-License-Identifier: GPL-3.0-or-later
// Favorites only: no receiver, DSP or background monitoring state.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../radio_controller.dart';

const favoriteCategories = ['Все', 'FM', 'AIR', 'VHF', 'MAR', 'UHF'];

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
  });
  final String id;
  final int frequencyHz;
  final String name;
  final DemodMode mode;
  final String category;
  final bool enabled;
  final bool builtIn;

  Favorite copyWith({
    String? name,
    DemodMode? mode,
    String? category,
    bool? enabled,
  }) => Favorite(
    id: id,
    frequencyHz: frequencyHz,
    name: name ?? this.name,
    mode: mode ?? this.mode,
    category: category ?? this.category,
    enabled: enabled ?? this.enabled,
    builtIn: builtIn,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'frequencyHz': frequencyHz,
    'name': name,
    'mode': mode.label,
    'category': category,
    'enabled': enabled,
    'builtIn': builtIn,
  };
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
  static const storageVersion = 2;
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
        parsed.add(
          Favorite(
            id: id,
            frequencyHz: hz,
            name: name,
            mode: mode,
            category: category,
            enabled: m['enabled'] == true,
            builtIn: builtIn,
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
          version < 2 ||
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
  }) {
    _validate(frequencyHz, name, category, minHz, maxHz);
    if (_entries.any((e) => e.frequencyHz == frequencyHz)) {
      throw ArgumentError.value(frequencyHz, 'frequencyHz', 'Already saved');
    }
    final f = Favorite(
      id: 'user-${_nextId++}',
      frequencyHz: frequencyHz,
      name: name.trim(),
      mode: mode,
      category: category,
    );
    _entries.add(f);
    _save();
    return f;
  }

  void edit(
    String id, {
    required String name,
    required DemodMode mode,
    required String category,
  }) {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i < 0) throw ArgumentError.value(id, 'id');
    _validate(_entries[i].frequencyHz, name, category, 1, 999999999999);
    _entries[i] = _entries[i].copyWith(
      name: name.trim(),
      mode: mode,
      category: category,
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

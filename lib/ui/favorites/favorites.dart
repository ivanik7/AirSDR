// SPDX-License-Identifier: GPL-3.0-or-later
// Favorites only: no receiver, DSP or background monitoring state.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../radio_controller.dart';

const favoriteCategories = ['Все', 'FM', 'AIR', 'VHF', 'MAR', 'UHF'];

@immutable
class Favorite {
  const Favorite({required this.id, required this.frequencyHz, required this.name,
    required this.mode, required this.category, this.enabled = true, this.builtIn = false});
  final String id;
  final int frequencyHz;
  final String name;
  final DemodMode mode;
  final String category;
  final bool enabled;
  final bool builtIn;

  Favorite copyWith({String? name, DemodMode? mode, String? category, bool? enabled}) =>
      Favorite(id: id, frequencyHz: frequencyHz, name: name ?? this.name,
        mode: mode ?? this.mode, category: category ?? this.category,
        enabled: enabled ?? this.enabled, builtIn: builtIn);

  Map<String, Object> toJson() => {'id': id, 'frequencyHz': frequencyHz, 'name': name,
    'mode': mode.label, 'category': category, 'enabled': enabled, 'builtIn': builtIn};
}

// Exact archive pool frequencies/names/categories, with stable IDs by original index.
const builtInFavorites = <Favorite>[
  Favorite(id: 'builtin-0', frequencyHz: 145500000, mode: DemodMode.nfm, name: 'Симплекс 2м', category: 'VHF'),
  Favorite(id: 'builtin-1', frequencyHz: 433500000, mode: DemodMode.nfm, name: 'PMR вызов', category: 'UHF'),
  Favorite(id: 'builtin-2', frequencyHz: 118100000, mode: DemodMode.am, name: 'Вышка / TWR', category: 'AIR'),
  Favorite(id: 'builtin-3', frequencyHz: 121500000, mode: DemodMode.am, name: 'Guard 121.5', category: 'AIR'),
  Favorite(id: 'builtin-4', frequencyHz: 156800000, mode: DemodMode.nfm, name: 'Морской 16', category: 'MAR'),
  Favorite(id: 'builtin-5', frequencyHz: 101200000, mode: DemodMode.wfm, name: 'FM радио', category: 'FM'),
  Favorite(id: 'builtin-6', frequencyHz: 462562000, mode: DemodMode.nfm, name: 'GMRS 1', category: 'UHF'),
  Favorite(id: 'builtin-7', frequencyHz: 446006000, mode: DemodMode.nfm, name: 'PMR446 1', category: 'UHF'),
  Favorite(id: 'builtin-8', frequencyHz: 162550000, mode: DemodMode.nfm, name: 'Погода WX', category: 'MAR'),
  Favorite(id: 'builtin-9', frequencyHz: 131550000, mode: DemodMode.am, name: 'ACARS', category: 'AIR'),
  Favorite(id: 'builtin-10', frequencyHz: 169000000, mode: DemodMode.nfm, name: 'Служебный', category: 'VHF'),
  Favorite(id: 'builtin-11', frequencyHz: 88600000, mode: DemodMode.wfm, name: 'Радио 88.6', category: 'FM'),
];

class FavoritesRepository extends ChangeNotifier {
  FavoritesRepository();
  static const storageKey = 'single_vfo_favorites_v1';
  final List<Favorite> _entries = [...builtInFavorites];
  List<Favorite> get entries => List.unmodifiable(_entries);
  List<Favorite> filtered(String category) => List.unmodifiable(
      _entries.where((f) => category == 'Все' || f.category == category));
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
      final saved = data['entries'] as List;
      final parsed = <Favorite>[];
      for (final raw in saved) {
        final m = raw as Map<String, dynamic>;
        final id = m['id'] as String;
        final hz = m['frequencyHz'] as int;
        final mode = DemodMode.values.firstWhere((v) => v.label == m['mode']);
        final category = m['category'] as String;
        if (!favoriteCategories.contains(category) || category == 'Все' || hz <= 0 || hz > 999999999999 ||
            parsed.any((e) => e.id == id || e.frequencyHz == hz)) continue;
        parsed.add(Favorite(id: id, frequencyHz: hz, name: m['name'] as String,
            mode: mode, category: category, enabled: m['enabled'] == true, builtIn: id.startsWith('builtin-')));
      }
      // Keep built-ins that were added in newer versions; preserve saved order.
      for (final item in builtInFavorites) {
        if (!parsed.any((e) => e.id == item.id || e.frequencyHz == item.frequencyHz)) parsed.add(item);
      }
      if (_changed) return;
      _entries..clear()..addAll(parsed);
      _nextId = (data['nextId'] as num?)?.toInt() ?? 0;
      notifyListeners();
    } catch (_) {
      // Corrupt data must not destroy the original built-in pool.
    }
  }

  void _save() {
    _changed = true;
    final encoded = jsonEncode({'nextId': _nextId, 'entries': _entries.map((e) => e.toJson()).toList()});
    _pending = _pending.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, encoded);
    });
    notifyListeners();
  }
  Future<void> flush() => _pending;

  void toggle(String id) {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i < 0) throw ArgumentError.value(id, 'id');
    _entries[i] = _entries[i].copyWith(enabled: !_entries[i].enabled);
    _save();
  }

  Favorite add({required int frequencyHz, required String name, required DemodMode mode, required String category,
    int minHz = 1, int maxHz = 999999999999}) {
    _validate(frequencyHz, name, category, minHz, maxHz);
    if (_entries.any((e) => e.frequencyHz == frequencyHz)) throw ArgumentError.value(frequencyHz, 'frequencyHz', 'Already saved');
    final f = Favorite(id: 'user-${_nextId++}', frequencyHz: frequencyHz,
        name: name.trim(), mode: mode, category: category);
    _entries.add(f);
    _save();
    return f;
  }

  void edit(String id, {required String name, required DemodMode mode, required String category}) {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i < 0) throw ArgumentError.value(id, 'id');
    _validate(_entries[i].frequencyHz, name, category, 1, 999999999999);
    _entries[i] = _entries[i].copyWith(name: name.trim(), mode: mode, category: category);
    _save();
  }

  void delete(String id) {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i < 0 || _entries[i].builtIn) throw ArgumentError.value(id, 'id', 'Built-in: toggle instead');
    _entries.removeAt(i);
    _save();
  }

  static void _validate(int hz, String name, String category, int min, int max) {
    if (hz < min || hz > max || hz <= 0 || hz > 999999999999) throw ArgumentError.value(hz, 'frequencyHz');
    if (name.trim().isEmpty || name.trim().length > 60) throw ArgumentError.value(name, 'name');
    if (!favoriteCategories.contains(category) || category == 'Все') throw ArgumentError.value(category, 'category');
  }
}

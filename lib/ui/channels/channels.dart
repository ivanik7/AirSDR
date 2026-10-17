// SPDX-License-Identifier: GPL-3.0-or-later
//
// Receiver channel slots (like VFO memories on a handheld): each slot keeps its
// own frequency + mode, exactly one slot is active and drives the single
// receiver. This is NOT multi-channel reception: there is still one VFO and one
// audio stream; inactive slots are just stored settings.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../radio_controller.dart';

@immutable
class ReceiverChannel {
  const ReceiverChannel({
    required this.id,
    required this.name,
    required this.frequencyHz,
    required this.mode,
  });
  final String id;
  final String name;
  final int frequencyHz;
  final DemodMode mode;

  ReceiverChannel copyWith({String? name, int? frequencyHz, DemodMode? mode}) =>
      ReceiverChannel(
        id: id,
        name: name ?? this.name,
        frequencyHz: frequencyHz ?? this.frequencyHz,
        mode: mode ?? this.mode,
      );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'frequencyHz': frequencyHz,
    'mode': mode.label,
  };
}

/// Ordered, persisted list of channel slots plus the id of the active one.
/// Stored separately from favorites (`FavoritesRepository`).
class ChannelsRepository extends ChangeNotifier {
  ChannelsRepository();
  static const storageKey = 'receiver_channels_v1';
  static const maxNameLength = 60;

  final List<ReceiverChannel> _channels = [];
  String? _activeId;
  int _nextId = 0;
  bool _changed = false;
  bool _loaded = false;
  bool _hadStoredData = false;
  Future<void> _pending = Future.value();

  List<ReceiverChannel> get channels => List.unmodifiable(_channels);
  int get length => _channels.length;
  String? get activeId => _activeId;
  ReceiverChannel? get active {
    final i = _indexOf(_activeId);
    return i < 0 ? null : _channels[i];
  }

  int indexOf(String id) => _indexOf(id);

  /// True once [load] has finished (successfully or not).
  bool get loaded => _loaded;

  /// Whether anything was stored before this run (false on first launch).
  bool get hadStoredData => _hadStoredData;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      if (_changed) return; // user actions before the async load always win
      final encoded = prefs.getString(storageKey);
      if (encoded == null) return;
      _hadStoredData = true;
      final data = jsonDecode(encoded) as Map<String, dynamic>;
      final parsed = <ReceiverChannel>[];
      for (final raw in data['entries'] as List) {
        try {
          final m = raw as Map<String, dynamic>;
          final id = m['id'] as String;
          final hz = (m['frequencyHz'] as num).toInt();
          final name = (m['name'] as String).trim();
          final mode = DemodMode.values.firstWhere((v) => v.label == m['mode']);
          if (hz <= 0 ||
              hz > 999999999999 ||
              name.isEmpty ||
              parsed.any((e) => e.id == id)) {
            continue;
          }
          parsed.add(
            ReceiverChannel(id: id, name: name, frequencyHz: hz, mode: mode),
          );
        } catch (_) {
          // Skip a corrupt entry, keep the rest.
        }
      }
      _channels
        ..clear()
        ..addAll(parsed);
      final active = data['activeId'];
      _activeId = active is String && _indexOf(active) >= 0
          ? active
          : (_channels.isEmpty ? null : _channels.first.id);
      _nextId = (data['nextId'] as num?)?.toInt() ?? 0;
      for (final c in _channels) {
        final n = int.tryParse(c.id.replaceFirst('ch-', ''));
        if (n != null && n >= _nextId) _nextId = n + 1;
      }
    } catch (_) {
      // Corrupt storage: start empty rather than crash.
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  int _indexOf(String? id) =>
      id == null ? -1 : _channels.indexWhere((c) => c.id == id);

  void _save() {
    _changed = true;
    final encoded = jsonEncode({
      'nextId': _nextId,
      'activeId': _activeId,
      'entries': _channels.map((e) => e.toJson()).toList(),
    });
    _pending = _pending.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, encoded);
    });
    notifyListeners();
  }

  Future<void> flush() => _pending;

  static String _validName(String name) {
    final n = name.trim();
    if (n.isEmpty || n.length > maxNameLength) {
      throw ArgumentError.value(name, 'name');
    }
    return n;
  }

  /// Appends a slot and makes it active.
  ReceiverChannel add({
    required int frequencyHz,
    required DemodMode mode,
    String? name,
  }) {
    if (frequencyHz <= 0 || frequencyHz > 999999999999) {
      throw ArgumentError.value(frequencyHz, 'frequencyHz');
    }
    final id = 'ch-${_nextId++}';
    final c = ReceiverChannel(
      id: id,
      name: _validName(name ?? 'Channel $_nextId'),
      frequencyHz: frequencyHz,
      mode: mode,
    );
    _channels.add(c);
    _activeId = id;
    _save();
    return c;
  }

  /// Makes [id] the active slot; `null` leaves no active slot.
  void activate(String? id) {
    if (id != null && _indexOf(id) < 0) throw ArgumentError.value(id, 'id');
    if (_activeId == id) return;
    _activeId = id;
    _save();
  }

  /// Writes the receiver's frequency/mode into the active slot (only).
  /// Returns false when there is no active slot or nothing changed.
  bool updateActive({required int frequencyHz, required DemodMode mode}) {
    final i = _indexOf(_activeId);
    if (i < 0 || frequencyHz <= 0) return false;
    final c = _channels[i];
    if (c.frequencyHz == frequencyHz && c.mode == mode) return false;
    _channels[i] = c.copyWith(frequencyHz: frequencyHz, mode: mode);
    _save();
    return true;
  }

  /// Removes a slot. If it was active, the neighbour that takes its place
  /// (or the previous one at the end of the list) becomes active; removing
  /// the last slot leaves no active channel.
  void delete(String id) {
    final i = _indexOf(id);
    if (i < 0) throw ArgumentError.value(id, 'id');
    _channels.removeAt(i);
    if (_activeId == id) {
      _activeId = _channels.isEmpty
          ? null
          : _channels[i < _channels.length ? i : _channels.length - 1].id;
    }
    _save();
  }

  /// Moves slot [id] to position [toIndex] (in the list after removal).
  /// The active slot stays active.
  void move(String id, int toIndex) {
    final from = _indexOf(id);
    if (from < 0) throw ArgumentError.value(id, 'id');
    final to = toIndex.clamp(0, _channels.length - 1);
    if (from == to) return;
    final c = _channels.removeAt(from);
    _channels.insert(to, c);
    _save();
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// Frequency bands (task t_7b20878c): named, non-overlapping frequency ranges
// with their own demodulation mode and tuning step. The receiver looks the
// band up by frequency (CenteredReceiver), the Приём status shows its name,
// the Пресеты tab groups presets by band. Stored like FavoritesRepository:
// SharedPreferences JSON, defaults offered once (`seenDefaults`), corrupt
// data falls back to the default set.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../favorites/favorites.dart';
import '../legacy/step_grid.dart' show formatMhz;
import '../radio_controller.dart';

/// Tuning steps of the receiver (Hz); a band's step is one of these.
/// `CenteredReceiver.steps` is this list.
const receiverSteps = <int>[
  5000,
  6250,
  10000,
  12500,
  25000,
  100000,
  200000,
  1000000,
];

/// Allowed band limits: any positive frequency up to the top of the widest
/// supported device (HackRF, 6 GHz). Bands are device independent.
const bandMinHz = 1;
const bandMaxHz = 6000000000;
const bandMaxNameLength = 40;

@immutable
class Band {
  const Band({
    required this.id,
    required this.name,
    required this.startHz,
    required this.endHz,
    required this.mode,
    required this.stepHz,
  });
  final String id;
  final String name;

  /// Inclusive limits, integer Hz.
  final int startHz;
  final int endHz;
  final DemodMode mode;
  final int stepHz;

  bool contains(int hz) => hz >= startHz && hz <= endHz;

  /// Closed ranges: a shared boundary Hz is an overlap too.
  bool overlaps(int start, int end) => startHz <= end && start <= endHz;

  Band copyWith({
    String? name,
    int? startHz,
    int? endHz,
    DemodMode? mode,
    int? stepHz,
  }) => Band(
    id: id,
    name: name ?? this.name,
    startHz: startHz ?? this.startHz,
    endHz: endHz ?? this.endHz,
    mode: mode ?? this.mode,
    stepHz: stepHz ?? this.stepHz,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'startHz': startHz,
    'endHz': endHz,
    'mode': mode.label,
    'stepHz': stepHz,
  };
}

/// Default bands, ITU Region 1 / Kazakhstan, sorted and non-overlapping.
/// Ids are stable: a default the user deleted stays deleted.
///
/// CB uses its lower edge as the grid origin: CEPT channels are
/// 26.965 + 10 kHz·n, not multiples of 10 kHz from zero.
/// GSM downlinks use RAW: GSM is digital (GMSK/TDMA), no demodulator gives
/// intelligible audio; RAW is the honest "just look at the spectrum" mode.
const defaultBands = <Band>[
  Band(
    id: 'band-cb27',
    name: 'CB 27 МГц',
    startHz: 26965000,
    endHz: 27405000,
    mode: DemodMode.am,
    stepHz: 10000,
  ),
  Band(
    id: 'band-fm',
    name: 'FM',
    startHz: 87500000,
    endHz: 108000000,
    mode: DemodMode.wfm,
    stepHz: 100000,
  ),
  Band(
    id: 'band-air',
    name: 'Авиа',
    startHz: 118000000,
    endHz: 136975000,
    mode: DemodMode.am,
    stepHz: 25000,
  ),
  Band(
    id: 'band-2m',
    name: '2 м (любительский)',
    startHz: 144000000,
    endHz: 146000000,
    mode: DemodMode.nfm,
    stepHz: 12500,
  ),
  Band(
    id: 'band-marine',
    name: 'Морской',
    startHz: 156000000,
    endHz: 162025000,
    mode: DemodMode.nfm,
    stepHz: 25000,
  ),
  Band(
    id: 'band-ism433',
    name: 'ISM 433',
    startHz: 433050000,
    endHz: 434790000,
    mode: DemodMode.am,
    stepHz: 25000,
  ),
  Band(
    id: 'band-pmr446',
    name: 'PMR446',
    startHz: 446000000,
    endHz: 446200000,
    mode: DemodMode.nfm,
    stepHz: 6250,
  ),
  Band(
    id: 'band-ism868',
    name: 'ISM 868',
    startHz: 863000000,
    endHz: 870000000,
    mode: DemodMode.am,
    stepHz: 25000,
  ),
  Band(
    id: 'band-gsm900',
    name: 'GSM 900',
    startHz: 925000000,
    endHz: 960000000,
    mode: DemodMode.raw,
    stepHz: 200000,
  ),
  Band(
    id: 'band-gsm1800',
    name: 'GSM 1800',
    startHz: 1805000000,
    endHz: 1880000000,
    mode: DemodMode.raw,
    stepHz: 200000,
  ),
];

enum BandIssue { name, order, outOfRange, step, overlap }

/// A rejected band; [message] is the text shown in the form.
class BandValidationException implements Exception {
  const BandValidationException(this.issue, [this.conflict]);
  final BandIssue issue;

  /// The existing band this one overlaps ([BandIssue.overlap]).
  final Band? conflict;

  String get message => switch (issue) {
    BandIssue.name => 'введите название (1–$bandMaxNameLength символов)',
    BandIssue.order => 'начало должно быть меньше конца',
    BandIssue.outOfRange =>
      'частота вне допустимого диапазона (0–${bandMaxHz ~/ 1000000} МГц)',
    BandIssue.step => 'шаг не из списка',
    BandIssue.overlap => 'пересечение с «${conflict!.name}»',
  };

  @override
  String toString() => 'BandValidationException: $message';
}

class BandsRepository extends ChangeNotifier {
  BandsRepository();
  static const storageKey = 'frequency_bands_v1';
  static const storageVersion = 1;

  final List<Band> _entries = [...defaultBands];
  final Set<String> _seenDefaults = {for (final b in defaultBands) b.id};
  int _nextId = 0;
  bool _changed = false;
  Future<void> _pending = Future.value();

  /// Sorted by start frequency.
  List<Band> get entries => List.unmodifiable(_entries);

  /// The band containing [hz] (inclusive limits), or null.
  Band? bandAt(int hz) {
    for (final b in _entries) {
      if (b.contains(hz)) return b;
    }
    return null;
  }

  Band? byId(String id) => _entries.where((b) => b.id == id).firstOrNull;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (_changed) return; // user actions before the async load always win
    try {
      final encoded = prefs.getString(storageKey);
      if (encoded == null) {
        // Clean install or first run of a version with bands: write the
        // default set once, so later deletions are remembered.
        _write();
        return;
      }
      final data = jsonDecode(encoded) as Map<String, dynamic>;
      final saved = data['entries'] as List;
      final parsed = <Band>[];
      var nextId = (data['nextId'] as num?)?.toInt() ?? 0;
      for (final raw in saved) {
        final m = raw as Map<String, dynamic>;
        final id = m['id'];
        if (id is! String) continue;
        final n = RegExp(r'^user-(\d+)$').firstMatch(id);
        if (n != null) nextId = max(nextId, int.parse(n.group(1)!) + 1);
        final mode = DemodMode.values
            .where((v) => v.label == m['mode'])
            .firstOrNull;
        final name = m['name'];
        final start = m['startHz'];
        final end = m['endHz'];
        final step = m['stepHz'];
        if (mode == null ||
            name is! String ||
            start is! int ||
            end is! int ||
            step is! int ||
            parsed.any((b) => b.id == id) ||
            check(
                  name: name,
                  startHz: start,
                  endHz: end,
                  stepHz: step,
                  among: parsed,
                ) !=
                null) {
          continue; // skip a corrupt entry, keep the rest
        }
        parsed.add(
          Band(
            id: id,
            name: name.trim(),
            startHz: start,
            endHz: end,
            mode: mode,
            stepHz: step,
          ),
        );
      }
      final seen = <String>{
        for (final s in (data['seenDefaults'] as List? ?? const []))
          if (s is String) s,
      };
      // A default added in a later version is offered once, if it fits.
      final fresh = <Band>[
        for (final d in defaultBands)
          if (!seen.contains(d.id) &&
              !parsed.any(
                (b) => b.id == d.id || b.overlaps(d.startHz, d.endHz),
              ))
            d,
      ];
      final migrated = defaultBands.any((d) => !seen.contains(d.id));
      seen.addAll(defaultBands.map((d) => d.id));
      if (_changed) return;
      _entries
        ..clear()
        ..addAll(parsed)
        ..addAll(fresh);
      _sort();
      _seenDefaults
        ..clear()
        ..addAll(seen);
      _nextId = nextId;
      if (migrated) _write();
      notifyListeners();
    } catch (_) {
      // Corrupt storage: keep the default set, never crash.
    }
  }

  void _sort() => _entries.sort((a, b) => a.startHz.compareTo(b.startHz));

  void _write() {
    final encoded = jsonEncode({
      'version': storageVersion,
      'nextId': _nextId,
      'seenDefaults': _seenDefaults.toList(),
      'entries': _entries.map((b) => b.toJson()).toList(),
    });
    _pending = _pending.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, encoded);
    });
  }

  void _save() {
    _changed = true;
    _sort();
    _write();
    notifyListeners();
  }

  Future<void> flush() => _pending;

  /// Validation of a new ([id] == null) or edited band against [among]
  /// (default: the stored bands); the edited band itself is excluded.
  BandValidationException? check({
    String? id,
    String name = 'x',
    required int startHz,
    required int endHz,
    int stepHz = 5000,
    List<Band>? among,
  }) {
    final n = name.trim();
    if (n.isEmpty || n.length > bandMaxNameLength) {
      return const BandValidationException(BandIssue.name);
    }
    if (startHz < bandMinHz ||
        endHz < bandMinHz ||
        startHz > bandMaxHz ||
        endHz > bandMaxHz) {
      return const BandValidationException(BandIssue.outOfRange);
    }
    if (startHz >= endHz) return const BandValidationException(BandIssue.order);
    if (!receiverSteps.contains(stepHz)) {
      return const BandValidationException(BandIssue.step);
    }
    for (final b in among ?? _entries) {
      if (b.id != id && b.overlaps(startHz, endHz)) {
        return BandValidationException(BandIssue.overlap, b);
      }
    }
    return null;
  }

  /// Throws [BandValidationException].
  Band add({
    required String name,
    required int startHz,
    required int endHz,
    required DemodMode mode,
    required int stepHz,
  }) {
    final err = check(
      name: name,
      startHz: startHz,
      endHz: endHz,
      stepHz: stepHz,
    );
    if (err != null) throw err;
    final b = Band(
      id: 'user-${_nextId++}',
      name: name.trim(),
      startHz: startHz,
      endHz: endHz,
      mode: mode,
      stepHz: stepHz,
    );
    _entries.add(b);
    _save();
    return b;
  }

  /// Throws [BandValidationException] or [ArgumentError] (unknown id).
  void edit(
    String id, {
    required String name,
    required int startHz,
    required int endHz,
    required DemodMode mode,
    required int stepHz,
  }) {
    final i = _entries.indexWhere((b) => b.id == id);
    if (i < 0) throw ArgumentError.value(id, 'id');
    final err = check(
      id: id,
      name: name,
      startHz: startHz,
      endHz: endHz,
      stepHz: stepHz,
    );
    if (err != null) throw err;
    _entries[i] = _entries[i].copyWith(
      name: name.trim(),
      startHz: startHz,
      endHz: endHz,
      mode: mode,
      stepHz: stepHz,
    );
    _save();
  }

  /// Any band, defaults included; a deleted default is not re-added.
  void delete(String id) {
    final i = _entries.indexWhere((b) => b.id == id);
    if (i < 0) throw ArgumentError.value(id, 'id');
    _entries.removeAt(i);
    _save();
  }
}

/// «87.500–108.000 МГц».
String formatBandRange(Band b) =>
    '${formatMhz(b.startHz)}–${formatMhz(b.endHz)} МГц';

/// «5 кГц», «6.25 кГц», «12.5 кГц», «200 кГц».
String formatStepKhz(int hz) {
  var s = (hz / 1000).toStringAsFixed(3);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return '$s кГц';
}

/// Exact MHz text → Hz (up to 6 decimals, "," accepted); null if invalid.
int? parseMhzToHz(String text) {
  final t = text.trim().replaceAll(',', '.');
  final m = RegExp(r'^(\d{1,5})(?:\.(\d{0,6}))?$').firstMatch(t);
  if (m == null) return null;
  final frac = (m.group(2) ?? '').padRight(6, '0');
  return int.parse(m.group(1)!) * 1000000 + int.parse(frac);
}

/// One section of the Пресеты tab: a band (null = «Вне диапазонов»).
@immutable
class PresetGroup {
  const PresetGroup(this.band, this.presets);
  final Band? band;
  final List<Favorite> presets;
}

/// Presets grouped by band: sections by band start, presets by frequency,
/// «Вне диапазонов» last; empty sections are omitted.
List<PresetGroup> groupPresetsByBand(List<Favorite> presets, List<Band> bands) {
  final sortedBands = [...bands]
    ..sort((a, b) => a.startHz.compareTo(b.startHz));
  final sorted = [...presets]
    ..sort((a, b) => a.frequencyHz.compareTo(b.frequencyHz));
  final groups = <PresetGroup>[];
  for (final b in sortedBands) {
    final inside = sorted.where((f) => b.contains(f.frequencyHz)).toList();
    if (inside.isNotEmpty) groups.add(PresetGroup(b, inside));
  }
  final outside = sorted
      .where((f) => !sortedBands.any((b) => b.contains(f.frequencyHz)))
      .toList();
  if (outside.isNotEmpty) groups.add(PresetGroup(null, outside));
  return groups;
}

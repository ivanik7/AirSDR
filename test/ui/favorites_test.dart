import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

/// The 12-entry pool shipped before the 3-preset default set, exactly as the
/// old build stored it (`builtin-<index>`, frequency, name, mode, category,
/// enabled).
const _oldPool = [
  ('builtin-0', 145500000, 'Симплекс 2м', 'NFM', 'VHF', true),
  ('builtin-1', 433500000, 'PMR вызов', 'NFM', 'UHF', true),
  ('builtin-2', 118100000, 'Вышка / TWR', 'AM', 'AIR', true),
  ('builtin-3', 121500000, 'Guard 121.5', 'AM', 'AIR', true),
  ('builtin-4', 156800000, 'Морской 16', 'NFM', 'MAR', true),
  ('builtin-5', 101200000, 'FM радио', 'WFM', 'FM', true),
  ('builtin-6', 462562000, 'GMRS 1', 'NFM', 'UHF', true),
  ('builtin-7', 446006000, 'PMR446 1', 'NFM', 'UHF', true),
  ('builtin-8', 162550000, 'Погода WX', 'NFM', 'MAR', true),
  ('builtin-9', 131550000, 'ACARS', 'AM', 'AIR', false),
  ('builtin-10', 169000000, 'Служебный', 'NFM', 'VHF', false),
  ('builtin-11', 88600000, 'Радио 88.6', 'WFM', 'FM', false),
];

Map<String, Object> _entry(
  String id,
  int hz,
  String name,
  String mode,
  String category,
  bool enabled,
) => {
  'id': id,
  'frequencyHz': hz,
  'name': name,
  'mode': mode,
  'category': category,
  'enabled': enabled,
  'builtIn': id.startsWith('builtin-'),
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('clean install: exactly FM Radio, Air Traffic, ISM Band', () async {
    final repo = FavoritesRepository();
    await repo.load();
    expect(
      repo.entries.map(
        (f) => (f.frequencyHz, f.mode, f.name, f.category, f.enabled),
      ),
      [
        (100000000, DemodMode.wfm, 'FM Radio', 'FM', true),
        (125000000, DemodMode.am, 'Air Traffic', 'AIR', true),
        (433000000, DemodMode.am, 'ISM Band', 'UHF', true),
      ],
    );
    expect(repo.entries.every((f) => f.builtIn), isTrue);
    expect(builtInFavorites, hasLength(3));
  });

  test('a deleted built-in stays deleted after reload', () async {
    final repo = FavoritesRepository();
    await repo.load();
    final air = repo.entries.firstWhere((f) => f.name == 'Air Traffic');
    repo.delete(air.id);
    expect(repo.entries.map((f) => f.name), ['FM Radio', 'ISM Band']);
    await repo.flush();

    final reopened = FavoritesRepository();
    await reopened.load();
    expect(reopened.entries.map((f) => f.name), ['FM Radio', 'ISM Band']);
    // Deleting the rest leaves an empty list, still empty after reload.
    for (final f in [...reopened.entries]) {
      reopened.delete(f.id);
    }
    await reopened.flush();
    final again = FavoritesRepository();
    await again.load();
    expect(again.entries, isEmpty);
    // The deleted frequency is free again for a user preset.
    again.add(
      frequencyHz: 125000000,
      name: 'Своя AIR',
      mode: DemodMode.am,
      category: 'AIR',
    );
    expect(again.entries.single.builtIn, isFalse);
  });

  test('filtering, toggling, add/edit/delete user presets persist', () async {
    final repo = FavoritesRepository();
    await repo.load();
    expect(repo.filtered('AIR').single.name, 'Air Traffic');
    repo.toggle(repo.entries.first.id);
    repo.add(
      frequencyHz: 99500000,
      name: 'Своё FM',
      mode: DemodMode.wfm,
      category: 'FM',
    );
    await repo.flush();
    final reopened = FavoritesRepository();
    await reopened.load();
    expect(reopened.entries.first.enabled, isFalse);
    expect(reopened.entries.last.name, 'Своё FM');
    expect(reopened.filtered('FM').map((f) => f.frequencyHz), [
      100000000,
      99500000,
    ]);
    reopened.edit(
      reopened.entries.last.id,
      name: 'Новая',
      mode: DemodMode.am,
      category: 'AIR',
    );
    expect(reopened.filtered('AIR').last.mode, DemodMode.am);
    reopened.delete(reopened.entries.last.id);
    await reopened.flush();
    final again = FavoritesRepository();
    await again.load();
    expect(again.entries.length, 3);
    expect(again.entries.first.enabled, isFalse);
  });

  group('migration from the 12-preset pool', () {
    Future<FavoritesRepository> loadLegacy(
      List<Map<String, Object>> entries, {
      int nextId = 0,
    }) async {
      SharedPreferences.setMockInitialValues({
        FavoritesRepository.storageKey: jsonEncode({
          'nextId': nextId,
          'entries': entries,
        }),
      });
      final repo = FavoritesRepository();
      await repo.load();
      return repo;
    }

    test('untouched old built-ins are dropped, 3 new ones added', () async {
      final repo = await loadLegacy([
        for (final e in _oldPool) _entry(e.$1, e.$2, e.$3, e.$4, e.$5, e.$6),
      ]);
      expect(repo.entries.map((f) => f.name), [
        'FM Radio',
        'Air Traffic',
        'ISM Band',
      ]);
      expect(repo.entries.every((f) => f.builtIn), isTrue);
    });

    test('keeps user presets (order, enabled), converts edited old '
        'built-ins to user presets, drops toggled-only ones, no duplicates '
        'and the result is stable across reloads', () async {
      final saved = <Map<String, Object>>[
        // User reordered/interleaved: user presets between built-ins.
        _entry('user-3', 99500000, 'Моя FM', 'WFM', 'FM', true),
        for (final e in _oldPool)
          switch (e.$1) {
            // Renamed by the user -> kept as a user preset.
            'builtin-2' => _entry(
              e.$1,
              e.$2,
              'Мой аэропорт',
              'AM',
              'AIR',
              true,
            ),
            // Mode changed by the user -> kept as a user preset.
            'builtin-4' => _entry(e.$1, e.$2, e.$3, 'AM', e.$5, false),
            // Only the bookmark flag toggled -> not an edit, dropped.
            'builtin-9' => _entry(e.$1, e.$2, e.$3, e.$4, e.$5, true),
            _ => _entry(e.$1, e.$2, e.$3, e.$4, e.$5, e.$6),
          },
        _entry('user-0', 145000000, 'Репитер', 'NFM', 'VHF', false),
        // Same frequency as the new «ISM Band» default.
        _entry('user-1', 433000000, 'Мой брелок', 'NFM', 'UHF', true),
      ];
      final repo = await loadLegacy(saved, nextId: 4);
      final got = repo.entries
          .map((f) => (f.frequencyHz, f.name, f.mode, f.enabled, f.builtIn))
          .toList();
      expect(got, [
        (100000000, 'FM Radio', DemodMode.wfm, true, true),
        (125000000, 'Air Traffic', DemodMode.am, true, true),
        (99500000, 'Моя FM', DemodMode.wfm, true, false),
        (118100000, 'Мой аэропорт', DemodMode.am, true, false),
        (156800000, 'Морской 16', DemodMode.am, false, false),
        (145000000, 'Репитер', DemodMode.nfm, false, false),
        (433000000, 'Мой брелок', DemodMode.nfm, true, false),
      ]);
      expect(
        repo.entries.where((f) => RegExp(r'^builtin-\d+$').hasMatch(f.id)),
        isEmpty,
        reason: 'no entry keeps an old built-in id',
      );
      final ids = repo.entries.map((f) => f.id).toSet();
      expect(ids, hasLength(repo.entries.length));
      final hz = repo.entries.map((f) => f.frequencyHz).toSet();
      expect(hz, hasLength(repo.entries.length), reason: 'no duplicates');
      // Existing user ids survive; converted ones get fresh user ids.
      expect(ids, containsAll(['user-0', 'user-1', 'user-3']));

      // Migration is persisted and idempotent.
      await repo.flush();
      final reopened = FavoritesRepository();
      await reopened.load();
      expect(
        reopened.entries.map((f) => (f.id, f.frequencyHz, f.name, f.enabled)),
        repo.entries.map((f) => (f.id, f.frequencyHz, f.name, f.enabled)),
      );
      // A new user preset does not reuse a converted id.
      final added = reopened.add(
        frequencyHz: 7100000,
        name: '40 м',
        mode: DemodMode.lsb,
        category: 'VHF',
      );
      expect(ids, isNot(contains(added.id)));

      // The default skipped because of a same-frequency user preset does
      // not appear later when that user preset is deleted.
      reopened.delete('user-1');
      await reopened.flush();
      final third = FavoritesRepository();
      await third.load();
      expect(third.entries.any((f) => f.frequencyHz == 433000000), isFalse);
    });
  });

  test('rejects duplicate frequencies and invalid values', () async {
    final repo = FavoritesRepository();
    await repo.load();
    expect(
      () => repo.add(
        frequencyHz: 100000000,
        name: 'duplicate',
        mode: DemodMode.am,
        category: 'VHF',
      ),
      throwsArgumentError,
    );
    expect(
      () => repo.add(
        frequencyHz: -1,
        name: 'x',
        mode: DemodMode.am,
        category: 'VHF',
      ),
      throwsArgumentError,
    );
    expect(
      () => repo.add(
        frequencyHz: 99000000,
        name: ' ',
        mode: DemodMode.am,
        category: 'VHF',
      ),
      throwsArgumentError,
    );
    expect(
      () => repo.add(
        frequencyHz: 99000000,
        name: 'x',
        mode: DemodMode.am,
        category: 'wrong',
      ),
      throwsArgumentError,
    );
  });
}

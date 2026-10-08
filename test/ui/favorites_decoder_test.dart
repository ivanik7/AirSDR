// SPDX-License-Identifier: GPL-3.0-or-later
//
// Favorites storage v3: per-preset decoder selection, round trip, and
// normalization of old/unknown/invalid decoder data (never a corrupted or
// dropped preset just because its decoder attachment can't be trusted).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a preset created with a decoder round-trips through storage', () async {
    final repo = FavoritesRepository();
    await repo.load();
    final f = repo.add(
      frequencyHz: 433920000,
      name: 'Weather sensors',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
      decoderSettings: const {'frequency_hz': 868000000},
    );
    expect(f.decoderId, 'rtl_433');
    expect(f.decoderSettings, {'frequency_hz': 868000000});
    await repo.flush();

    final reopened = FavoritesRepository();
    await reopened.load();
    final again = reopened.entries.firstWhere((e) => e.id == f.id);
    expect(again.decoderId, 'rtl_433');
    expect(again.decoderSettings, {'frequency_hz': 868000000});
  });

  test('add without a decoder stores plain voice/audio (unchanged '
      'behaviour)', () async {
    final repo = FavoritesRepository();
    await repo.load();
    final f = repo.add(
      frequencyHz: 99500000,
      name: 'Своя FM',
      mode: DemodMode.wfm,
      category: 'FM',
    );
    expect(f.decoderId, isNull);
    expect(f.decoderSettings, isEmpty);
    expect(f.toJson().containsKey('decoderId'), isFalse);
  });

  test('add with an unrecognized decoder id falls back to no decoder, '
      'preset itself still saved', () async {
    final repo = FavoritesRepository();
    await repo.load();
    final f = repo.add(
      frequencyHz: 99600000,
      name: 'x',
      mode: DemodMode.wfm,
      category: 'FM',
      decoderId: 'no-such-decoder',
    );
    expect(f.decoderId, isNull);
  });

  test('settings outside a decoder\'s allowed list fall back to the '
      'default, unknown keys are dropped', () async {
    final repo = FavoritesRepository();
    await repo.load();
    final f = repo.add(
      frequencyHz: 433920000,
      name: 'x',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
      decoderSettings: const {'frequency_hz': 999, 'bogus_key': 1},
    );
    expect(f.decoderSettings, {'frequency_hz': 433920000});
  });

  test('edit leaves the decoder selection untouched unless explicitly '
      'passed', () async {
    final repo = FavoritesRepository();
    await repo.load();
    final f = repo.add(
      frequencyHz: 433920000,
      name: 'x',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
      decoderSettings: const {'frequency_hz': 915000000},
    );
    repo.edit(f.id, name: 'y', mode: DemodMode.am, category: 'UHF');
    final untouched = repo.entries.firstWhere((e) => e.id == f.id);
    expect(untouched.decoderId, 'rtl_433');
    expect(untouched.decoderSettings, {'frequency_hz': 915000000});

    repo.edit(
      f.id,
      name: 'y',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: null,
    );
    final cleared = repo.entries.firstWhere((e) => e.id == f.id);
    expect(cleared.decoderId, isNull);
    expect(cleared.decoderSettings, isEmpty);
  });

  test('two presets on the same decoder keep fully independent settings '
      '(copy isolation)', () async {
    final repo = FavoritesRepository();
    await repo.load();
    final a = repo.add(
      frequencyHz: 433920000,
      name: 'a',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
      decoderSettings: const {'frequency_hz': 433920000},
    );
    final b = repo.add(
      frequencyHz: 868000000,
      name: 'b',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
      decoderSettings: const {'frequency_hz': 868000000},
    );
    // Mutating one entry's map (defensively, as if a caller tried) must
    // never be possible to observe on the other.
    expect(a.decoderSettings['frequency_hz'], 433920000);
    expect(b.decoderSettings['frequency_hz'], 868000000);
    expect(
      identical(a.decoderSettings, b.decoderSettings),
      isFalse,
      reason: 'each Favorite owns its own settings map',
    );
  });

  test('v1/v2 saves (no decoder keys at all) load as plain voice/audio',
      () async {
    SharedPreferences.setMockInitialValues({
      FavoritesRepository.storageKey: jsonEncode({
        'version': 2,
        'nextId': 1,
        'seenDefaults': ['builtin-fm', 'builtin-air', 'builtin-ism'],
        'entries': [
          {
            'id': 'user-0',
            'frequencyHz': 145000000,
            'name': 'Old preset',
            'mode': 'NFM',
            'category': 'VHF',
            'enabled': true,
            'builtIn': false,
          },
        ],
      }),
    });
    final repo = FavoritesRepository();
    await repo.load();
    final old = repo.entries.firstWhere((e) => e.name == 'Old preset');
    expect(old.decoderId, isNull);
    expect(old.decoderSettings, isEmpty);
  });

  test('an unknown decoderId in storage normalizes to no decoder without '
      'dropping the preset', () async {
    SharedPreferences.setMockInitialValues({
      FavoritesRepository.storageKey: jsonEncode({
        'version': 3,
        'nextId': 1,
        'seenDefaults': ['builtin-fm', 'builtin-air', 'builtin-ism'],
        'entries': [
          {
            'id': 'user-0',
            'frequencyHz': 145000000,
            'name': 'Future decoder',
            'mode': 'NFM',
            'category': 'VHF',
            'enabled': true,
            'builtIn': false,
            'decoderId': 'not-yet-invented',
            'decoderSettingsVersion': 1,
            'decoderSettings': <String, Object>{},
          },
        ],
      }),
    });
    final repo = FavoritesRepository();
    await repo.load();
    final e = repo.entries.firstWhere((e) => e.name == 'Future decoder');
    expect(e.decoderId, isNull);
    expect(e.decoderSettings, isEmpty);
  });

  test('a decoderSettingsVersion mismatch normalizes to no decoder '
      '(schema changed underneath an old save)', () async {
    SharedPreferences.setMockInitialValues({
      FavoritesRepository.storageKey: jsonEncode({
        'version': 3,
        'nextId': 1,
        'seenDefaults': ['builtin-fm', 'builtin-air', 'builtin-ism'],
        'entries': [
          {
            'id': 'user-0',
            'frequencyHz': 433920000,
            'name': 'Stale schema',
            'mode': 'AM',
            'category': 'UHF',
            'enabled': true,
            'builtIn': false,
            'decoderId': 'rtl_433',
            'decoderSettingsVersion': 999,
            'decoderSettings': {'frequency_hz': 433920000},
          },
        ],
      }),
    });
    final repo = FavoritesRepository();
    await repo.load();
    final e = repo.entries.firstWhere((e) => e.name == 'Stale schema');
    expect(e.decoderId, isNull);
    expect(e.decoderSettings, isEmpty);
  });

  test('a decoderSettings entry missing a declared key resolves it to '
      'the default on load', () async {
    SharedPreferences.setMockInitialValues({
      FavoritesRepository.storageKey: jsonEncode({
        'version': 3,
        'nextId': 1,
        'seenDefaults': ['builtin-fm', 'builtin-air', 'builtin-ism'],
        'entries': [
          {
            'id': 'user-0',
            'frequencyHz': 433920000,
            'name': 'Partial settings',
            'mode': 'AM',
            'category': 'UHF',
            'enabled': true,
            'builtIn': false,
            'decoderId': 'rtl_433',
            'decoderSettingsVersion': 1,
            'decoderSettings': <String, Object>{},
          },
        ],
      }),
    });
    final repo = FavoritesRepository();
    await repo.load();
    final e = repo.entries.firstWhere((e) => e.name == 'Partial settings');
    expect(e.decoderId, 'rtl_433');
    expect(e.decoderSettings, {'frequency_hz': 433920000});
  });
}

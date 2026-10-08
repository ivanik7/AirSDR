// SPDX-License-Identifier: GPL-3.0-or-later
//
// Unified decoder-catalog id for voice/demod-mode choices
// (favorites.dart `decoderIdForMode`/`demodModeFromDecoderId`): round trip,
// mode pinning on save/edit, migration of legacy data (no decoder keys,
// the obsolete literal `'voice'` id) where the stored mode stays
// authoritative instead, and [Favorite.decoderChoice] always resolving to
// a concrete choice for the unified preset-editor dropdown.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('decoderIdForMode/demodModeFromDecoderId round-trip every DemodMode '
      'using the fixed native ids', () {
    const expectedNativeIds = {
      DemodMode.nfm: 0,
      DemodMode.wfm: 1,
      DemodMode.am: 2,
      DemodMode.dsb: 3,
      DemodMode.usb: 4,
      DemodMode.cw: 5,
      DemodMode.lsb: 6,
      DemodMode.raw: 7,
    };
    for (final mode in DemodMode.values) {
      final id = decoderIdForMode(mode);
      expect(id, 'demod:${expectedNativeIds[mode]}');
      expect(demodModeFromDecoderId(id), mode);
    }
    expect(demodModeFromDecoderId(null), isNull);
    expect(demodModeFromDecoderId('rtl_433'), isNull);
    expect(demodModeFromDecoderId('demod:99'), isNull, reason: 'no such mode');
    expect(demodModeFromDecoderId('demod:abc'), isNull);
  });

  test('decoderChoice resolves to an explicit demod id when no decoder is '
      'stored, and to the stored decoderId otherwise', () {
    final repo = FavoritesRepository();
    final plain = repo.add(
      frequencyHz: 99500000,
      name: 'Plain',
      mode: DemodMode.wfm,
      category: 'FM',
    );
    expect(plain.decoderId, isNull);
    expect(plain.decoderChoice, decoderIdForMode(DemodMode.wfm));

    final withData = repo.add(
      frequencyHz: 433920000,
      name: 'Sensors',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
      decoderSettings: const {'frequency_hz': 433920000},
    );
    expect(withData.decoderChoice, 'rtl_433');

    // A built-in constructed directly (storage-untouched, decoderId null)
    // still resolves to a real choice for display.
    expect(builtInFavorites.first.decoderId, isNull);
    expect(
      builtInFavorites.first.decoderChoice,
      decoderIdForMode(builtInFavorites.first.mode),
    );
    repo.dispose();
  });

  test('saving an explicit voice/demod-mode decoderId pins the underlying '
      'mode, overriding a contradicting mode argument', () {
    final repo = FavoritesRepository();
    final f = repo.add(
      frequencyHz: 29912500,
      name: 'Pinned to USB',
      mode: DemodMode.nfm, // contradicts the decoderId below
      category: 'VHF',
      decoderId: decoderIdForMode(DemodMode.usb),
    );
    expect(f.mode, DemodMode.usb, reason: 'voice/demod-mode id always wins');
    expect(f.decoderId, decoderIdForMode(DemodMode.usb));
    expect(f.decoderSettings, isEmpty);
    repo.dispose();
  });

  test('a data decoder never pins the mode: the caller-given mode stands',
      () async {
    final repo = FavoritesRepository();
    final f = repo.add(
      frequencyHz: 433920000,
      name: 'Data decoder',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
    );
    expect(f.mode, DemodMode.am);
    expect(f.decoderId, 'rtl_433');
    repo.dispose();
  });

  test('edit() with an explicit voice/demod-mode decoderId also updates '
      'the stored mode', () async {
    final repo = FavoritesRepository();
    final f = repo.add(
      frequencyHz: 433920000,
      name: 'x',
      mode: DemodMode.am,
      category: 'UHF',
    );
    repo.edit(
      f.id,
      name: 'x',
      mode: DemodMode.am, // ignored: the decoderId below pins LSB instead
      category: 'UHF',
      decoderId: decoderIdForMode(DemodMode.lsb),
    );
    final edited = repo.entries.firstWhere((e) => e.id == f.id);
    expect(edited.mode, DemodMode.lsb);
    expect(edited.decoderId, decoderIdForMode(DemodMode.lsb));
    repo.dispose();
  });

  test('a voice/demod-mode decoderId round-trips through storage (v3, '
      'settings schema 1 unaffected)', () async {
    final repo = FavoritesRepository();
    await repo.load();
    final f = repo.add(
      frequencyHz: 29912500,
      name: 'USB spot',
      mode: DemodMode.nfm,
      category: 'VHF',
      decoderId: decoderIdForMode(DemodMode.usb),
    );
    await repo.flush();

    final reopened = FavoritesRepository();
    await reopened.load();
    final again = reopened.entries.firstWhere((e) => e.id == f.id);
    expect(again.decoderId, decoderIdForMode(DemodMode.usb));
    expect(again.mode, DemodMode.usb);
    expect(again.decoderSettings, isEmpty);
  });

  test('the obsolete literal \'voice\' decoderId never survives '
      'normalization; the preset itself and its stored mode are kept', () async {
    SharedPreferences.setMockInitialValues({
      FavoritesRepository.storageKey: jsonEncode({
        'version': 3,
        'nextId': 1,
        'seenDefaults': ['builtin-fm', 'builtin-air', 'builtin-ism'],
        'entries': [
          {
            'id': 'user-0',
            'frequencyHz': 145000000,
            'name': 'Legacy voice entry',
            'mode': 'NFM',
            'category': 'VHF',
            'enabled': true,
            'builtIn': false,
            'decoderId': 'voice',
            'decoderSettingsVersion': 1,
            'decoderSettings': <String, Object>{},
          },
        ],
      }),
    });
    final repo = FavoritesRepository();
    await repo.load();
    final e = repo.entries.firstWhere((e) => e.name == 'Legacy voice entry');
    expect(e.decoderId, isNull);
    // No decoderId pin: the stored mode is authoritative for legacy data.
    expect(e.mode, DemodMode.nfm);
    expect(e.decoderChoice, decoderIdForMode(DemodMode.nfm));
  });

  test('v1/v2 saves (no decoder keys at all) keep their stored mode '
      'authoritative — no pin to reconcile', () async {
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
    expect(old.mode, DemodMode.nfm);
  });

  test('a decoderId using the demod scheme but naming a mode id with no '
      'DemodMode (unknown native id) normalizes away like any other '
      'unrecognized decoder', () async {
    SharedPreferences.setMockInitialValues({
      FavoritesRepository.storageKey: jsonEncode({
        'version': 3,
        'nextId': 1,
        'seenDefaults': ['builtin-fm', 'builtin-air', 'builtin-ism'],
        'entries': [
          {
            'id': 'user-0',
            'frequencyHz': 145000000,
            'name': 'Future native mode',
            'mode': 'NFM',
            'category': 'VHF',
            'enabled': true,
            'builtIn': false,
            'decoderId': 'demod:42',
            'decoderSettingsVersion': 1,
            'decoderSettings': <String, Object>{},
          },
        ],
      }),
    });
    final repo = FavoritesRepository();
    await repo.load();
    final e = repo.entries.firstWhere((e) => e.name == 'Future native mode');
    expect(e.decoderId, isNull);
    expect(e.mode, DemodMode.nfm, reason: 'stored mode stays authoritative');
  });

  test('copyWith with an explicit voice/demod-mode decoderId pins mode '
      'even when a conflicting mode is also passed', () {
    const f = Favorite(
      id: 'x',
      frequencyHz: 100000000,
      name: 'n',
      mode: DemodMode.wfm,
      category: 'FM',
    );
    final updated = f.copyWith(
      mode: DemodMode.am, // overridden by the decoderId pin below
      decoderId: decoderIdForMode(DemodMode.cw),
    );
    expect(updated.mode, DemodMode.cw);
    expect(updated.decoderId, decoderIdForMode(DemodMode.cw));
  });
}

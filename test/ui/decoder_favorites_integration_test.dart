// SPDX-License-Identifier: GPL-3.0-or-later
//
// End-to-end coherence of the Decoder tab's shell-scoped preview with
// favorites/channels: create/edit a preset, save a channel as preset, and
// apply a preset — all while a (fake, available) decoder is previewed —
// plus a storage reload and that two presets keep independent decoder
// settings.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _FakeBackend implements DecoderBackend {
  _FakeBackend(this._available);
  final Set<String> _available;
  final List<String?> selected = [];
  @override
  Set<String> get availableIds => _available;
  @override
  bool select(String? id, Map<String, Object> versionedConfig) {
    selected.add(id);
    return id != null;
  }

  @override
  DecoderEvent? poll(int afterSequence) => null;
}

class _BackedRadio extends DemoRadioController {
  _BackedRadio(this._backend);
  final DecoderBackend? _backend;
  @override
  DecoderBackend? get decoderBackend => _backend;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'creating a preset while rtl_433 is previewed carries the decoder '
    'into the saved favorite',
    (tester) async {
      final backend = _FakeBackend({'rtl_433'});
      final radio = _BackedRadio(backend);
      final favorites = FavoritesRepository();
      await favorites.load();
      radio.setTuning(centerFrequency: 433920000, vfoOffset: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('decoderSelect-rtl_433')));
      await tester.pump();
      expect(
        backend.selected.last,
        isNull,
        reason: 'preview cannot claim tuner',
      );

      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('addFavorite')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('favoriteName')),
        'Sensors',
      );
      await tester.tap(find.byKey(const ValueKey('favoriteSave')));
      await tester.pumpAndSettle();

      final saved = favorites.entries.last;
      expect(saved.name, 'Sensors');
      expect(
        saved.decoderId,
        'rtl_433',
        reason:
            'the preview previewed when the preset was created carries over',
      );
      expect(saved.decoderSettings['frequency_hz'], 433920000);

      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );

  testWidgets('applying a preset with a stored decoder restores that preview '
      'without starting anything if unavailable', (tester) async {
    final backend = _FakeBackend(const {});
    final radio = _BackedRadio(backend);
    final favorites = FavoritesRepository();
    await favorites.load();
    favorites.add(
      frequencyHz: 433920000,
      name: 'Sensors',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
      decoderSettings: const {'frequency_hz': 433920000},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    final f = favorites.entries.firstWhere((e) => e.name == 'Sensors');
    await tester.tap(find.byKey(ValueKey('apply-${f.id}')));
    await tester.pump();
    // Applying switches to Receive (onApplied); check the Decoder tab now
    // shows the restored preview.
    await tester.tap(find.byKey(const ValueKey('tab-3')));
    await tester.pump();
    expect(find.byKey(const ValueKey('decoderPanel-rtl_433')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('decoderUnavailable-rtl_433')),
      findsOneWidget,
      reason: 'unavailable in this backend: preview only, never started',
    );
    expect(radio.running, isFalse);

    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });

  testWidgets('saving a channel as preset while SSTV is previewed carries the '
      'decoder into the new favorite; editing the preset leaves it intact', (
    tester,
  ) async {
    final backend = _FakeBackend({'sstv'});
    final radio = _BackedRadio(backend);
    final favorites = FavoritesRepository();
    await favorites.load();
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    await tester.pump();
    await tester.pump();
    radio.setTuning(centerFrequency: 29912500, vfoOffset: 0);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('tab-3')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('decoderSelect-sstv')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('tab-0')));
    await tester.pump();
    await tester.pumpAndSettle();
    // The seeded first-run channel is active; long-press to open its menu.
    final activeFinder = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('channel-'),
    );
    expect(activeFinder, findsOneWidget);
    await tester.longPress(activeFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить как пресет'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('presetName')),
      'SSTV spot',
    );
    await tester.tap(find.byKey(const ValueKey('presetNameSave')));
    await tester.pumpAndSettle();

    final saved = favorites.entries.firstWhere((e) => e.name == 'SSTV spot');
    expect(saved.decoderId, 'sstv');
    expect(saved.decoderSettings['mode'], 'auto');

    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });

  testWidgets('editing name/mode of a preset with a decoder does not clear its '
      'decoder (edit leaves it untouched unless explicitly changed)', (
    tester,
  ) async {
    final radio = DemoRadioController();
    final favorites = FavoritesRepository();
    await favorites.load();
    favorites.add(
      frequencyHz: 433920000,
      name: 'Sensors',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
      decoderSettings: const {'frequency_hz': 433920000},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    final f = favorites.entries.firstWhere((e) => e.name == 'Sensors');
    await tester.tap(find.byKey(ValueKey('favoriteMenu-${f.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Изменить').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('favoriteName')),
      'Sensors renamed',
    );
    await tester.tap(find.byKey(const ValueKey('favoriteSave')));
    await tester.pumpAndSettle();

    final renamed = favorites.entries.firstWhere((e) => e.id == f.id);
    expect(renamed.name, 'Sensors renamed');
    expect(
      renamed.decoderId,
      'rtl_433',
      reason: 'edit dialog does not touch it',
    );
    expect(renamed.decoderSettings['frequency_hz'], 433920000);

    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });

  testWidgets('editing a preset changes its decoder without retuning', (
    tester,
  ) async {
    final radio = DemoRadioController();
    final favorites = FavoritesRepository();
    await favorites.load();
    final preset = favorites.add(
      frequencyHz: 433920000,
      name: 'Sensor',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
      decoderSettings: const {'frequency_hz': 433920000},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('favoriteMenu-${preset.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Изменить').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favoriteDecoder')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SSTV').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favoriteSave')));
    await tester.pumpAndSettle();
    final saved = favorites.entries.firstWhere(
      (entry) => entry.id == preset.id,
    );
    expect(saved.decoderId, 'sstv');
    expect(saved.decoderSettings, {'mode': 'auto'});
    expect(radio.mode, DemodMode.wfm);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });

  test('two presets with different decoder settings survive a reload '
      'independently', () async {
    final repo = FavoritesRepository();
    await repo.load();
    repo.add(
      frequencyHz: 433920000,
      name: 'A',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
      decoderSettings: const {'frequency_hz': 433920000},
    );
    repo.add(
      frequencyHz: 868000000,
      name: 'B',
      mode: DemodMode.am,
      category: 'UHF',
      decoderId: 'rtl_433',
      decoderSettings: const {'frequency_hz': 868000000},
    );
    await repo.flush();

    final reopened = FavoritesRepository();
    await reopened.load();
    final a = reopened.entries.firstWhere((e) => e.name == 'A');
    final b = reopened.entries.firstWhere((e) => e.name == 'B');
    expect(a.decoderSettings['frequency_hz'], 433920000);
    expect(b.decoderSettings['frequency_hz'], 868000000);
  });
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// Unified preset editor: ONE decoder-choice dropdown drives both the
// voice/demod-mode pin and data-decoder selection, replacing the old
// separate mode + decoder dropdowns.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/legacy/presets_screen.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('WFM RBDS preference survives saving and reopening a preset', (
    tester,
  ) async {
    final radio = DemoRadioController();
    final session = DecoderSession(radio);
    final favorites = FavoritesRepository();
    await favorites.load();
    final wfm = decoderIdForMode(DemodMode.wfm);
    session.setSetting(wfm, 'rbds', true);
    radio.setTuning(centerFrequency: 99600000, vfoOffset: 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PresetsScreen(
            controller: radio,
            receiver: CenteredReceiver(radio),
            favorites: favorites,
            decoderSession: session,
            onApplied: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('addFavorite')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('favoriteName')),
      'RDS FM',
    );
    await tester.tap(find.byKey(const ValueKey('favoriteSave')));
    await tester.pumpAndSettle();
    final saved = favorites.entries.singleWhere((e) => e.name == 'RDS FM');
    expect(saved.decoderId, wfm);
    expect(saved.decoderSettings['rbds'], true);
    await favorites.flush();
    final reopened = FavoritesRepository();
    await reopened.load();
    final restored = reopened.entries.singleWhere((e) => e.id == saved.id);
    expect(restored.decoderSettings['rbds'], true);
    session.setSetting(wfm, 'rbds', false);
    session.applyStored(
      restored.decoderId,
      restored.decoderSettings,
      mode: restored.mode,
    );
    expect(session.settingsFor(wfm)['rbds'], true);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    radio.dispose();
    favorites.dispose();
    reopened.dispose();
  });

  testWidgets(
    'the add-preset dialog offers exactly one decoder dropdown: no separate '
    'DemodMode chooser',
    (tester) async {
      final radio = DemoRadioController();
      final favorites = FavoritesRepository();
      await favorites.load();
      radio.setTuning(centerFrequency: 99500000, vfoOffset: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('addFavorite')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('favoriteDecoder')), findsOneWidget);
      expect(find.byType(DropdownButton<DemodMode>), findsNothing);
      expect(find.byType(DropdownButton<String>), findsOneWidget);

      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );

  testWidgets(
    'choosing a voice/demod-mode option in the unified dropdown pins the '
    'saved preset to that mode',
    (tester) async {
      final radio = DemoRadioController();
      final favorites = FavoritesRepository();
      await favorites.load();
      radio.setTuning(centerFrequency: 29912500, vfoOffset: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('addFavorite')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('favoriteName')),
        'LSB spot',
      );
      await tester.tap(find.byKey(const ValueKey('favoriteDecoder')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('LSB').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favoriteSave')));
      await tester.pumpAndSettle();

      final saved = favorites.entries.firstWhere((e) => e.name == 'LSB spot');
      expect(saved.mode, DemodMode.lsb);
      expect(saved.decoderId, decoderIdForMode(DemodMode.lsb));
      expect(saved.decoderSettings, isEmpty);

      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );

  testWidgets(
    'choosing a data decoder in the unified dropdown leaves the dialog '
    'mode untouched',
    (tester) async {
      final radio = DemoRadioController();
      final favorites = FavoritesRepository();
      await favorites.load();
      radio.setTuning(centerFrequency: 433920000, vfoOffset: 0);
      radio.setMode(DemodMode.am);
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('addFavorite')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('favoriteName')),
        'Sensors direct',
      );
      await tester.tap(find.byKey(const ValueKey('favoriteDecoder')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('rtl_433').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favoriteSave')));
      await tester.pumpAndSettle();

      final saved = favorites.entries.firstWhere(
        (e) => e.name == 'Sensors direct',
      );
      expect(saved.decoderId, 'rtl_433');
      expect(saved.mode, DemodMode.am, reason: 'dialog mode unchanged');

      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );

  testWidgets('editing a preset shows its resolved decoderChoice preselected, '
      'including a plain-voice preset with no stored decoderId', (
    tester,
  ) async {
    final radio = DemoRadioController();
    final favorites = FavoritesRepository();
    await favorites.load();
    final plain = favorites.add(
      frequencyHz: 101200000,
      name: 'Plain FM',
      mode: DemodMode.wfm,
      category: 'FM',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('favoriteMenu-${plain.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Изменить').last);
    await tester.pumpAndSettle();

    final dropdown = tester.widget<DropdownButton<String>>(
      find.byKey(const ValueKey('favoriteDecoder')),
    );
    expect(dropdown.value, decoderIdForMode(DemodMode.wfm));

    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });
}

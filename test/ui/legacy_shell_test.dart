import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/receive_screen.dart';
import 'package:sdr_flutter/ui/legacy/squelch_controls.dart';
import 'package:sdr_flutter/ui/legacy/theme.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/spectrum_waterfall.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('receive spectrum uses the legacy accent for its FFT trace', (
    tester,
  ) async {
    final radio = DemoRadioController();
    final favorites = FavoritesRepository();
    await favorites.load();
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );

    final spectrum = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is SpectrumPainter,
      ),
    );
    expect(
      (spectrum.painter! as SpectrumPainter).plotLineColor,
      LegacyColors.accent,
    );

    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });

  testWidgets(
    'squelch controls live only in Decoder, not Settings or Receive',
    (tester) async {
      final radio = DemoRadioController();
      final favorites = FavoritesRepository();
      await favorites.load();
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );

      expect(find.byKey(const ValueKey('key-1')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ReceiveScreen),
          matching: find.byType(SquelchControls, skipOffstage: false),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('squelchStatus')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(SquelchControls), findsOneWidget);
      expect(find.text('Авто'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );

  testWidgets(
    'add arbitrary current frequency, edit, group, delete and persist',
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
      await tester.enterText(
        find.byKey(const ValueKey('favoriteName')),
        'Своя станция',
      );
      await tester.tap(find.byKey(const ValueKey('favoriteSave')));
      await tester.pumpAndSettle();
      expect(favorites.entries.last.frequencyHz, 99500000);
      expect(favorites.entries.last.name, 'Своя станция');
      await favorites.flush();
      expect(
        find.byKey(const ValueKey('presetSection-band-fm')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('category-FM')), findsNothing);
      expect(find.text('Своя станция'), findsOneWidget);
      expect(
        find.byKey(ValueKey('toggle-${favorites.entries.last.id}')),
        findsNothing,
      );
      final id = favorites.entries.last.id;
      await tester.tap(find.byKey(ValueKey('favoriteMenu-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Изменить').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('favoriteName')),
        'Другая станция',
      );
      await tester.tap(find.byKey(const ValueKey('favoriteSave')));
      await tester.pumpAndSettle();
      expect(favorites.entries.last.name, 'Другая станция');
      expect(favorites.entries.last.enabled, isTrue);
      await tester.tap(find.byKey(ValueKey('favoriteMenu-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить').last);
      await tester.pumpAndSettle();
      expect(find.text('Удалить пресет?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('favoriteDeleteConfirm')));
      await tester.pumpAndSettle();
      expect(favorites.entries.any((f) => f.id == id), isFalse);
      await favorites.flush();
      final reopened = FavoritesRepository();
      await reopened.load();
      expect(reopened.entries.any((f) => f.id == id), isFalse);
      reopened.dispose();
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );

  testWidgets(
    'built-in preset can be deleted from the menu with confirmation',
    (tester) async {
      final radio = DemoRadioController();
      final favorites = FavoritesRepository();
      await favorites.load();
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pump();
      final fm = favorites.entries.firstWhere((f) => f.name == 'FM Radio');
      expect(fm.builtIn, isTrue);
      expect(find.text('FM Radio'), findsOneWidget);

      // Cancel keeps it.
      await tester.tap(find.byKey(ValueKey('favoriteMenu-${fm.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Удалить'), findsOneWidget);
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();
      expect(find.text('Удалить пресет?'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(favorites.entries.any((f) => f.id == fm.id), isTrue);
      expect(find.text('FM Radio'), findsOneWidget);

      // Confirm removes it from the list and from storage.
      await tester.tap(find.byKey(ValueKey('favoriteMenu-${fm.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favoriteDeleteConfirm')));
      await tester.pumpAndSettle();
      expect(find.text('FM Radio'), findsNothing);
      expect(favorites.entries.map((f) => f.name), ['Air Traffic', 'ISM Band']);
      await favorites.flush();
      final reopened = FavoritesRepository();
      await reopened.load();
      expect(reopened.entries.map((f) => f.name), ['Air Traffic', 'ISM Band']);
      reopened.dispose();
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );

  testWidgets('mode selection and nudge keep centered tuning', (tester) async {
    final radio = DemoRadioController();
    final favorites = FavoritesRepository();
    await favorites.load();
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('decoderSelector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('decoderSelect-demod:4')));
    await tester.pump();
    expect(radio.mode.label, 'USB');
    expect(radio.vfoOffset, 0);
    await tester.tap(find.byKey(const ValueKey('tab-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('legacyStep')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('legacyStep-25000')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('legacyStep-25000')));
    await tester.pumpAndSettle();
    expect(find.text('ШАГ 25 кГц'), findsOneWidget);
    expect(radio.centerFrequency, radio.tunedFrequency);
    radio.setTuning(centerFrequency: 90000000, vfoOffset: 3500);
    await tester.pump();
    expect(
      radio.vfoOffset,
      0,
      reason: 'late backend offset must be recentered',
    );
    final beforeRuler = radio.tunedFrequency;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('legacySpectrumDrag'))),
    );
    await gesture.moveBy(
      const Offset(-24, 0),
      timeStamp: const Duration(milliseconds: 500),
    );
    await gesture.moveBy(
      const Offset(-24, 0),
      timeStamp: const Duration(milliseconds: 1000),
    );
    await gesture.up();
    await tester.pump();
    expect(radio.tunedFrequency, isNot(beforeRuler));
    expect(radio.vfoOffset, 0);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });

  testWidgets(
    'four tabs, MHz keypad, presets apply to the single centered tuner',
    (tester) async {
      final radio = DemoRadioController();
      radio.setTuning(centerFrequency: 100000000, vfoOffset: 15000);
      final favorites = FavoritesRepository();
      await favorites.load();
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );
      await tester.pump();
      expect(radio.vfoOffset, 0);
      expect(find.text('Приём'), findsOneWidget);
      expect(find.text('Пресеты'), findsOneWidget);
      expect(find.text('Настройки'), findsOneWidget);
      expect(find.text('Decoder'), findsOneWidget);
      // The Приём tab now has real channel slots, not an inert "позже" card.
      expect(find.byKey(const ValueKey('channelsSection')), findsOneWidget);
      expect(find.text('КАНАЛЫ · 1'), findsOneWidget);
      expect(find.text('+ канал · позже'), findsNothing);
      expect(find.byKey(const ValueKey('key-1')), findsOneWidget);
      for (final key in ['1', '2', '1', '.', '5']) {
        await tester.tap(find.byKey(ValueKey('key-$key')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('key-OK')));
      await tester.pump();
      expect(radio.centerFrequency, 121500000);
      expect(radio.vfoOffset, 0);
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pump();
      expect(find.text('Air Traffic'), findsOneWidget);
      final air = favorites.entries.firstWhere((f) => f.name == 'Air Traffic');
      await tester.tap(find.byKey(ValueKey('apply-${air.id}')));
      await tester.pump();
      expect(radio.tunedFrequency, 125000000);
      expect(radio.vfoOffset, 0);
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pump();
      expect(find.text('Настройки приёмника'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );
}

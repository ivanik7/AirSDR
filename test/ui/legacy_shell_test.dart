import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
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
    'add arbitrary current frequency, edit, filter, delete and persist',
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
      await tester.tap(find.byKey(const ValueKey('tab-1')));
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
      await tester.tap(find.byKey(const ValueKey('category-FM')));
      await tester.pump();
      expect(find.text('Своя станция'), findsOneWidget);
      await tester.tap(
        find.byKey(ValueKey('toggle-${favorites.entries.last.id}')),
      );
      await tester.pump();
      expect(favorites.entries.last.enabled, isFalse);
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
      await tester.tap(find.byKey(ValueKey('favoriteMenu-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить').last);
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

  testWidgets('mode selection and nudge keep centered tuning', (tester) async {
    final radio = DemoRadioController();
    final favorites = FavoritesRepository();
    await favorites.load();
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('legacyMode-USB')));
    await tester.pump();
    expect(radio.mode.label, 'USB');
    expect(radio.vfoOffset, 0);
    await tester.tap(find.byKey(const ValueKey('nudgeRight')));
    await tester.pump();
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
      tester.getCenter(find.byKey(const ValueKey('tuningRuler'))),
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
    'three tabs, MHz keypad, presets apply to the single centered tuner',
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
      // The Приём tab now has real channel slots, not an inert "позже" card.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('channelsSection')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('КАНАЛЫ · 1'), findsOneWidget);
      expect(find.text('+ канал · позже'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('key-1')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      for (final key in ['1', '2', '1', '.', '5']) {
        await tester.tap(find.byKey(ValueKey('key-$key')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('key-OK')));
      await tester.pump();
      expect(radio.centerFrequency, 121500000);
      expect(radio.vfoOffset, 0);
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump();
      expect(find.text('Симплекс 2м'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('apply-builtin-0')));
      await tester.pump();
      expect(radio.tunedFrequency, 145500000);
      expect(radio.vfoOffset, 0);
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pump();
      expect(find.text('Настройки приёмника'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );
}

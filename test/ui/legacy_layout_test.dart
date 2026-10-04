import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/presets_screen.dart';
import 'package:sdr_flutter/ui/legacy/receive_screen.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

/// Demo controller that reports it is running with worst-case long stats,
/// as the real RTL-SDR backend does on the phone.
class _BusyRadio extends DemoRadioController {
  @override
  bool get running => true;
  @override
  String? get lastError =>
      'USB transfer error: LIBUSB_ERROR_IO while reading bulk endpoint 0x81';
  @override
  Map<String, Object?> get stats => const {
    'droppedBuffers': 123456789,
    'audioDropped': 987654321,
    'audioOutput': 'mp_audio_stream_with_a_very_long_backend_name',
    'samplesIn': 123456789012,
  };
}

Future<void> _pumpAt(
  WidgetTester tester,
  Size logical,
  double dpr,
  Widget child,
) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // Fold cover: 904 px / 2.625 ≈ 344 dp; inner: 1812 px / 2.625 ≈ 690 dp.
  for (final size in const [Size(344, 882), Size(690, 829), Size(300, 640)]) {
    for (final tab in const [0, 1, 2, 3]) {
      testWidgets('no overflow at ${size.width}dp, tab $tab, long status', (
        tester,
      ) async {
        final radio = _BusyRadio();
        final favorites = FavoritesRepository();
        await favorites.load();
        favorites.add(
          frequencyHz: 99912345,
          name: 'Очень длинное название пользовательской станции для проверки',
          mode: DemodMode.values.last,
          category: 'FM',
        );
        radio.setTuning(centerFrequency: 1766123456, vfoOffset: 0);
        await _pumpAt(
          tester,
          size,
          2.625,
          LegacyAppShell(controller: radio, favorites: favorites),
        );
        if (tab != 0) {
          await tester.tap(find.byKey(ValueKey('tab-$tab')));
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
        if (tab == 0) {
          final stats = find.byKey(const ValueKey('legacyStats'));
          expect(stats, findsOneWidget);
          final shown = tester.widget<Text>(stats).data!;
          expect(shown, contains('USB drops 123456789'));
          expect(
            tester.getRect(stats).right,
            lessThanOrEqualTo(size.width),
            reason: 'status line must stay on screen',
          );
        }
        await tester.pumpWidget(const SizedBox());
        radio.dispose();
        favorites.dispose();
      });
    }
  }

  test('compact stats line is short and uses fixed MS/s', () {
    final radio = _BusyRadio();
    final line = compactStatsLine(radio);
    expect(
      line,
      startsWith('${(radio.sampleRate / 1e6).toStringAsFixed(2)} MS/s'),
    );
    expect(line, isNot(contains('out ')));
    radio.dispose();
  });

  test('favorite validation errors are never blank', () {
    final repo = FavoritesRepository();
    String reason(void Function() f) {
      try {
        f();
      } on ArgumentError catch (e) {
        return favoriteErrorText(e);
      }
      fail('expected ArgumentError');
    }

    expect(
      reason(
        () => repo.add(
          frequencyHz: 99900000,
          name: '  ',
          mode: DemodMode.values.first,
          category: 'FM',
        ),
      ),
      contains('название'),
    );
    final first = repo.entries.first;
    expect(
      reason(
        () => repo.add(
          frequencyHz: first.frequencyHz,
          name: 'dup',
          mode: DemodMode.values.first,
          category: 'FM',
        ),
      ),
      contains('уже есть'),
    );
    expect(
      reason(
        () => repo.add(
          frequencyHz: 5,
          name: 'low',
          mode: DemodMode.values.first,
          category: 'FM',
          minHz: 24000000,
        ),
      ),
      contains('диапазона'),
    );
    repo.dispose();
  });

  testWidgets('edit dialog shows the preset frequency, not the tuned one', (
    tester,
  ) async {
    final radio = DemoRadioController();
    final favorites = FavoritesRepository();
    await favorites.load();
    radio.setTuning(centerFrequency: 99900000, vfoOffset: 0);
    await _pumpAt(
      tester,
      const Size(344, 882),
      2.625,
      LegacyAppShell(controller: radio, favorites: favorites),
    );
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    final f = favorites.entries.first;
    await tester.tap(find.byKey(ValueKey('favoriteMenu-${f.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Изменить').last);
    await tester.pumpAndSettle();
    expect(
      find.text('Частота ${(f.frequencyHz / 1000000).toStringAsFixed(3)} MHz'),
      findsOneWidget,
    );
    expect(find.text('Частота 99.900 MHz'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });

  testWidgets('saving an unnamed preset shows a readable reason', (
    tester,
  ) async {
    final radio = DemoRadioController();
    final favorites = FavoritesRepository();
    await favorites.load();
    radio.setTuning(centerFrequency: 99900000, vfoOffset: 0);
    await _pumpAt(
      tester,
      const Size(344, 882),
      2.625,
      LegacyAppShell(controller: radio, favorites: favorites),
    );
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('addFavorite')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favoriteSave')));
    await tester.pumpAndSettle();
    expect(find.textContaining('введите название'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('favoriteMenu-builtin-fm')));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(
      find.textContaining('Не удалось сохранить'),
      findsNothing,
      reason: 'stale error must clear on the next action',
    );
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });
}

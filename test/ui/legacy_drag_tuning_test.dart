import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';

class CountingRadio extends DemoRadioController {
  final centers = <double>[];
  @override
  void setTuning({required double centerFrequency, required double vfoOffset}) {
    if (centerFrequency != this.centerFrequency) centers.add(centerFrequency);
    super.setTuning(centerFrequency: centerFrequency, vfoOffset: vfoOffset);
  }
}

void main() {
  test(
    'drag moves DSP VFO without LO tuning; edge shifts half the IQ span',
    () {
      final radio = CountingRadio();
      final receiver = CenteredReceiver(radio);
      final initial = radio.centerFrequency;
      final span = radio.sampleRate;
      receiver.beginDrag();
      receiver.dragBy(25000);
      expect(radio.centers, isEmpty);
      expect(radio.tunedFrequency, initial + 25000);
      expect(radio.vfoOffset, 25000);
      receiver.dragBy(span / 2);
      expect(radio.centers, [initial + span / 2]);
      expect(radio.tunedFrequency, initial + span / 2 + 25000);
      receiver.endDrag();
      expect(radio.centerFrequency, radio.tunedFrequency);
      expect(radio.vfoOffset, 0);
      expect(radio.centers.last, initial + span / 2 + 25000);
      radio.dispose();
    },
  );

  test(
    'negative edge shift and cancel recenter once; direct nudge stays centered',
    () {
      final radio = CountingRadio();
      final receiver = CenteredReceiver(radio);
      final initial = radio.centerFrequency;
      receiver.beginDrag();
      receiver.dragBy(-radio.sampleRate / 2);
      expect(radio.centers, [initial - radio.sampleRate / 2]);
      receiver
          .endDrag(); // onHorizontalDragCancel uses the same completion path.
      expect(radio.vfoOffset, 0);
      expect(radio.centerFrequency, radio.tunedFrequency);
      radio.centers.clear();
      receiver.nudge(1);
      expect(radio.centers, hasLength(1));
      expect(radio.vfoOffset, 0);
      radio.dispose();
    },
  );

  testWidgets(
    'ruler drag keeps offset until finger release, including shell listener',
    (tester) async {
      final radio = CountingRadio();
      final favorites = FavoritesRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, favorites: favorites),
        ),
      );
      final start = tester.getCenter(find.byKey(const ValueKey('tuningRuler')));
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(-40, 0));
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(radio.centers, isEmpty);
      expect(radio.vfoOffset, isNot(0));
      await gesture.up();
      await tester.pump();
      expect(radio.centers, hasLength(1));
      expect(radio.vfoOffset, 0);
      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
    },
  );

  testWidgets('spectrum drag offsets VFO; cancellation recenters', (
    tester,
  ) async {
    final radio = CountingRadio();
    final favorites = FavoritesRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyAppShell(controller: radio, favorites: favorites),
      ),
    );
    final start = tester.getCenter(
      find.byKey(const ValueKey('legacySpectrumDrag')),
    );
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(radio.centers, isEmpty);
    expect(radio.vfoOffset, isNot(0));
    await gesture.cancel();
    await tester.pump();
    expect(radio.centers, hasLength(1));
    expect(radio.vfoOffset, 0);
    await tester.pumpWidget(const SizedBox());
    radio.dispose();
    favorites.dispose();
  });
}

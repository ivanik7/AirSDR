// Golden-free smoke test of MainScreen with the DemoRadioController.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/main_screen.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';
import 'package:sdr_flutter/ui/spectrum_waterfall.dart';

void main() {
  Future<void> runFrames(WidgetTester tester, DemoRadioController c, int n) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(Duration(milliseconds: 1000 ~/ c.fftRate));
    }
  }

  for (final size in const [Size(420, 860), Size(900, 420)]) {
    testWidgets('MainScreen runs with demo data (${size.width}x${size.height})', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final c = DemoRadioController();
      await tester.pumpWidget(MaterialApp(home: MainScreen(controller: c)));
      await tester.pump();
      expect(find.byType(SpectrumWaterfallView), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('modeSelector')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Start.
      await tester.tap(find.byKey(const ValueKey<String>('playStop')));
      await tester.pump();
      expect(c.running, isTrue);
      await runFrames(tester, c, 8);
      expect(c.rowsEmitted, greaterThanOrEqualTo(4));

      // Mode change via segmented button.
      await tester.tap(find.text('NFM'));
      await tester.pump();
      expect(c.mode, DemodMode.nfm);
      expect(c.bandwidth, 12500);

      // Tap on the waterfall tunes the VFO.
      final before = c.tunedFrequency;
      final wf = tester.getRect(find.byKey(const ValueKey<String>('waterfall')));
      await tester.tapAt(Offset(wf.left + wf.width * 0.75, wf.center.dy));
      await tester.pump();
      expect(c.tunedFrequency, isNot(before));
      expect(c.tunedFrequency % 2500, 0);

      // Horizontal drag on the waterfall pans (full view → LO moves).
      final lo = c.centerFrequency;
      await tester.dragFrom(wf.center, const Offset(-120, 0));
      await tester.pump();
      expect(c.centerFrequency, greaterThan(lo));

      // Step button: +snap, rounded to the snap grid (main_window.cpp:590-591).
      final t0 = c.tunedFrequency;
      await tester.tap(find.byKey(const ValueKey<String>('stepUp')));
      await tester.pump();
      expect(c.tunedFrequency, ((t0 + 2500) / 2500).round() * 2500.0);

      // Device dropdown is disabled while running.
      final dd = tester.widget<DropdownButton<SdrDeviceInfo>>(find.byKey(const ValueKey<String>('deviceDropdown')));
      expect(dd.onChanged, isNull);

      await runFrames(tester, c, 5);
      expect(tester.takeException(), isNull);

      // Stop.
      await tester.tap(find.byKey(const ValueKey<String>('playStop')));
      await tester.pump();
      expect(c.running, isFalse);

      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
}

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/sdr_ui_state.dart';
import 'package:sdr_flutter/ui/spectrum_waterfall.dart';
import 'package:sdr_flutter/ui/waterfall_model.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'waterfall rows keep pixel positions at different heights; speed changes spacing',
    (tester) async {
      final radio = DemoRadioController();
      final model = WaterfallModel(width: 40, height: 64, autoSchedule: false);
      final state = SdrUiState(radio, waterfall: model);
      final vp = state.displayViewport;
      for (final level in [-45.0, -75.0, -105.0]) {
        model.pushRow(
          Float32List.fromList(List.filled(40, level)),
          vp.lowerFreq,
          vp.upperFreq,
        );
      }
      model.flush();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(model.image, isNotNull);
      const key = ValueKey('waterfall-test');
      Future<Uint8List> pixels(double height) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 40,
                  height: height,
                  child: CustomPaint(painter: WaterfallPainter(state: state)),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        return (await tester.runAsync(() async {
          final image = await (tester.renderObject<RenderRepaintBoundary>(
            find.byKey(key),
          )).toImage(pixelRatio: 1);
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          image.dispose();
          return data.buffer.asUint8List();
        }))!;
      }

      // The top three rows occupy exactly the same 6 logical pixels.
      final short = await pixels(12);
      final tall = await pixels(24);
      expect(short.sublist(0, 6 * 40 * 4), tall.sublist(0, 6 * 40 * 4));
      state.setWaterfallRowHeight(4);
      final slow = await pixels(24);
      // A line now occupies four pixels rather than two.
      expect(slow[2], greaterThan(0));
      expect(
        slow.sublist(2 * 40 * 4, 4 * 40 * 4),
        isNot(short.sublist(2 * 40 * 4, 4 * 40 * 4)),
      );
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      radio.dispose();
    },
  );
}

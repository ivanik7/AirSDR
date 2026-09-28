// Tests for lib/ui/waterfall_model.dart, lib/ui/demo_radio_controller.dart,
// lib/ui/sdr_ui_state.dart.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/colormaps.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';
import 'package:sdr_flutter/ui/sdr_ui_state.dart';
import 'package:sdr_flutter/ui/tuner.dart';
import 'package:sdr_flutter/ui/waterfall_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WaterfallModel', () {
    test('ring: head moves down, rows colourised with palette', () {
      final m = WaterfallModel(width: 4, height: 3, autoSchedule: false);
      m.setView(0, 4);
      m.setLevels(-100, 0);
      m.flush();
      expect(m.lines, 0);
      m.pushRow(Float32List.fromList([-100, -50, 0, 10]), 0, 4);
      expect(m.head, 2);
      expect(m.lines, 1);
      final pal = m.palette;
      expect(m.rgba.sublist(8, 12), [
        pal[0],
        pal[(0.5 * (pal.length - 1)).toInt()],
        pal[pal.length - 1],
        pal[pal.length - 1],
      ]);
      expect(m.latestFFT, [-100, -50, 0, 10]);
      m.pushRow(Float32List.fromList([-100, -100, -100, -100]), 0, 4);
      m.pushRow(Float32List.fromList([-100, -100, -100, -100]), 0, 4);
      m.pushRow(Float32List.fromList([0, 0, 0, 0]), 0, 4);
      expect(m.head, 2); // wrapped
      expect(m.lines, 3);
      expect(m.rgba[8], pal[pal.length - 1]);
    });

    test('full update on view change re-projects history', () {
      final m = WaterfallModel(width: 4, height: 2, autoSchedule: false);
      m.setView(0, 4);
      m.setLevels(-100, 0);
      m.flush();
      m.pushRow(Float32List.fromList([-100, -100, 0, -100]), 0, 4);
      m.flush();
      // Zoom out ×2 centred: the row now covers the middle half.
      m.setView(-2, 6);
      m.flush();
      final row = m.head * 4;
      expect(m.rgba[row + 0], kOpaqueBlack);
      expect(m.rgba[row + 3], kOpaqueBlack);
      expect(m.rgba[row + 2], m.palette[m.palette.length - 1]); // [2,4) contains the 0 dB bin
      // Unfilled row stays black.
      final other = ((m.head + 1) % 2) * 4;
      expect(m.rgba.sublist(other, other + 4), everyElement(kOpaqueBlack));
    });

    test('levels and colormap trigger recolour', () {
      final m = WaterfallModel(width: 2, height: 1, autoSchedule: false);
      m.setView(0, 2);
      m.setLevels(-100, 0);
      m.pushRow(Float32List.fromList([-50, -50]), 0, 2);
      m.flush();
      final before = m.rgba[0];
      m.setLevels(-50, 0);
      m.flush();
      expect(m.rgba[0], m.palette[0]);
      expect(m.rgba[0], isNot(before));
      m.setColorMap(colorMapByName('turbo'));
      m.flush();
      expect(m.rgba[0], buildPalette(colorMapByName('turbo').colors)[0]);
    });

    test('hold and smoothing affect only the spectrum line', () {
      final m = WaterfallModel(width: 2, height: 2, autoSchedule: false)
        ..fftHold = true
        ..fftHoldSpeed = 1
        ..fftSmoothing = true
        ..fftSmoothingAlpha = 0.5
        ..fftSmoothingBeta = 0.5;
      m.setView(0, 2);
      m.setLevels(-100, 0);
      m.flush();
      m.pushRow(Float32List.fromList([-10, -10]), 0, 2);
      m.pushRow(Float32List.fromList([-30, -30]), 0, 2);
      expect(m.latestFFT[1], -20);
      expect(m.latestFFTHold[1], -11);
      // Waterfall row is the unsmoothed −30 dB.
      final pal = m.palette;
      expect(m.rgba[m.head * 2 + 1], pal[(0.7 * (pal.length - 1)).toInt()]);
    });

    test('resize keeps newest rows', () {
      final m = WaterfallModel(width: 4, height: 4, autoSchedule: false);
      m.setView(0, 4);
      for (var i = 0; i < 3; i++) {
        m.pushRow(Float32List.fromList([i * -10.0, 0, 0, 0]), 0, 4);
      }
      m.resize(8, 2);
      m.flush();
      expect(m.width, 8);
      expect(m.height, 2);
      expect(m.lines, 2);
      expect(m.latestFFT[0], -20);
    });
  });

  group('DemoRadioController', () {
    test('mode switch uses per-mode bandwidth limits', () {
      final c = DemoRadioController();
      expect(c.mode, DemodMode.wfm);
      expect(c.bandwidth, 150000);
      c.setMode(DemodMode.usb);
      expect(c.bandwidth, 2800);
      expect(c.snapInterval, 100);
      expect(c.vfoCenterOffset, c.vfoOffset + 1400);
      c.setBandwidth(1e6);
      expect(c.bandwidth, 12000);
      c.setMode(DemodMode.raw);
      c.setBandwidth(1000);
      expect(c.bandwidth, 48000);
      c.setMode(DemodMode.usb);
      expect(c.bandwidth, 12000); // remembered per mode
      c.dispose();
    });

    test('synthRow has a carrier peak and noise floor', () {
      final c = DemoRadioController();
      final row = c.synthRow(100e6, 98.8e6, 101.2e6, 1200, 0);
      // 100.1 MHz carrier at x = (100.1-98.8)/2.4*1200 = 650
      final peak = row.sublist(640, 660).reduce((a, b) => a > b ? a : b);
      expect(peak, greaterThan(-60));
      final floor = row.sublist(10, 50).reduce((a, b) => a + b) / 40;
      expect(floor, lessThan(-80));
      c.dispose();
    });

    test('emits rows while running', () async {
      final c = DemoRadioController(fftRate: 50);
      c.setFftWidth(64);
      final rows = <FftRow>[];
      final sub = c.fftRows.listen(rows.add);
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await c.stop();
      final n = rows.length;
      expect(n, greaterThanOrEqualTo(2));
      expect(rows.first.width, 64);
      expect(rows.first.span, closeTo(c.sampleRate, 1));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(rows.length, n);
      await sub.cancel();
      c.dispose();
    });
  });

  group('SdrUiState', () {
    test('tap-to-tune snaps and updates controller (NORMAL)', () {
      final c = DemoRadioController();
      final ui = SdrUiState(c, waterfall: WaterfallModel(autoSchedule: false));
      c.setMode(DemodMode.nfm); // snap 2500
      ui.tapAt(750, 1000); // +0.25 * sr
      final expected = ((c.centerFrequency + 0.25 * c.sampleRate) / 2500).round() * 2500.0;
      expect(c.tunedFrequency, expected);
      expect(ui.tunedFrequency, expected);
      expect(c.centerFrequency, 100e6);
      ui.dispose();
      c.dispose();
    });

    test('tap in CENTER mode retunes the LO', () {
      final c = DemoRadioController();
      final ui = SdrUiState(c, waterfall: WaterfallModel(autoSchedule: false), tuningMode: TuningMode.center);
      c.setMode(DemodMode.nfm);
      ui.tapAt(750, 1000);
      expect(c.vfoOffset, 0);
      expect(c.centerFrequency, ((100e6 + 0.25 * c.sampleRate) / 2500).round() * 2500.0);
      ui.dispose();
      c.dispose();
    });

    test('step, tuneTo, levels, sample-rate change resets zoom', () {
      final c = DemoRadioController();
      final ui = SdrUiState(c, waterfall: WaterfallModel(autoSchedule: false));
      ui.step(1); // WFM snap 100 kHz
      expect(c.tunedFrequency, 100.1e6);
      ui.tuneTo(145.5e6);
      expect(c.tunedFrequency, closeTo(145.5e6, 1e-3));
      ui.setLevels(-50, -45);
      expect(ui.fftMax - ui.fftMin, greaterThanOrEqualTo(10));
      ui.setZoomSlider(0.5);
      expect(ui.viewport.viewBandwidth, lessThan(c.sampleRate));
      c.setSampleRate(c.selectedDevice!.sampleRates.first);
      expect(ui.viewport.wholeBandwidth, c.sampleRate);
      expect(ui.viewport.viewBandwidth, c.sampleRate);
      ui.dispose();
      c.dispose();
    });
  });
}

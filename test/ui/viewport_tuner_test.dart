// Tests for lib/ui/viewport.dart and lib/ui/tuner.dart
// (ports of SDR++ WaterFall view math, WaterfallVFO, gui/tuner.cpp).

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';
import 'package:sdr_flutter/ui/tuner.dart';
import 'package:sdr_flutter/ui/viewport.dart';

void main() {
  group('pixel <-> frequency', () {
    test('full view', () {
      final vp = FftViewport(centerFreq: 100e6, bandwidth: 2.4e6);
      expect(vp.lowerFreq, 98.8e6);
      expect(vp.upperFreq, 101.2e6);
      expect(vp.freqToX(100e6, 1000), closeTo(500, 1e-9));
      expect(vp.freqToX(98.8e6, 1000), closeTo(0, 1e-9));
      expect(vp.xToFreq(0, 1000), closeTo(98.8e6, 1e-6));
      expect(vp.xToFreq(1000, 1000), closeTo(101.2e6, 1e-6));
      expect(vp.xToOffset(250, 1000), closeTo(-600000, 1e-6));
      expect(vp.offsetToX(-600000, 1000), closeTo(250, 1e-9));
      for (final x in [0.0, 123.0, 500.0, 999.0]) {
        expect(vp.freqToX(vp.xToFreq(x, 1000), 1000), closeTo(x, 1e-6));
        expect(vp.xToFreq(x, 1000), closeTo(vp.centerFreq + vp.xToOffset(x, 1000), 1e-3));
      }
    });

    test('zoomed + offset view', () {
      final vp = FftViewport(centerFreq: 100e6, bandwidth: 2.4e6);
      vp.setViewBandwidth(1e6);
      vp.setViewOffset(300000);
      expect(vp.lowerFreq, 99.8e6);
      expect(vp.upperFreq, 100.8e6);
      expect(vp.xToOffset(500, 1000), 300000);
      expect(vp.freqToX(100.3e6, 1000), closeTo(500, 1e-9));
    });

    test('snap rounds the ABSOLUTE frequency', () {
      final vp = FftViewport(centerFreq: 100.0123e6, bandwidth: 2.4e6);
      final off = vp.xToSnappedOffset(521, 1000, 100000)!;
      expect((vp.centerFreq + off) % 100000, closeTo(0, 1e-6));
      expect(vp.centerFreq + off, closeTo(100.1e6, 1e-3));
      expect(vp.xToSnappedOffset(-1, 1000, 1000), isNull);
      expect(vp.xToSnappedOffset(1000, 1000, 1000), isNull);
    });
  });

  group('view clamps / pan / zoom', () {
    test('setViewOffset clamps inside the band', () {
      final vp = FftViewport(centerFreq: 100e6, bandwidth: 2.4e6);
      vp.setViewBandwidth(1e6);
      vp.setViewOffset(5e6);
      expect(vp.viewOffset, 700000);
      vp.setViewOffset(-5e6);
      expect(vp.viewOffset, -700000);
    });

    test('setViewBandwidth pulls viewOffset in', () {
      final vp = FftViewport(centerFreq: 100e6, bandwidth: 2.4e6);
      vp.setViewBandwidth(0.4e6);
      vp.setViewOffset(1e6);
      vp.setViewBandwidth(2e6);
      expect(vp.viewOffset, 200000);
    });

    test('dragView pans; past the edge moves the LO', () {
      final vp = FftViewport(centerFreq: 100e6, bandwidth: 2.4e6);
      vp.setViewBandwidth(1e6);
      // Drag right by 100 px (1 px = 1 kHz) → view moves down in frequency.
      expect(vp.dragView(100, 1000), 0);
      expect(vp.viewOffset, -100000);
      // Drag left by 1000 px → +1 MHz; limit is +700 kHz, the rest moves LO.
      final moved = vp.dragView(-1000, 1000);
      expect(vp.viewOffset, 700000);
      expect(moved, closeTo(200000, 1e-6));
      expect(vp.centerFreq, closeTo(100.2e6, 1e-6));
      // Locked LO.
      final m2 = vp.dragView(-100, 1000, centerFrequencyLocked: true);
      expect(m2, 0);
      expect(vp.centerFreq, closeTo(100.2e6, 1e-6));
    });

    test('dragView on a full view moves only the LO', () {
      final vp = FftViewport(centerFreq: 100e6, bandwidth: 2.4e6);
      final moved = vp.dragView(-100, 1000); // 1 px = 2.4 kHz
      expect(moved, closeTo(240000, 1e-6));
      expect(vp.viewOffset, 0);
    });

    test('zoomAround keeps the focal frequency fixed', () {
      final vp = FftViewport(centerFreq: 100e6, bandwidth: 2.4e6);
      final f = vp.xToFreq(250, 1000);
      vp.zoomAround(2, 250, 1000);
      expect(vp.viewBandwidth, 1.2e6);
      expect(vp.viewOffset, -300000);
      expect(vp.xToFreq(250, 1000), closeTo(f, 1e-3));
      // Cannot zoom out beyond the band or in below 1 kHz.
      vp.zoomAround(0.01, 500, 1000);
      expect(vp.viewBandwidth, 2.4e6);
      expect(vp.viewOffset, 0);
      vp.zoomAround(1e9, 500, 1000);
      expect(vp.viewBandwidth, 1000);
    });

    test('zoom slider mapping (main_window.cpp) and inverse', () {
      expect(zoomSliderToViewBandwidth(1, 2.4e6), 2.4e6);
      expect(zoomSliderToViewBandwidth(0, 2.4e6), 1000);
      expect(zoomSliderToViewBandwidth(0.5, 2.4e6), 1000 + 0.25 * (2.4e6 - 1000));
      expect(viewBandwidthToZoomSlider(zoomSliderToViewBandwidth(0.3, 2.4e6), 2.4e6), closeTo(0.3, 1e-12));
    });

    test('resetForSampleRate', () {
      final vp = FftViewport(centerFreq: 100e6, bandwidth: 2.4e6);
      vp.setViewBandwidth(1e6);
      vp.setViewOffset(500000);
      vp.resetForSampleRate(8e6);
      expect(vp.wholeBandwidth, 8e6);
      expect(vp.viewBandwidth, 8e6);
      expect(vp.viewOffset, 0);
    });
  });

  group('WaterfallVfo', () {
    test('references (setOffset / setCenterOffset / setBandwidth)', () {
      final usb = WaterfallVfo(reference: VfoReference.lower, bandwidth: 2800, offset: 1000);
      expect(usb.lowerOffset, 1000);
      expect(usb.centerOffset, 2400);
      expect(usb.upperOffset, 3800);
      usb.setBandwidth(3000);
      expect(usb.lowerOffset, 1000);
      expect(usb.centerOffset, 2500);
      usb.setCenterOffset(0);
      expect(usb.generalOffset, -1500);

      final lsb = WaterfallVfo(reference: VfoReference.upper, bandwidth: 2800, offset: 0);
      expect(lsb.centerOffset, -1400);
      expect(lsb.lowerOffset, -2800);
      lsb.setReference(VfoReference.center);
      expect(lsb.centerOffset, 0);
    });

    test('pixels (updateDrawingVars)', () {
      final vfo = WaterfallVfo(bandwidth: 200000, offset: 0);
      final px = vfo.pixels(2.4e6, 1200, 0);
      expect(px.line, 600);
      // 200 kHz of 2.4 MHz over 1200 px = 100 px
      expect(px.rectLeft, 550);
      expect(px.rectRight, 651);
      expect(px.lineVisible, isTrue);
      final edge = WaterfallVfo(bandwidth: 200000, offset: 1.2e6).pixels(2.4e6, 1200, 0);
      expect(edge.lineVisible, isFalse);
      expect(edge.rightClamped, isTrue);
    });
  });

  group('tuner', () {
    FftViewport vp0() => FftViewport(centerFreq: 100e6, bandwidth: 2.4e6);

    test('CENTER: LO jumps, VFO to 0, view centred', () {
      final vp = vp0();
      vp.setViewBandwidth(1e6);
      vp.setViewOffset(500000);
      final vfo = WaterfallVfo(bandwidth: 200000, offset: 300000);
      tune(TuningMode.center, vp, vfo, 105e6);
      expect(vp.centerFreq, 105e6);
      expect(vfo.generalOffset, 0);
      expect(vp.viewOffset, 0);
    });

    test('NORMAL: VFO still fits in view → only VFO moves', () {
      final vp = vp0();
      final vfo = WaterfallVfo(bandwidth: 200000, offset: 0);
      tune(TuningMode.normal, vp, vfo, 100.5e6);
      expect(vp.centerFreq, 100e6);
      expect(vfo.centerOffset, 500000);
    });

    test('NORMAL: VFO above the SDR band → retune LO', () {
      final vp = vp0();
      final vfo = WaterfallVfo(bandwidth: 200000, offset: 0);
      tune(TuningMode.normal, vp, vfo, 102e6);
      // newVFOOffset = vfoBW/2 − BW/2 + viewBW/10 = 100k − 1.2M + 240k
      expect(vfo.generalOffset, closeTo(-860000, 1e-6));
      expect(vp.centerFreq, closeTo(102.86e6, 1e-3));
      expect(vp.centerFreq + vfo.generalOffset, closeTo(102e6, 1e-3));
    });

    test('NORMAL: VFO below the SDR band → retune LO', () {
      final vp = vp0();
      final vfo = WaterfallVfo(bandwidth: 200000, offset: 0);
      tune(TuningMode.normal, vp, vfo, 98e6);
      expect(vfo.generalOffset, closeTo(860000, 1e-6));
      expect(vp.centerFreq, closeTo(97.14e6, 1e-3));
    });

    test('NORMAL: inside band but outside view → view shifts, LO stays', () {
      final vp = vp0();
      vp.setViewBandwidth(0.5e6);
      final vfo = WaterfallVfo(bandwidth: 200000, offset: 0);
      tune(TuningMode.normal, vp, vfo, 100.3e6);
      expect(vp.centerFreq, 100e6);
      expect(vfo.centerOffset, 300000);
      expect(vp.viewOffset, 400000); // vfoBottom + viewBW/2 − viewBW/10
    });

    test('NORMAL: outside view and view would hit band edge → retune LO', () {
      final vp = vp0();
      vp.setViewBandwidth(1e6);
      final vfo = WaterfallVfo(bandwidth: 200000, offset: 0);
      tune(TuningMode.normal, vp, vfo, 100.8e6);
      expect(vp.viewOffset, -700000);
      expect(vfo.centerOffset, closeTo(-1.0e6, 1e-6));
      expect(vp.centerFreq, closeTo(101.8e6, 1e-3));
    });

    test('NORMAL: downward move inside band, outside view', () {
      final vp = vp0();
      vp.setViewBandwidth(0.5e6);
      final vfo = WaterfallVfo(bandwidth: 200000, offset: 0);
      tune(TuningMode.normal, vp, vfo, 99.7e6);
      expect(vp.centerFreq, 100e6);
      expect(vfo.centerOffset, -300000);
      expect(vp.viewOffset, -400000); // vfoTop − viewBW/2 + viewBW/10
    });

    test('no VFO → CENTER; IQ only moves LO', () {
      final vp = vp0();
      normalTuning(vp, null, 101e6);
      expect(vp.centerFreq, 101e6);
      final vfo = WaterfallVfo(bandwidth: 200000, offset: 100000);
      tune(TuningMode.iqOnly, vp, vfo, 90e6);
      expect(vp.centerFreq, 90e6);
      expect(vfo.generalOffset, 100000);
    });
  });
}

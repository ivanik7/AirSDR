// Unit tests for the R820T/R828D tuner port (lib/drivers/rtlsdr/tuner_r82xx.dart).
// The full register sequences are verified against C by oracle_trace_test.dart;
// these tests pin down the pure helpers and a few hand-computed results.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/drivers/rtlsdr/rtl_sdr.dart';
import 'package:sdr_flutter/drivers/rtlsdr/rtlsdr_i2c.dart';
import 'package:sdr_flutter/drivers/rtlsdr/tuner_r82xx.dart';

/// Minimal RtlSdrI2c: records I2C writes, answers reads with a locked PLL.
class _I2c implements RtlSdrI2c {
  final writes = <List<int>>[];
  final gpio = <List<int>>[];
  String manufact = 'Realtek', product = 'RTL2838UHIDIR';
  bool lock = true;

  @override
  bool checkDongleModel(String m, String p) => m == manufact && p == product;
  @override
  int getTunerClock() => 28800000;
  @override
  int setBiasTeeGpio(int g, int on) {
    gpio.add([g, on]);
    return 0;
  }

  @override
  int i2cWriteFn(int addr, Uint8List buf, int len) {
    writes.add([addr, ...buf.sublist(0, len)]);
    return len;
  }

  @override
  int i2cReadFn(int addr, Uint8List buf, int len) {
    // status regs are bit-reversed on the wire
    final st = [0x96, 0x00, lock ? 0x40 : 0x00, 0x00, 0x18];
    for (var i = 0; i < len; i++) {
      buf[i] = r82xxBitrev(st[i]);
    }
    return len;
  }
}

R82xxPriv _newTuner(_I2c i2c, {bool r828d = false}) {
  final cfg = R82xxConfig()
    ..i2cAddr = r828d ? r828dI2cAddr : r820tI2cAddr
    ..rafaelChip = r828d ? R82xxChip.r828d : R82xxChip.r820t
    ..xtal = 28800000
    ..maxI2cMsgLen = 8;
  return R82xxPriv(cfg, i2c);
}

void main() {
  rtlsdrLog = (_) {};

  test('r82xxBitrev reverses bits of a byte', () {
    expect(r82xxBitrev(0x01), 0x80);
    expect(r82xxBitrev(0x96), 0x69);
    expect(r82xxBitrev(0xf0), 0x0f);
    for (var b = 0; b < 256; b++) {
      expect(r82xxBitrev(r82xxBitrev(b)), b);
    }
  });

  test('init array covers NUM_REGS (incl. implicit C zero padding)', () {
    expect(r82xxInitArray.length, numRegs);
    expect(r82xxInitArray.sublist(27), [0, 0, 0]);
  });

  test('init writes shadow regs in 7-byte chunks and completes', () {
    final i2c = _I2c();
    final t = _newTuner(i2c);
    expect(t.r82xxInit(), 0);
    expect(t.initDone, 1);
    expect(t.hasLock, 1);
    expect(t.intFreq, 3570000);
    // first 5 writes: 30 regs from 0x05 in chunks of 7 (+1 reg byte)
    expect(i2c.writes.take(5).map((w) => w[1]).toList(),
        [0x05, 0x0c, 0x13, 0x1a, 0x21]);
    expect(i2c.writes.take(5).every((w) => w[0] == r820tI2cAddr), isTrue);
    expect(i2c.writes.take(5).every((w) => w.length <= 1 + 8), isTrue);
  });

  test('set_bandwidth returns the IF frequency for the chosen filter', () {
    final t = _newTuner(_I2c())..r82xxInit();
    expect(t.r82xxSetBandwidth(8000000, 0), 4570000);
    expect(t.r82xxSetBandwidth(6500000, 0), 4570000);
    expect(t.r82xxSetBandwidth(2500000, 0), 3570000);
    // hand-computed from tuner_r82xx.c:1078-1109 for bw = 2.4 MHz
    expect(t.r82xxSetBandwidth(2400000, 0), 1815000);
    expect(t.regs[0x0b - regShadowStart] & 0xef, 0x8f & 0xef);
  });

  test('manual gain picks LNA/mixer indices by accumulating steps', () {
    final i2c = _I2c();
    final t = _newTuner(i2c)..r82xxInit();
    expect(t.r82xxSetGain(1, 0), 0);
    expect(t.regs[0x05 - regShadowStart] & 0x0f, 0);
    expect(t.regs[0x07 - regShadowStart] & 0x0f, 0);
    // 9 (lna1) + 5 (mix1) + 13 (lna2) = 27 >= 27
    expect(t.r82xxSetGain(1, 27), 0);
    expect(t.regs[0x05 - regShadowStart] & 0x0f, 2);
    expect(t.regs[0x07 - regShadowStart] & 0x0f, 1);
    expect(t.regs[0x05 - regShadowStart] & 0x10, 0x10); // LNA auto off
    expect(t.regs[0x0c - regShadowStart] & 0x9f, 0x08); // VGA fixed
    // max gain -> 15/15
    t.r82xxSetGain(1, 10000);
    expect(t.regs[0x05 - regShadowStart] & 0x0f, 15);
    expect(t.regs[0x07 - regShadowStart] & 0x0f, 15);
    // auto
    t.r82xxSetGain(0, 0);
    expect(t.regs[0x05 - regShadowStart] & 0x10, 0);
    expect(t.regs[0x07 - regShadowStart] & 0x10, 0x10);
    expect(t.regs[0x0c - regShadowStart] & 0x9f, 0x0b);
  });

  test('shadow registers suppress redundant writes', () {
    final i2c = _I2c();
    final t = _newTuner(i2c)..r82xxInit();
    t.r82xxSetGain(0, 0);
    final n = i2c.writes.length;
    t.r82xxSetGain(0, 0);
    expect(i2c.writes.length, n);
  });

  test('PLL not locked -> set_freq returns 0 but has_lock = 0', () {
    final i2c = _I2c();
    final t = _newTuner(i2c)..r82xxInit();
    i2c.lock = false;
    expect(t.r82xxSetFreq(100000000), 0);
    expect(t.hasLock, 0);
  });

  test('Blog V4: HF upconversion, GPIO5 input switching', () {
    final i2c = _I2c()
      ..manufact = 'RTLSDRBlog'
      ..product = 'Blog V4';
    final t = _newTuner(i2c, r828d: true)..r82xxInit();
    expect(t.r82xxSetFreq(7000000), 0);
    expect(t.input, 1); // HF
    expect(i2c.gpio.last, [5, 0]); // upconverter path: cable2 active
    expect(t.regs[0x06 - regShadowStart] & 0x08, 0x08);
    expect(t.regs[0x1b - regShadowStart], 0x00); // tracking filter bypass
    i2c.gpio.clear();
    expect(t.r82xxSetFreq(7100000), 0);
    expect(i2c.gpio, isEmpty); // no band change -> no switching
    expect(t.r82xxSetFreq(100000000), 0);
    expect(t.input, 2); // VHF
    expect(i2c.gpio.last, [5, 1]);
    expect(t.regs[0x17 - regShadowStart] & 0x08, 0x00); // FM notch off in band
    expect(t.r82xxSetFreq(400000000), 0);
    expect(t.input, 3); // UHF
    expect(t.regs[0x17 - regShadowStart] & 0x08, 0x08);
  });

  test('plain R828D switches Cable1/Air-In at 345 MHz', () {
    final t = _newTuner(_I2c(), r828d: true)..r82xxInit();
    t.r82xxSetFreq(300000000);
    expect(t.input, 0x60);
    expect(t.regs[0x05 - regShadowStart] & 0x60, 0x60);
    t.r82xxSetFreq(400000000);
    expect(t.input, 0x00);
    expect(t.regs[0x05 - regShadowStart] & 0x60, 0x00);
  });

  test('standby only after init', () {
    final i2c = _I2c();
    final t = _newTuner(i2c);
    expect(t.r82xxStandby(), 0);
    expect(i2c.writes, isEmpty);
    t.r82xxInit();
    expect(t.r82xxStandby(), 0);
    expect(t.type, -1);
    expect(t.regs[0x06 - regShadowStart], 0xb1);
  });
}

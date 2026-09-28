// Dart port of the Fitipower FC0012 tuner driver.
//
// Source: ~/prj/ref/rtl-sdr/src/tuner_fc0012.c (osmocom rtl-sdr v2.0.3, 333
// lines) and include/tuner_fc0012.h.
//
// Fitipower FC0012 tuner driver
//
// Copyright (C) 2012 Hans-Frieder Vogt <hfvogt@gmx.net>
//
// modified for use in librtlsdr
// Copyright (C) 2012 Steve Markgraf <steve@steve-m.de>
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version. (Distributed in this app under GPL-3.0.)
//
// Porting notes: see fcPllRegs() (shared with tuner_fc0013.dart) for the C
// integer arithmetic reproduced bit-exactly (incl. the 32-bit overflow of
// `freq * multi`).

import 'dart:typed_data';

import 'rtl_sdr.dart' show rtlsdrLog;
import 'rtlsdr_i2c.dart';

const int fc0012I2cAddr = 0xc6; // FC0012_I2C_ADDR
const int fc0012CheckAddr = 0x00; // FC0012_CHECK_ADDR
const int fc0012CheckVal = 0xa1; // FC0012_CHECK_VAL

int _writereg(RtlSdrI2c dev, int reg, int val) {
  final data = Uint8List(2);
  data[0] = reg;
  data[1] = val;

  if (dev.i2cWriteFn(fc0012I2cAddr, data, 2) < 0) return -1;

  return 0;
}

/// Returns 0 and the value, or -1 (value null) on error.
(int, int?) _readreg(RtlSdrI2c dev, int reg) {
  final data = Uint8List(1)..[0] = reg;

  if (dev.i2cWriteFn(fc0012I2cAddr, data, 1) < 0) return (-1, null);

  if (dev.i2cReadFn(fc0012I2cAddr, data, 1) < 0) return (-1, null);

  return (0, data[0]);
}

// Incomplete list of register settings: see tuner_fc0012.c:57-89.

int fc0012Init(RtlSdrI2c dev) {
  int ret = 0;
  final reg = Uint8List.fromList([
    0x00, // dummy reg. 0
    0x05, // reg. 0x01
    0x10, // reg. 0x02
    0x00, // reg. 0x03
    0x00, // reg. 0x04
    0x0f, // reg. 0x05: may also be 0x0a
    0x00, // reg. 0x06: divider 2, VCO slow
    0x00, // reg. 0x07: may also be 0x0f
    0xff, // reg. 0x08: AGC Clock divide by 256, AGC gain 1/256,
    //       Loop Bw 1/8
    0x6e, // reg. 0x09: Disable LoopThrough, Enable LoopThrough: 0x6f
    0xb8, // reg. 0x0a: Disable LO Test Buffer
    0x82, // reg. 0x0b: Output Clock is same as clock frequency,
    //       may also be 0x83
    0xfc, // reg. 0x0c: depending on AGC Up-Down mode, may need 0xf8
    0x02, // reg. 0x0d: AGC Not Forcing & LNA Forcing, 0x02 for DVB-T
    0x00, // reg. 0x0e
    0x00, // reg. 0x0f
    0x00, // reg. 0x10: may also be 0x0d
    0x00, // reg. 0x11
    0x1f, // reg. 0x12: Set to maximum gain
    0x00, // reg. 0x13: Set to Low Gain: 0x00,
    //       Low Gain: 0x00, High Gain: 0x10, enable IX2: 0x80
    0x00, // reg. 0x14
    0x04, // reg. 0x15: Enable LNA COMPS
  ]);

  // #if 0: switch (rtlsdr_get_tuner_clock(dev)) ...
  reg[0x07] |= 0x20;

  //	if (priv->dual_master)
  reg[0x0c] |= 0x02;

  for (var i = 1; i < reg.length; i++) {
    ret = _writereg(dev, i, reg[i]);
    if (ret != 0) break;
  }

  return ret;
}

/// PLL register computation shared by fc0012_set_params and
/// fc0013_set_params (identical code in both C files; only the divider
/// table differs). Returns null for "no valid PLL combination".
///
/// C types: freq uint32_t, multi uint8_t, f_vco uint64_t = freq * multi
/// computed in 32 bit (wraps), xtal_freq_div_2 uint32_t, xdiv/xin uint16_t,
/// am/pm uint8_t.
({int multi, bool vcoSelect, Uint8List reg})? fcPllRegs({
  required int freq,
  required int bandwidth,
  required int xtalFreqDiv2,
  required int multi,
  required int reg5,
  required int reg6,
  required String name,
}) {
  final reg = Uint8List(7);
  int am, pm, xin, xdiv;
  bool vcoSelect = false;
  reg[5] = reg5;
  reg[6] = reg6;

  final fVco = (freq * multi) & 0xffffffff;

  if (fVco >= 3060000000) {
    reg[6] |= 0x08;
    vcoSelect = true;
  }

  // From divided value (XDIV) determined the FA and FP value
  xdiv = (fVco ~/ xtalFreqDiv2) & 0xffff;
  // (f_vco - xdiv * xtal_freq_div_2): uint64 - uint32
  final prod = (xdiv * xtalFreqDiv2) & 0xffffffff;
  final diff = fVco - prod; // negative = huge uint64
  if (diff < 0 || diff >= (xtalFreqDiv2 ~/ 2)) xdiv = (xdiv + 1) & 0xffff;

  pm = (xdiv ~/ 8) & 0xff;
  am = (xdiv - (8 * pm)) & 0xff;

  if (am < 2) {
    am = (am + 8) & 0xff;
    pm = (pm - 1) & 0xff;
  }

  if (pm > 31) {
    reg[1] = am + (8 * (pm - 31));
    reg[2] = 31;
  } else {
    reg[1] = am;
    reg[2] = pm;
  }

  if ((reg[1] > 15) || (reg[2] < 0x0b)) {
    rtlsdrLog(
      '[$name] no valid PLL combination '
      'found for ${freq & 0xffffffff} Hz!',
    );
    return null;
  }

  // fix clock out
  reg[6] |= 0x20;

  // From VCO frequency determines the XIN ( fractional part of Delta
  // Sigma PLL) and divided value (XDIV)
  xin = ((fVco - (fVco ~/ xtalFreqDiv2) * xtalFreqDiv2) ~/ 1000) & 0xffff;
  xin = ((xin << 15) ~/ (xtalFreqDiv2 ~/ 1000)) & 0xffff;
  if (xin >= 16384) xin = (xin + 32768) & 0xffff;

  reg[3] = xin >> 8; // xin with 9 bit resolution
  reg[4] = xin & 0xff;

  reg[6] &= 0x3f; // bits 6 and 7 describe the bandwidth
  switch (bandwidth) {
    case 6000000:
      reg[6] |= 0x80;
    case 7000000:
      reg[6] |= 0x40;
    case 8000000:
    default:
      break;
  }

  // modified for Realtek demod
  reg[5] |= 0x07;

  return (multi: multi, vcoSelect: vcoSelect, reg: reg);
}

int fc0012SetParams(RtlSdrI2c dev, int freq, int bandwidth) {
  int ret = 0;
  int multi, r5, r6;
  int? tmp;

  freq &= 0xffffffff;
  final xtalFreqDiv2 = (dev.getTunerClock() & 0xffffffff) ~/ 2;

  // select frequency divider and the frequency of VCO
  if (freq < 37084000) {
    // freq * 96 < 3560000000
    multi = 96;
    r5 = 0x82;
    r6 = 0x00;
  } else if (freq < 55625000) {
    // freq * 64 < 3560000000
    multi = 64;
    r5 = 0x82;
    r6 = 0x02;
  } else if (freq < 74167000) {
    // freq * 48 < 3560000000
    multi = 48;
    r5 = 0x42;
    r6 = 0x00;
  } else if (freq < 111250000) {
    // freq * 32 < 3560000000
    multi = 32;
    r5 = 0x42;
    r6 = 0x02;
  } else if (freq < 148334000) {
    // freq * 24 < 3560000000
    multi = 24;
    r5 = 0x22;
    r6 = 0x00;
  } else if (freq < 222500000) {
    // freq * 16 < 3560000000
    multi = 16;
    r5 = 0x22;
    r6 = 0x02;
  } else if (freq < 296667000) {
    // freq * 12 < 3560000000
    multi = 12;
    r5 = 0x12;
    r6 = 0x00;
  } else if (freq < 445000000) {
    // freq * 8 < 3560000000
    multi = 8;
    r5 = 0x12;
    r6 = 0x02;
  } else if (freq < 593334000) {
    // freq * 6 < 3560000000
    multi = 6;
    r5 = 0x0a;
    r6 = 0x00;
  } else {
    multi = 4;
    r5 = 0x0a;
    r6 = 0x02;
  }

  final p = fcPllRegs(
    freq: freq,
    bandwidth: bandwidth,
    xtalFreqDiv2: xtalFreqDiv2,
    multi: multi,
    reg5: r5,
    reg6: r6,
    name: 'FC0012',
  );
  if (p == null) return -1;
  final reg = p.reg;

  for (var i = 1; i <= 6; i++) {
    ret = _writereg(dev, i, reg[i]);
    if (ret != 0) return ret;
  }

  // VCO Calibration
  ret = _writereg(dev, 0x0e, 0x80);
  if (ret == 0) ret = _writereg(dev, 0x0e, 0x00);

  // VCO Re-Calibration if needed
  if (ret == 0) ret = _writereg(dev, 0x0e, 0x00);

  if (ret == 0) {
    //		msleep(10);
    (ret, tmp) = _readreg(dev, 0x0e);
  }
  if (ret != 0) return ret;

  // vco selection
  final t = tmp! & 0x3f;

  if (p.vcoSelect) {
    if (t > 0x3c) {
      reg[6] &= ~0x08;
      ret = _writereg(dev, 0x06, reg[6]);
      if (ret == 0) ret = _writereg(dev, 0x0e, 0x80);
      if (ret == 0) ret = _writereg(dev, 0x0e, 0x00);
    }
  } else {
    if (t < 0x02) {
      reg[6] |= 0x08;
      ret = _writereg(dev, 0x06, reg[6]);
      if (ret == 0) ret = _writereg(dev, 0x0e, 0x80);
      if (ret == 0) ret = _writereg(dev, 0x0e, 0x00);
    }
  }

  return ret;
}

int fc0012SetGain(RtlSdrI2c dev, int gain) {
  int ret;
  int tmp = 0;

  final (r, v) = _readreg(dev, 0x13);
  ret = r;
  if (v != null) tmp = v;

  // mask bits off
  tmp &= 0xe0;

  if (gain < -40) {
    tmp |= 0x02; // -9.9 dB
  } else if (gain < 71) {
    tmp |= 0x00; // -4.0 dB
  } else if (gain < 179) {
    tmp |= 0x08; //  7.1 dB
  } else if (gain < 192) {
    tmp |= 0x17; // 17.9 dB
  } else {
    tmp |= 0x10; // 19.2 dB
  }

  ret = _writereg(dev, 0x13, tmp);

  return ret;
}

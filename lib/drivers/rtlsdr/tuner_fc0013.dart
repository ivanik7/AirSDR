// Dart port of the Fitipower FC0013 tuner driver.
//
// Source: ~/prj/ref/rtl-sdr/src/tuner_fc0013.c (osmocom rtl-sdr v2.0.3, 500
// lines) and include/tuner_fc0013.h.
//
// Fitipower FC0013 tuner driver
//
// Copyright (C) 2012 Hans-Frieder Vogt <hfvogt@gmx.net>
// partially based on driver code from Fitipower
// Copyright (C) 2010 Fitipower Integrated Technology Inc
//
// modified for use in librtlsdr
// Copyright (C) 2012 Steve Markgraf <steve@steve-m.de>
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version. (Distributed in this app under GPL-3.0.)

import 'dart:typed_data';

import 'rtlsdr_i2c.dart';
import 'tuner_fc0012.dart' show fcPllRegs;

const int fc0013I2cAddr = 0xc6; // FC0013_I2C_ADDR
const int fc0013CheckAddr = 0x00; // FC0013_CHECK_ADDR
const int fc0013CheckVal = 0xa3; // FC0013_CHECK_VAL

int _writereg(RtlSdrI2c dev, int reg, int val) {
  final data = Uint8List(2);
  data[0] = reg;
  data[1] = val;

  if (dev.i2cWriteFn(fc0013I2cAddr, data, 2) < 0) return -1;

  return 0;
}

/// Returns 0 and the value, or -1 (value null) on error.
(int, int?) _readreg(RtlSdrI2c dev, int reg) {
  final data = Uint8List(1)..[0] = reg;

  if (dev.i2cWriteFn(fc0013I2cAddr, data, 1) < 0) return (-1, null);

  if (dev.i2cReadFn(fc0013I2cAddr, data, 1) < 0) return (-1, null);

  return (0, data[0]);
}

int fc0013Init(RtlSdrI2c dev) {
  int ret = 0;
  final reg = Uint8List.fromList([
    0x00, // reg. 0x00: dummy
    0x09, // reg. 0x01
    0x16, // reg. 0x02
    0x00, // reg. 0x03
    0x00, // reg. 0x04
    0x17, // reg. 0x05
    0x02, // reg. 0x06: LPF bandwidth
    0x0a, // reg. 0x07: CHECK
    0xff, // reg. 0x08: AGC Clock divide by 256, AGC gain 1/256,
    //       Loop Bw 1/8
    0x6e, // reg. 0x09: Disable LoopThrough, Enable LoopThrough: 0x6f
    0xb8, // reg. 0x0a: Disable LO Test Buffer
    0x82, // reg. 0x0b: CHECK
    0xfc, // reg. 0x0c: depending on AGC Up-Down mode, may need 0xf8
    0x01, // reg. 0x0d: AGC Not Forcing & LNA Forcing, may need 0x02
    0x00, // reg. 0x0e
    0x00, // reg. 0x0f
    0x00, // reg. 0x10
    0x00, // reg. 0x11
    0x00, // reg. 0x12
    0x00, // reg. 0x13
    0x50, // reg. 0x14: DVB-t High Gain, UHF.
    //       Middle Gain: 0x48, Low Gain: 0x40
    0x01, // reg. 0x15
  ]);
  // #if 0: switch (rtlsdr_get_tuner_clock(dev)) ...
  reg[0x07] |= 0x20;

  //	if (dev->dual_master)
  reg[0x0c] |= 0x02;

  for (var i = 1; i < reg.length; i++) {
    ret = _writereg(dev, i, reg[i]);
    if (ret < 0) break;
  }

  return ret;
}

int fc0013RcCalAdd(RtlSdrI2c dev, int rcVal) {
  int ret;
  int? rcCal;
  int val;

  // push rc_cal value, get rc_cal value
  ret = _writereg(dev, 0x10, 0x00);
  if (ret != 0) return ret;

  // get rc_cal value
  (ret, rcCal) = _readreg(dev, 0x10);
  if (ret != 0) return ret;

  rcCal = rcCal! & 0x0f;

  val = rcCal + rcVal;

  // forcing rc_cal
  ret = _writereg(dev, 0x0d, 0x11);
  if (ret != 0) return ret;

  // modify rc_cal value
  if (val > 15) {
    ret = _writereg(dev, 0x10, 0x0f);
  } else if (val < 0) {
    ret = _writereg(dev, 0x10, 0x00);
  } else {
    ret = _writereg(dev, 0x10, val);
  }

  return ret;
}

int fc0013RcCalReset(RtlSdrI2c dev) {
  int ret;

  ret = _writereg(dev, 0x0d, 0x01);
  if (ret == 0) ret = _writereg(dev, 0x10, 0x00);

  return ret;
}

int _setVhfTrack(RtlSdrI2c dev, int freq) {
  var (ret, tmp) = _readreg(dev, 0x1d);
  if (ret != 0) return ret;
  final t = tmp! & 0xe3;
  if (freq <= 177500000) {
    // VHF Track: 7
    ret = _writereg(dev, 0x1d, t | 0x1c);
  } else if (freq <= 184500000) {
    // VHF Track: 6
    ret = _writereg(dev, 0x1d, t | 0x18);
  } else if (freq <= 191500000) {
    // VHF Track: 5
    ret = _writereg(dev, 0x1d, t | 0x14);
  } else if (freq <= 198500000) {
    // VHF Track: 4
    ret = _writereg(dev, 0x1d, t | 0x10);
  } else if (freq <= 205500000) {
    // VHF Track: 3
    ret = _writereg(dev, 0x1d, t | 0x0c);
  } else if (freq <= 219500000) {
    // VHF Track: 2
    ret = _writereg(dev, 0x1d, t | 0x08);
  } else if (freq < 300000000) {
    // VHF Track: 1
    ret = _writereg(dev, 0x1d, t | 0x04);
  } else {
    // UHF and GPS
    ret = _writereg(dev, 0x1d, t | 0x1c);
  }

  return ret;
}

int fc0013SetParams(RtlSdrI2c dev, int freq, int bandwidth) {
  int ret = 0;
  int multi, r5, r6;
  int? tmp;

  freq &= 0xffffffff;
  final xtalFreqDiv2 = (dev.getTunerClock() & 0xffffffff) ~/ 2;

  // set VHF track
  ret = _setVhfTrack(dev, freq);
  if (ret != 0) return ret;

  if (freq < 300000000) {
    // enable VHF filter
    (ret, tmp) = _readreg(dev, 0x07);
    if (ret != 0) return ret;
    ret = _writereg(dev, 0x07, tmp! | 0x10);
    if (ret != 0) return ret;

    // disable UHF & disable GPS
    (ret, tmp) = _readreg(dev, 0x14);
    if (ret != 0) return ret;
    ret = _writereg(dev, 0x14, tmp! & 0x1f);
    if (ret != 0) return ret;
  } else if (freq <= 862000000) {
    // disable VHF filter
    (ret, tmp) = _readreg(dev, 0x07);
    if (ret != 0) return ret;
    ret = _writereg(dev, 0x07, tmp! & 0xef);
    if (ret != 0) return ret;

    // enable UHF & disable GPS
    (ret, tmp) = _readreg(dev, 0x14);
    if (ret != 0) return ret;
    ret = _writereg(dev, 0x14, (tmp! & 0x1f) | 0x40);
    if (ret != 0) return ret;
  } else {
    // disable VHF filter
    (ret, tmp) = _readreg(dev, 0x07);
    if (ret != 0) return ret;
    ret = _writereg(dev, 0x07, tmp! & 0xef);
    if (ret != 0) return ret;

    // enable UHF & disable GPS
    (ret, tmp) = _readreg(dev, 0x14);
    if (ret != 0) return ret;
    ret = _writereg(dev, 0x14, (tmp! & 0x1f) | 0x40);
    if (ret != 0) return ret;
  }

  // select frequency divider and the frequency of VCO
  if (freq < 37084000) {
    // freq * 96 < 3560000000
    multi = 96;
    r5 = 0x82;
    r6 = 0x00;
  } else if (freq < 55625000) {
    // freq * 64 < 3560000000
    multi = 64;
    r5 = 0x02;
    r6 = 0x02;
  } else if (freq < 74167000) {
    // freq * 48 < 3560000000
    multi = 48;
    r5 = 0x42;
    r6 = 0x00;
  } else if (freq < 111250000) {
    // freq * 32 < 3560000000
    multi = 32;
    r5 = 0x82;
    r6 = 0x02;
  } else if (freq < 148334000) {
    // freq * 24 < 3560000000
    multi = 24;
    r5 = 0x22;
    r6 = 0x00;
  } else if (freq < 222500000) {
    // freq * 16 < 3560000000
    multi = 16;
    r5 = 0x42;
    r6 = 0x02;
  } else if (freq < 296667000) {
    // freq * 12 < 3560000000
    multi = 12;
    r5 = 0x12;
    r6 = 0x00;
  } else if (freq < 445000000) {
    // freq * 8 < 3560000000
    multi = 8;
    r5 = 0x22;
    r6 = 0x02;
  } else if (freq < 593334000) {
    // freq * 6 < 3560000000
    multi = 6;
    r5 = 0x0a;
    r6 = 0x00;
  } else if (freq < 950000000) {
    // freq * 4 < 3800000000
    multi = 4;
    r5 = 0x12;
    r6 = 0x02;
  } else {
    multi = 2;
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
    name: 'FC0013',
  );
  if (p == null) return -1;
  final reg = p.reg;

  for (var i = 1; i <= 6; i++) {
    ret = _writereg(dev, i, reg[i]);
    if (ret != 0) return ret;
  }

  (ret, tmp) = _readreg(dev, 0x11);
  if (ret != 0) return ret;
  if (multi == 64) {
    ret = _writereg(dev, 0x11, tmp! | 0x04);
  } else {
    ret = _writereg(dev, 0x11, tmp! & 0xfb);
  }
  if (ret != 0) return ret;

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

int fc0013SetGainMode(RtlSdrI2c dev, int manual) {
  int ret = 0;
  int tmp = 0;

  final (r, v) = _readreg(dev, 0x0d);
  ret |= r;
  if (v != null) tmp = v;

  if (manual != 0) {
    tmp |= (1 << 3);
  } else {
    tmp &= ~(1 << 3);
  }

  ret |= _writereg(dev, 0x0d, tmp & 0xff);

  // set a fixed IF-gain for now
  ret |= _writereg(dev, 0x13, 0x0a);

  return ret;
}

const List<int> fc0013LnaGains = [
  -99, 0x02, //
  -73, 0x03,
  -65, 0x05,
  -63, 0x04,
  -63, 0x00,
  -60, 0x07,
  -58, 0x01,
  -54, 0x06,
  58, 0x0f,
  61, 0x0e,
  63, 0x0d,
  65, 0x0c,
  67, 0x0b,
  68, 0x0a,
  70, 0x09,
  71, 0x08,
  179, 0x17,
  181, 0x16,
  182, 0x15,
  184, 0x14,
  186, 0x13,
  188, 0x12,
  191, 0x11,
  197, 0x10,
];

const int _gainCnt = 24; // GAIN_CNT

int fc0013SetLnaGain(RtlSdrI2c dev, int gain) {
  int ret = 0;
  int tmp = 0;

  final (r, v) = _readreg(dev, 0x14);
  ret |= r;
  if (v != null) tmp = v;

  // mask bits off
  tmp &= 0xe0;

  for (var i = 0; i < _gainCnt; i++) {
    if ((fc0013LnaGains[i * 2] >= gain) || (i + 1 == _gainCnt)) {
      tmp |= fc0013LnaGains[i * 2 + 1];
      break;
    }
  }

  // set gain
  ret |= _writereg(dev, 0x14, tmp);

  return ret;
}

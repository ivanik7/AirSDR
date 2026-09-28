// Dart port of the Rafael Micro R820T/R828D tuner driver.
//
// Source: ~/prj/ref/rtl-sdr/src/tuner_r82xx.c (osmocom rtl-sdr v2.0.3, 797f814,
// 1427 lines, incl. RTL-SDR Blog V4 / V4L handling in r82xx_set_freq,
// lines 1124-1280) and include/tuner_r82xx.h.
//
// Rafael Micro R820T/R828D driver
//
// Copyright (C) 2013 Mauro Carvalho Chehab <mchehab@redhat.com>
// Copyright (C) 2013 Steve Markgraf <steve@steve-m.de>
//
// This driver is a heavily modified version of the driver found in the
// Linux kernel:
// http://git.linuxtv.org/linux-2.6.git/history/HEAD:/drivers/media/tuners/r820t.c
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// (at your option) any later version. (Distributed in this app under GPL-3.0.)
//
// Porting notes:
//  * C uint8_t/uint32_t wrap-around is reproduced with explicit masks (& 0xff,
//    & 0xffffffff); see r82xxSetPll (div_num - 1, nint, ni, si).
//  * MHZ(x) is a double expression in C (MHZ(28.8)); comparisons are done in
//    double here too.
//  * The (commented out) usleep calls of the C source are kept as comments.

import 'dart:typed_data';

import 'rtl_sdr.dart' show rtlsdrLog;
import 'rtlsdr_i2c.dart';

// ---- include/tuner_r82xx.h ----

const int r820tI2cAddr = 0x34; // R820T_I2C_ADDR
const int r828dI2cAddr = 0x74; // R828D_I2C_ADDR
const int r828dXtalFreq = 16000000; // R828D_XTAL_FREQ

const int r82xxCheckAddr = 0x00; // R82XX_CHECK_ADDR
const int r82xxCheckVal = 0x69; // R82XX_CHECK_VAL

const int r82xxIfFreq = 3570000; // R82XX_IF_FREQ

const int regShadowStart = 5; // REG_SHADOW_START
const int numRegs = 30; // NUM_REGS
const int numImr = 5; // NUM_IMR
const int imrTrial = 9; // IMR_TRIAL

const int verNum = 49; // VER_NUM

/// enum r82xx_chip
abstract final class R82xxChip {
  static const r820t = 0; // CHIP_R820T
  static const r620d = 1; // CHIP_R620D
  static const r828d = 2; // CHIP_R828D
  static const r828 = 3; // CHIP_R828
  static const r828s = 4; // CHIP_R828S
  static const r820c = 5; // CHIP_R820C
}

/// enum r82xx_tuner_type
abstract final class R82xxTunerType {
  static const radio = 1; // TUNER_RADIO
  static const analogTv = 2; // TUNER_ANALOG_TV
  static const digitalTv = 3; // TUNER_DIGITAL_TV
}

/// enum r82xx_xtal_cap_value
abstract final class R82xxXtalCap {
  static const lowCap30p = 0; // XTAL_LOW_CAP_30P
  static const lowCap20p = 1; // XTAL_LOW_CAP_20P
  static const lowCap10p = 2; // XTAL_LOW_CAP_10P
  static const lowCap0p = 3; // XTAL_LOW_CAP_0P
  static const highCap0p = 4; // XTAL_HIGH_CAP_0P
}

/// enum r82xx_delivery_system
abstract final class R82xxDeliverySystem {
  static const undefined = 0; // SYS_UNDEFINED
  static const dvbt = 1; // SYS_DVBT
  static const dvbt2 = 2; // SYS_DVBT2
  static const isdbt = 3; // SYS_ISDBT
}

/// struct r82xx_config
class R82xxConfig {
  int i2cAddr = 0;
  int xtal = 0;
  int rafaelChip = R82xxChip.r820t;
  int maxI2cMsgLen = 0;
  int usePredetect = 0;
}

/// struct r82xx_freq_range
class R82xxFreqRange {
  final int freq;
  final int openD;
  final int rfMuxPloy;
  final int tfC;
  final int xtalCap20p;
  final int xtalCap10p;
  final int xtalCap0p;
  const R82xxFreqRange(this.freq, this.openD, this.rfMuxPloy, this.tfC,
      this.xtalCap20p, this.xtalCap10p, this.xtalCap0p);
}

// ---- src/tuner_r82xx.c ----

double _mhz(double x) => x * 1000 * 1000; // MHZ(x)

const int _hf = 1; // HF
const int _vhf = 2; // VHF
const int _uhf = 3; // UHF

/// Those initial values start from REG_SHADOW_START
///
/// Note: declared `r82xx_init_array[NUM_REGS]` in C, i.e. 30 bytes: the three
/// trailing (regs 0x20..0x22) are implicit zeros and ARE written by r82xx_init
/// (sizeof == 30). Verified against the C oracle trace.
const List<int> r82xxInitArray = [
  0x83, 0x32, 0x75, // 05 to 07
  0xc0, 0x40, 0xd6, 0x6c, // 08 to 0b
  0xf5, 0x63, 0x75, 0x68, // 0c to 0f
  0x6c, 0x83, 0x80, 0x00, // 10 to 13
  0x0f, 0x00, 0xc0, 0x30, // 14 to 17
  0x48, 0xcc, 0x60, 0x00, // 18 to 1b
  0x54, 0xae, 0x4a, 0xc0, // 1c to 1f
  0x00, 0x00, 0x00, // 20 to 22 (implicit zero padding to NUM_REGS)
];

/// Tuner frequency ranges
/// (freq MHz, open_d, rf_mux_ploy, tf_c, xtal_cap20p, xtal_cap10p, xtal_cap0p)
const List<R82xxFreqRange> freqRanges = [
  // 0: open_d low, R26[7:6]=0 (LPF) R26[1:0]=2 (low), R27 band2,band0, R16 20pF (10)
  R82xxFreqRange(0, 0x08, 0x02, 0xdf, 0x02, 0x01, 0x00),
  // band4,band1
  R82xxFreqRange(50, 0x08, 0x02, 0xbe, 0x02, 0x01, 0x00),
  // band7,band4
  R82xxFreqRange(55, 0x08, 0x02, 0x8b, 0x02, 0x01, 0x00),
  // band8,band4
  R82xxFreqRange(60, 0x08, 0x02, 0x7b, 0x02, 0x01, 0x00),
  // band9,band6
  R82xxFreqRange(65, 0x08, 0x02, 0x69, 0x02, 0x01, 0x00),
  // band10,band7
  R82xxFreqRange(70, 0x08, 0x02, 0x58, 0x02, 0x01, 0x00),
  // open_d high; band11,band11
  R82xxFreqRange(75, 0x00, 0x02, 0x44, 0x02, 0x01, 0x00),
  // band11,band11
  R82xxFreqRange(80, 0x00, 0x02, 0x44, 0x02, 0x01, 0x00),
  // band12,band11; R16 10pF (01)
  R82xxFreqRange(90, 0x00, 0x02, 0x34, 0x01, 0x01, 0x00),
  // band12,band11
  R82xxFreqRange(100, 0x00, 0x02, 0x34, 0x01, 0x01, 0x00),
  // band13,band11
  R82xxFreqRange(110, 0x00, 0x02, 0x24, 0x01, 0x01, 0x00),
  // band13,band11
  R82xxFreqRange(120, 0x00, 0x02, 0x24, 0x01, 0x01, 0x00),
  // band14,band11
  R82xxFreqRange(140, 0x00, 0x02, 0x14, 0x01, 0x01, 0x00),
  // band14,band12; R16 0pF (00)
  R82xxFreqRange(180, 0x00, 0x02, 0x13, 0x00, 0x00, 0x00),
  // band14,band12
  R82xxFreqRange(220, 0x00, 0x02, 0x13, 0x00, 0x00, 0x00),
  // highest,highest
  R82xxFreqRange(250, 0x00, 0x02, 0x11, 0x00, 0x00, 0x00),
  // highest,highest
  R82xxFreqRange(280, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00),
  // R26[7:6]=1 (bypass) R26[1:0]=1 (middle)
  R82xxFreqRange(310, 0x00, 0x41, 0x00, 0x00, 0x00, 0x00),
  // R26[7:6]=1 (bypass) R26[1:0]=1 (middle)
  R82xxFreqRange(450, 0x00, 0x41, 0x00, 0x00, 0x00, 0x00),
  // R26[7:6]=1 (bypass) R26[1:0]=0 (highest)
  R82xxFreqRange(588, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00),
  // R26[7:6]=1 (bypass) R26[1:0]=0 (highest)
  R82xxFreqRange(650, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00),
];

const List<List<int>> r82xxXtalCapacitor = [
  [0x0b, R82xxXtalCap.lowCap30p],
  [0x02, R82xxXtalCap.lowCap20p],
  [0x01, R82xxXtalCap.lowCap10p],
  [0x00, R82xxXtalCap.lowCap0p],
  [0x10, R82xxXtalCap.highCap0p],
];

/// measured with a Racal 6103E GSM test set at 928 MHz with -60 dBm
/// input power, for raw results see:
/// http://steve-m.de/projects/rtl-sdr/gain_measurement/r820t/
const int vgaBaseGain = -47; // VGA_BASE_GAIN
const List<int> r82xxVgaGainSteps = [
  0, 26, 26, 30, 42, 35, 24, 13, 14, 32, 36, 34, 35, 37, 35, 36 //
];

const List<int> r82xxLnaGainSteps = [
  0, 9, 13, 40, 38, 13, 31, 22, 26, 31, 26, 14, 19, 5, 35, 13 //
];

const List<int> r82xxMixerGainSteps = [
  0, 5, 10, 10, 19, 9, 10, 25, 17, 10, 8, 16, 13, 6, 3, -8 //
];

/// Bandwidth contribution by low-pass filter.
const List<int> r82xxIfLowPassBwTable = [
  1700000, 1600000, 1550000, 1450000, 1200000, 900000, 700000, 550000, 450000,
  350000 //
];

const int _filtHpBw1 = 350000; // FILT_HP_BW1
const int _filtHpBw2 = 380000; // FILT_HP_BW2

int _maskReg8(int reg, int val, int mask) =>
    ((reg & ~mask) | (val & mask)) & 0xff;

/// r82xx_bitrev
int r82xxBitrev(int byte) {
  const lut = [
    0x0, 0x8, 0x4, 0xc, 0x2, 0xa, 0x6, 0xe, //
    0x1, 0x9, 0x5, 0xd, 0x3, 0xb, 0x7, 0xf,
  ];
  byte &= 0xff;
  return (lut[byte & 0xf] << 4) | lut[byte >> 4];
}

/// struct r82xx_priv + the functions of tuner_r82xx.c.
class R82xxPriv {
  R82xxConfig cfg;
  final Uint8List regs = Uint8List(numRegs);
  final Uint8List buf = Uint8List(numRegs + 1);
  int xtalCapSel = R82xxXtalCap.lowCap30p;
  int pll = 0; // kHz
  int intFreq = 0;
  int filCalCode = 0;
  int input = 0;
  int hasLock = 0;
  int initDone = 0;

  // Store current mode
  int delsys = 0;
  int type = 0;
  int bw = 0; // in MHz

  RtlSdrI2c rtlDev;

  R82xxPriv(this.cfg, this.rtlDev);

  //
  // I2C read/write code and shadow registers logic
  //
  void _shadowStore(int reg, Uint8List val, int len) {
    int r = reg - regShadowStart;
    int valOff = 0;

    if (r < 0) {
      len += r;
      valOff -= r;
      r = 0;
    }
    if (len <= 0) return;
    if (len > numRegs - r) len = numRegs - r;

    regs.setRange(r, r + len, val, valOff);
  }

  bool _shadowEqual(int reg, Uint8List val, int len) {
    final r = reg - regShadowStart;

    if (r < 0 || len < 0 || len > numRegs - r) return false;

    for (var i = 0; i < len; i++) {
      if (regs[r + i] != val[i]) return false;
    }
    return true;
  }

  int _write(int reg, Uint8List val, int len) {
    int rc, size, pos = 0;

    // Avoid setting registers unnecessarily since it's slow
    if (_shadowEqual(reg, val, len)) return 0;

    // Store the shadow registers
    _shadowStore(reg, val, len);

    do {
      if (len > cfg.maxI2cMsgLen - 1) {
        size = cfg.maxI2cMsgLen - 1;
      } else {
        size = len;
      }

      // Fill I2C buffer
      buf[0] = reg & 0xff;
      buf.setRange(1, 1 + size, val, pos);

      rc = rtlDev.i2cWriteFn(cfg.i2cAddr, buf, size + 1);

      if (rc != size + 1) {
        rtlsdrLog('r82xx_write: i2c wr failed=$rc '
            'reg=${_hex2(reg)} len=$size');
        if (rc < 0) return rc;
        return -1;
      }

      reg = (reg + size) & 0xff;
      len -= size;
      pos += size;
    } while (len > 0);

    return 0;
  }

  int _writeReg(int reg, int val) =>
      _write(reg, Uint8List.fromList([val & 0xff]), 1);

  int _readCacheReg(int reg) {
    reg -= regShadowStart;

    if (reg >= 0 && reg < numRegs) {
      return regs[reg];
    } else {
      return -1;
    }
  }

  int _writeRegMask(int reg, int val, int bitMask) {
    final rc = _readCacheReg(reg);

    if (rc < 0) return rc;

    val = ((rc & ~bitMask) | (val & bitMask)) & 0xff;

    return _write(reg, Uint8List.fromList([val]), 1);
  }

  int _read(int reg, Uint8List val, int len) {
    int rc;
    final p = Uint8List.sublistView(buf, 1);

    buf[0] = reg & 0xff;

    rc = rtlDev.i2cWriteFn(cfg.i2cAddr, buf, 1);

    if (rc != 1) {
      rtlsdrLog('r82xx_read: i2c wr failed=$rc reg=${_hex2(reg)} len=1');
      if (rc < 0) return rc;
      return -1;
    }

    rc = rtlDev.i2cReadFn(cfg.i2cAddr, p, len);

    if (rc != len) {
      rtlsdrLog('r82xx_read: i2c rd failed=$rc reg=${_hex2(reg)} len=$len');
      if (rc < 0) return rc;
      return -1;
    }

    // Copy data to the output buffer
    for (var i = 0; i < len; i++) {
      val[i] = r82xxBitrev(p[i]);
    }

    return 0;
  }

  //
  // r82xx tuning logic
  //

  int _setMux(int freq) {
    R82xxFreqRange range;
    int rc;
    int i;
    int val;

    // Get the proper frequency range
    freq = freq ~/ 1000000;
    for (i = 0; i < freqRanges.length - 1; i++) {
      if (freq < freqRanges[i + 1].freq) break;
    }
    range = freqRanges[i];

    // Open Drain
    rc = _writeRegMask(0x17, range.openD, 0x08);
    if (rc < 0) return rc;

    // RF_MUX,Polymux
    rc = _writeRegMask(0x1a, range.rfMuxPloy, 0xc3);
    if (rc < 0) return rc;

    // TF BAND
    rc = _writeReg(0x1b, range.tfC);
    if (rc < 0) return rc;

    // XTAL CAP & Drive
    switch (xtalCapSel) {
      case R82xxXtalCap.lowCap30p:
      case R82xxXtalCap.lowCap20p:
        val = range.xtalCap20p | 0x08;
      case R82xxXtalCap.lowCap10p:
        val = range.xtalCap10p | 0x08;
      case R82xxXtalCap.highCap0p:
        val = range.xtalCap0p | 0x00;
      case R82xxXtalCap.lowCap0p:
      default:
        val = range.xtalCap0p | 0x08;
    }
    rc = _writeRegMask(0x10, val, 0x0b);
    if (rc < 0) return rc;

    rc = _writeRegMask(0x08, 0x00, 0x3f);
    if (rc < 0) return rc;

    rc = _writeRegMask(0x09, 0x00, 0x3f);

    return rc;
  }

  int _setPll(int freq) {
    int rc, i;
    // unsigned sleep_time = 10000;
    int vcoFreq;
    int vcoDiv;
    const int vcoMin = 1770000; // kHz
    const int vcoMax = vcoMin * 2; // kHz
    int freqKhz, pllRef;
    int sdm = 0;
    int mixDiv = 2;
    int divBuf = 0;
    int divNum = 0;
    int vcoPowerRef = 2;
    const int refdiv2 = 0;
    int ni, si, nint, vcoFineTune, val;
    final data = Uint8List(5);
    final regs = Uint8List(7);

    // Frequency in kHz
    freqKhz = ((freq + 500) & 0xffffffff) ~/ 1000;
    pllRef = cfg.xtal;

    // set pll autotune = 128kHz
    rc = _writeRegMask(0x1a, 0x00, 0x0c);
    if (rc < 0) return rc;

    // regs 0x10 to 0x16
    regs.setRange(0, 7, this.regs, 0x10 - regShadowStart);

    regs[0] = _maskReg8(regs[0], refdiv2, 0x10);

    // set VCO current = 100
    regs[2] = _maskReg8(regs[2], 0x80, 0xe0);

    // Calculate divider
    while (mixDiv <= 64) {
      if (((freqKhz * mixDiv) >= vcoMin) && ((freqKhz * mixDiv) < vcoMax)) {
        divBuf = mixDiv;
        while (divBuf > 2) {
          divBuf = divBuf >> 1;
          divNum++;
        }
        break;
      }
      mixDiv = (mixDiv << 1) & 0xff;
    }

    rc = _read(0x00, data, data.length);
    if (rc < 0) return rc;

    if (cfg.rafaelChip == R82xxChip.r828d ||
        rtlDev.checkDongleModel('RTLSDRBlog', 'Blog V4L')) {
      vcoPowerRef = 1;
    }

    vcoFineTune = (data[4] & 0x30) >> 4;

    if (vcoFineTune > vcoPowerRef) {
      divNum = (divNum - 1) & 0xff;
    } else if (vcoFineTune < vcoPowerRef) {
      divNum = (divNum + 1) & 0xff;
    }

    regs[0] = _maskReg8(regs[0], (divNum << 5) & 0xff, 0xe0);

    vcoFreq = freq * mixDiv;

    // We want to approximate:
    //  vco_freq / (2 * pll_ref)
    //
    // in the form:
    //  nint + sdm/65536
    //
    // where nint,sdm are integers and 0 < nint, 0 <= sdm < 65536
    //
    // Scaling to fixed point and rounding:
    //
    //  vco_div = 65536*(nint + sdm/65536) = int( 0.5 + 65536 * vco_freq / (2 * pll_ref) )
    //  vco_div = 65536*nint + sdm         = int( (pll_ref + 65536 * vco_freq) / (2 * pll_ref) )

    vcoDiv = (pllRef + 65536 * vcoFreq) ~/ (2 * pllRef);
    nint = (vcoDiv ~/ 65536) & 0xff; // uint8_t nint = (uint32_t)(...)
    sdm = (vcoDiv % 65536) & 0xffffffff;

    if (nint > ((128 ~/ vcoPowerRef) - 1)) {
      rtlsdrLog('[R82XX] No valid PLL values for $freq Hz!');
      return -1;
    }

    ni = ((nint - 13) ~/ 4) & 0xff;
    si = (nint - 4 * ni - 13) & 0xff;

    regs[4] = (ni + (si << 6)) & 0xff;

    // pw_sdm
    if (sdm == 0) {
      val = 0x08;
    } else {
      val = 0x00;
    }

    regs[2] = _maskReg8(regs[2], val, 0x08);

    regs[5] = sdm & 0xff;
    regs[6] = (sdm >> 8) & 0xff;

    rc = _write(0x10, regs, 7);
    if (rc < 0) return rc;

    for (i = 0; i < 2; i++) {
      // usleep_range(sleep_time, sleep_time + 1000);

      // Check if PLL has locked
      rc = _read(0x00, data, 3);
      if (rc < 0) return rc;
      if (data[2] & 0x40 != 0) break;

      if (i == 0) {
        // Didn't lock. Increase VCO current
        rc = _writeRegMask(0x12, 0x60, 0xe0);
        if (rc < 0) return rc;
      }
    }

    if (data[2] & 0x40 == 0) {
      rtlsdrLog('[R82XX] PLL not locked!');
      hasLock = 0;
      return 0;
    }

    hasLock = 1;

    // set pll autotune = 8kHz
    rc = _writeRegMask(0x1a, 0x08, 0x08);

    return rc;
  }

  int _sysfreqSel(int freq, int type, int delsys) {
    int rc;
    int mixerTop, lnaTop, cpCur, divBufCur, lnaVthL, mixerVthL;
    int airCable1In, cable2In, preDect, lnaDischarge, filterCur;

    switch (delsys) {
      case R82xxDeliverySystem.dvbt:
        if ((freq == 506000000) || (freq == 666000000) || (freq == 818000000)) {
          mixerTop = 0x14; // mixer top:14 , top-1, low-discharge
          lnaTop = 0xe5; // detect bw 3, lna top:4, predet top:2
          cpCur = 0x28; // 101, 0.2
          divBufCur = 0x20; // 10, 200u
        } else {
          mixerTop = 0x24; // mixer top:13 , top-1, low-discharge
          lnaTop = 0xe5; // detect bw 3, lna top:4, predet top:2
          cpCur = 0x38; // 111, auto
          divBufCur = 0x30; // 11, 150u
        }
        lnaVthL = 0x53; // lna vth 0.84	,  vtl 0.64
        mixerVthL = 0x75; // mixer vth 1.04, vtl 0.84
        airCable1In = 0x00;
        cable2In = 0x00;
        preDect = 0x40;
        lnaDischarge = 14;
        filterCur = 0x40; // 10, low
      case R82xxDeliverySystem.dvbt2:
        mixerTop = 0x24; // mixer top:13 , top-1, low-discharge
        lnaTop = 0xe5; // detect bw 3, lna top:4, predet top:2
        lnaVthL = 0x53; // lna vth 0.84	,  vtl 0.64
        mixerVthL = 0x75; // mixer vth 1.04, vtl 0.84
        airCable1In = 0x00;
        cable2In = 0x00;
        preDect = 0x40;
        lnaDischarge = 14;
        cpCur = 0x38; // 111, auto
        divBufCur = 0x30; // 11, 150u
        filterCur = 0x40; // 10, low
      case R82xxDeliverySystem.isdbt:
        mixerTop = 0x24; // mixer top:13 , top-1, low-discharge
        lnaTop = 0xe5; // detect bw 3, lna top:4, predet top:2
        lnaVthL = 0x75; // lna vth 1.04	,  vtl 0.84
        mixerVthL = 0x75; // mixer vth 1.04, vtl 0.84
        airCable1In = 0x00;
        cable2In = 0x00;
        preDect = 0x40;
        lnaDischarge = 14;
        cpCur = 0x38; // 111, auto
        divBufCur = 0x30; // 11, 150u
        filterCur = 0x40; // 10, low
      default: // DVB-T 8M
        mixerTop = 0x24; // mixer top:13 , top-1, low-discharge
        lnaTop = 0xe5; // detect bw 3, lna top:4, predet top:2
        lnaVthL = 0x53; // lna vth 0.84	,  vtl 0.64
        mixerVthL = 0x75; // mixer vth 1.04, vtl 0.84
        airCable1In = 0x00;
        cable2In = 0x00;
        preDect = 0x40;
        lnaDischarge = 14;
        cpCur = 0x38; // 111, auto
        divBufCur = 0x30; // 11, 150u
        filterCur = 0x40; // 10, low
    }

    if (cfg.usePredetect != 0) {
      rc = _writeRegMask(0x06, preDect, 0x40);
      if (rc < 0) return rc;
    }

    rc = _writeRegMask(0x1d, lnaTop, 0xc7);
    if (rc < 0) return rc;
    rc = _writeRegMask(0x1c, mixerTop, 0xf8);
    if (rc < 0) return rc;
    rc = _writeReg(0x0d, lnaVthL);
    if (rc < 0) return rc;
    rc = _writeReg(0x0e, mixerVthL);
    if (rc < 0) return rc;

    input = airCable1In;

    // Air-IN only for Astrometa
    rc = _writeRegMask(0x05, airCable1In, 0x60);
    if (rc < 0) return rc;
    rc = _writeRegMask(0x06, cable2In, 0x08);
    if (rc < 0) return rc;

    rc = _writeRegMask(0x11, cpCur, 0x38);
    if (rc < 0) return rc;
    rc = _writeRegMask(0x17, divBufCur, 0x30);
    if (rc < 0) return rc;
    rc = _writeRegMask(0x0a, filterCur, 0x60);
    if (rc < 0) return rc;

    //
    // Set LNA
    //

    if (type != R82xxTunerType.analogTv) {
      // LNA TOP: lowest
      rc = _writeRegMask(0x1d, 0, 0x38);
      if (rc < 0) return rc;

      // 0: normal mode
      rc = _writeRegMask(0x1c, 0, 0x04);
      if (rc < 0) return rc;

      // 0: PRE_DECT off
      rc = _writeRegMask(0x06, 0, 0x40);
      if (rc < 0) return rc;

      // agc clk 250hz
      rc = _writeRegMask(0x1a, 0x30, 0x30);
      if (rc < 0) return rc;

      // msleep(250);

      // write LNA TOP = 3
      rc = _writeRegMask(0x1d, 0x18, 0x38);
      if (rc < 0) return rc;

      // write discharge mode
      // FIXME: IMHO, the mask here is wrong, but it matches
      // what's there at the original driver
      rc = _writeRegMask(0x1c, mixerTop, 0x04);
      if (rc < 0) return rc;

      // LNA discharge current
      rc = _writeRegMask(0x1e, lnaDischarge, 0x1f);
      if (rc < 0) return rc;

      // agc clk 60hz
      rc = _writeRegMask(0x1a, 0x20, 0x30);
      if (rc < 0) return rc;
    } else {
      // PRE_DECT off
      rc = _writeRegMask(0x06, 0, 0x40);
      if (rc < 0) return rc;

      // write LNA TOP
      rc = _writeRegMask(0x1d, lnaTop, 0x38);
      if (rc < 0) return rc;

      // write discharge mode
      // FIXME: IMHO, the mask here is wrong, but it matches
      // what's there at the original driver
      rc = _writeRegMask(0x1c, mixerTop, 0x04);
      if (rc < 0) return rc;

      // LNA discharge current
      rc = _writeRegMask(0x1e, lnaDischarge, 0x1f);
      if (rc < 0) return rc;

      // agc clk 1Khz, external det1 cap 1u
      rc = _writeRegMask(0x1a, 0x00, 0x30);
      if (rc < 0) return rc;

      rc = _writeRegMask(0x10, 0x00, 0x04);
      if (rc < 0) return rc;
    }
    return 0;
  }

  int _setTvStandard(int bw, int type, int delsys) {
    int rc, i;
    int ifKhz, filtCalLo;
    final data = Uint8List(5);
    int filtGain, imgR, filtQ, hpCor, extEnable, loopThrough;
    int ltAtt, fltExtWidest, polyfilCur;
    int needCalibration;

    // BW < 6 MHz
    ifKhz = 3570;
    filtCalLo = 56000; // 52000->56000
    filtGain = 0x10; // +3db, 6mhz on
    imgR = 0x00; // image negative
    filtQ = 0x10; // r10[4]:low q(1'b1)
    hpCor = 0x6b; // 1.7m disable, +2cap, 1.0mhz
    extEnable = 0x60; // r30[6]=1 ext enable; r30[5]:1 ext at lna max-1
    loopThrough = 0x01; // r5[7], lt off
    ltAtt = 0x00; // r31[7], lt att enable
    fltExtWidest = 0x00; // r15[7]: flt_ext_wide off
    polyfilCur = 0x60; // r25[6:5]:min

    // Initialize the shadow registers
    regs.setRange(0, r82xxInitArray.length, r82xxInitArray);

    // Init Flag & Xtal_check Result (inits VGA gain, needed?)
    rc = _writeRegMask(0x0c, 0x00, 0x0f);
    if (rc < 0) return rc;

    // version
    rc = _writeRegMask(0x13, verNum, 0x3f);
    if (rc < 0) return rc;

    // for LT Gain test
    if (type != R82xxTunerType.analogTv) {
      rc = _writeRegMask(0x1d, 0x00, 0x38);
      if (rc < 0) return rc;
      // usleep_range(1000, 2000);
    }
    intFreq = ifKhz * 1000;

    // Check if standard changed. If so, filter calibration is needed
    // as we call this function only once in rtlsdr, force calibration
    needCalibration = 1;

    if (needCalibration != 0) {
      for (i = 0; i < 2; i++) {
        // Set filt_cap
        rc = _writeRegMask(0x0b, hpCor, 0x60);
        if (rc < 0) return rc;

        // set cali clk =on
        rc = _writeRegMask(0x0f, 0x04, 0x04);
        if (rc < 0) return rc;

        // X'tal cap 0pF for PLL
        rc = _writeRegMask(0x10, 0x00, 0x03);
        if (rc < 0) return rc;

        rc = _setPll(filtCalLo * 1000);
        if (rc < 0 || hasLock == 0) return rc;

        // Start Trigger
        rc = _writeRegMask(0x0b, 0x10, 0x10);
        if (rc < 0) return rc;

        // usleep_range(1000, 2000);

        // Stop Trigger
        rc = _writeRegMask(0x0b, 0x00, 0x10);
        if (rc < 0) return rc;

        // set cali clk =off
        rc = _writeRegMask(0x0f, 0x00, 0x04);
        if (rc < 0) return rc;

        // Check if calibration worked
        rc = _read(0x00, data, data.length);
        if (rc < 0) return rc;

        filCalCode = data[4] & 0x0f;
        if (filCalCode != 0 && filCalCode != 0x0f) break;
      }
      // narrowest
      if (filCalCode == 0x0f) filCalCode = 0;
    }

    rc = _writeRegMask(0x0a, filtQ | filCalCode, 0x1f);
    if (rc < 0) return rc;

    // Set BW, Filter_gain, & HP corner
    rc = _writeRegMask(0x0b, hpCor, 0xef);
    if (rc < 0) return rc;

    // Set Img_R
    rc = _writeRegMask(0x07, imgR, 0x80);
    if (rc < 0) return rc;

    // Set filt_3dB, V6MHz
    rc = _writeRegMask(0x06, filtGain, 0x30);
    if (rc < 0) return rc;

    // channel filter extension
    rc = _writeRegMask(0x1e, extEnable, 0x60);
    if (rc < 0) return rc;

    // Loop through
    rc = _writeRegMask(0x05, loopThrough, 0x80);
    if (rc < 0) return rc;

    // Loop through attenuation
    rc = _writeRegMask(0x1f, ltAtt, 0x80);
    if (rc < 0) return rc;

    // filter extension widest
    rc = _writeRegMask(0x0f, fltExtWidest, 0x80);
    if (rc < 0) return rc;

    // RF poly filter current
    rc = _writeRegMask(0x19, polyfilCur, 0x60);
    if (rc < 0) return rc;

    // Store current standard. If it changes, re-calibrate the tuner
    this.delsys = delsys;
    this.type = type;
    this.bw = bw;

    return 0;
  }

  /// r82xx_read_gain (static, unused by librtlsdr; kept for completeness)
  int r82xxReadGain() {
    final data = Uint8List(4);
    int rc;

    rc = _read(0x00, data, data.length);
    if (rc < 0) return rc;

    return ((data[3] & 0x0f) << 1) + ((data[3] & 0xf0) >> 4);
  }

  /// r82xx_set_gain
  int r82xxSetGain(int setManualGain, int gain) {
    int rc;

    if (setManualGain != 0) {
      int i, totalGain = 0;
      int mixIndex = 0, lnaIndex = 0;
      final data = Uint8List(4);

      // LNA auto off
      rc = _writeRegMask(0x05, 0x10, 0x10);
      if (rc < 0) return rc;

      // Mixer auto off
      rc = _writeRegMask(0x07, 0, 0x10);
      if (rc < 0) return rc;

      rc = _read(0x00, data, data.length);
      if (rc < 0) return rc;

      // set fixed VGA gain for now (16.3 dB)
      rc = _writeRegMask(0x0c, 0x08, 0x9f);
      if (rc < 0) return rc;

      for (i = 0; i < 15; i++) {
        if (totalGain >= gain) break;

        totalGain += r82xxLnaGainSteps[++lnaIndex];

        if (totalGain >= gain) break;

        totalGain += r82xxMixerGainSteps[++mixIndex];
      }

      // set LNA gain
      rc = _writeRegMask(0x05, lnaIndex, 0x0f);
      if (rc < 0) return rc;

      // set Mixer gain
      rc = _writeRegMask(0x07, mixIndex, 0x0f);
      if (rc < 0) return rc;
    } else {
      // LNA
      rc = _writeRegMask(0x05, 0, 0x10);
      if (rc < 0) return rc;

      // Mixer
      rc = _writeRegMask(0x07, 0x10, 0x10);
      if (rc < 0) return rc;

      // set fixed VGA gain for now (26.5 dB)
      rc = _writeRegMask(0x0c, 0x0b, 0x9f);
      if (rc < 0) return rc;
    }

    return 0;
  }

  /// r82xx_set_bandwidth: returns the new IF frequency (Hz) or a negative error.
  int r82xxSetBandwidth(int bw, int rate) {
    int rc;
    int i;
    int realBw = 0;
    int reg0a;
    int reg0b;

    if (bw > 7000000) {
      // BW: 8 MHz
      reg0a = 0x10;
      reg0b = 0x0b;
      intFreq = 4570000;
    } else if (bw > 6000000) {
      // BW: 7 MHz
      reg0a = 0x10;
      reg0b = 0x2a;
      intFreq = 4570000;
    } else if (bw > r82xxIfLowPassBwTable[0] + _filtHpBw1 + _filtHpBw2) {
      // BW: 6 MHz
      reg0a = 0x10;
      reg0b = 0x6b;
      intFreq = 3570000;
    } else {
      reg0a = 0x00;
      reg0b = 0x80;
      intFreq = 2300000;

      if (bw > r82xxIfLowPassBwTable[0] + _filtHpBw1) {
        bw -= _filtHpBw2;
        intFreq += _filtHpBw2;
        realBw += _filtHpBw2;
      } else {
        reg0b |= 0x20;
      }

      if (bw > r82xxIfLowPassBwTable[0]) {
        bw -= _filtHpBw1;
        intFreq += _filtHpBw1;
        realBw += _filtHpBw1;
      } else {
        reg0b |= 0x40;
      }

      // find low-pass filter
      for (i = 0; i < r82xxIfLowPassBwTable.length; ++i) {
        if (bw > r82xxIfLowPassBwTable[i]) break;
      }
      --i;
      reg0b |= 15 - i;
      reg0b &= 0xff;
      realBw += r82xxIfLowPassBwTable[i];

      intFreq -= realBw ~/ 2;
    }

    rc = _writeRegMask(0x0a, reg0a, 0x10);
    if (rc < 0) return rc;

    rc = _writeRegMask(0x0b, reg0b, 0xef);
    if (rc < 0) return rc;

    return intFreq;
  }

  /// r82xx_set_freq (incl. RTL-SDR Blog V4 / V4L input switching)
  int r82xxSetFreq(int freq) {
    int rc = -1;
    bool isRtlsdrBlogV4;
    bool isRtlsdrBlogV4l;
    int upconvertFreq;
    int loFreq;
    int airCable1In;
    int openD;
    int band;
    int cable2In;
    int cable1In;
    int airIn;

    isRtlsdrBlogV4 = rtlDev.checkDongleModel('RTLSDRBlog', 'Blog V4');
    isRtlsdrBlogV4l = rtlDev.checkDongleModel('RTLSDRBlog', 'Blog V4L');

    // if it's an RTL-SDR Blog V4, automatically upconvert by 28.8 MHz if we tune to HF
    // so that we don't need to manually set any upconvert offset in the SDR software
    upconvertFreq = (isRtlsdrBlogV4 || isRtlsdrBlogV4l)
        ? ((freq < _mhz(28.8)) ? (freq + _mhz(28.8)).toInt() : freq)
        : freq;
    upconvertFreq &= 0xffffffff;

    loFreq = (upconvertFreq + intFreq) & 0xffffffff;

    // C: goto err
    int err(int rc) {
      if (rc < 0) rtlsdrLog('r82xx_set_freq: failed=$rc');
      return rc;
    }

    rc = _setMux(loFreq);
    if (rc < 0) return err(rc);

    rc = _setPll(loFreq);
    if (rc < 0 || hasLock == 0) return err(rc);

    if (isRtlsdrBlogV4) {
      // determine if notch filters should be on or off notches are turned OFF
      // when tuned within the notch band and ON when tuned outside the notch band.
      openD = (freq <= _mhz(2.2) ||
              (freq >= _mhz(85) && freq <= _mhz(112)) ||
              (freq >= _mhz(172) && freq <= _mhz(242)))
          ? 0x00
          : 0x08;
      rc = _writeRegMask(0x17, openD, 0x08);

      if (rc < 0) return rc;

      // select tuner band based on frequency and only switch if there is a band change
      // (to avoid excessive register writes when tuning rapidly)
      band = (freq <= _mhz(28.8))
          ? _hf
          : ((freq > _mhz(28.8) && freq < _mhz(250)) ? _vhf : _uhf);

      // bypass tracking filter for HF to reduce insertion loss,
      // the upconverter path doesn't benefit from it.
      // Must be outside band-change guard since r82xx_set_mux
      // re-applies the tracking filter on every frequency change.
      if (band == _hf) {
        rc = _writeRegMask(0x1a, 0x40, 0xc3);
        if (rc < 0) return err(rc);
        rc = _writeReg(0x1b, 0x00);
        if (rc < 0) return err(rc);
      }

      // switch between tuner inputs on the RTL-SDR Blog V4
      if (band != input) {
        input = band;

        // activate cable 2 (HF input)
        cable2In = (band == _hf) ? 0x08 : 0x00;
        rc = _writeRegMask(0x06, cable2In, 0x08);

        if (rc < 0) return err(rc);

        // Control upconverter GPIO switch on newer batches
        rc = rtlDev.setBiasTeeGpio(5, cable2In == 0 ? 1 : 0);

        if (rc < 0) return err(rc);

        // activate cable 1 (VHF input)
        cable1In = (band == _vhf) ? 0x40 : 0x00;
        rc = _writeRegMask(0x05, cable1In, 0x40);

        if (rc < 0) return err(rc);

        // activate air_in (UHF input)
        airIn = (band == _uhf) ? 0x00 : 0x20;
        rc = _writeRegMask(0x05, airIn, 0x20);

        if (rc < 0) return err(rc);
      }
    } else if (isRtlsdrBlogV4l) {
      // select tuner band based on frequency and only switch if there is a band change
      // (to avoid excessive register writes when tuning rapidly)
      band = (freq <= _mhz(28.8)) ? _hf : _uhf;

      // bypass tracking filter for HF to reduce insertion loss,
      // the upconverter path doesn't benefit from it.
      // Must be outside band-change guard since r82xx_set_mux
      // re-applies the tracking filter on every frequency change.
      if (band == _hf) {
        rc = _writeRegMask(0x1a, 0x40, 0xc3);
        if (rc < 0) return err(rc);
        rc = _writeReg(0x1b, 0x00);
        if (rc < 0) return err(rc);
      }

      // switch between tuner inputs on the RTL-SDR Blog V4L
      if (band != input) {
        input = band;

        cable1In = (band == _hf) ? 0x40 : 0x00;

        // Control upconverter GPIO switch on newer batches
        rc = rtlDev.setBiasTeeGpio(5, cable1In == 0 ? 1 : 0);

        if (rc < 0) return err(rc);

        // activate cable 1 (HF input)
        rc = _writeRegMask(0x05, cable1In, 0x40);

        if (rc < 0) return err(rc);

        // activate air_in (UHF input)
        airIn = (band == _uhf) ? 0x00 : 0x20;
        rc = _writeRegMask(0x05, airIn, 0x20);

        if (rc < 0) return err(rc);
      }
    } else {
      // Standard R828D dongle
      // switch between 'Cable1' and 'Air-In' inputs on sticks with
      // R828D tuner. We switch at 345 MHz, because that's where the
      // noise-floor has about the same level with identical LNA
      // settings. The original driver used 320 MHz.
      airCable1In = (freq > _mhz(345)) ? 0x00 : 0x60;

      if ((cfg.rafaelChip == R82xxChip.r828d) && (airCable1In != input)) {
        input = airCable1In;
        rc = _writeRegMask(0x05, airCable1In, 0x60);
      }
    }

    return err(rc);
  }

  //
  // r82xx standby logic
  //

  /// r82xx_standby
  int r82xxStandby() {
    int rc;

    // If device was not initialized yet, don't need to standby
    if (initDone == 0) return 0;

    rc = _writeReg(0x06, 0xb1);
    if (rc < 0) return rc;
    rc = _writeReg(0x05, 0xa0);
    if (rc < 0) return rc;
    rc = _writeReg(0x07, 0x3a);
    if (rc < 0) return rc;
    rc = _writeReg(0x08, 0x40);
    if (rc < 0) return rc;
    rc = _writeReg(0x09, 0xc0);
    if (rc < 0) return rc;
    rc = _writeReg(0x0a, 0x36);
    if (rc < 0) return rc;
    rc = _writeReg(0x0c, 0x35);
    if (rc < 0) return rc;
    rc = _writeReg(0x0f, 0x68);
    if (rc < 0) return rc;
    rc = _writeReg(0x11, 0x03);
    if (rc < 0) return rc;
    rc = _writeReg(0x17, 0xf4);
    if (rc < 0) return rc;
    rc = _writeReg(0x19, 0x0c);

    // Force initial calibration
    type = -1;

    return rc;
  }

  //
  // r82xx device init logic
  //

  /// r82xx_xtal_check (static and unused in librtlsdr; kept for completeness)
  int r82xxXtalCheck() {
    int rc;
    int i;
    final data = Uint8List(3);
    int val;

    // Initialize the shadow registers
    regs.setRange(0, r82xxInitArray.length, r82xxInitArray);

    // cap 30pF & Drive Low
    rc = _writeRegMask(0x10, 0x0b, 0x0b);
    if (rc < 0) return rc;

    // set pll autotune = 128kHz
    rc = _writeRegMask(0x1a, 0x00, 0x0c);
    if (rc < 0) return rc;

    // set manual initial reg = 111111;
    rc = _writeRegMask(0x13, 0x7f, 0x7f);
    if (rc < 0) return rc;

    // set auto
    rc = _writeRegMask(0x13, 0x00, 0x40);
    if (rc < 0) return rc;

    // Try several xtal capacitor alternatives
    for (i = 0; i < r82xxXtalCapacitor.length; i++) {
      rc = _writeRegMask(0x10, r82xxXtalCapacitor[i][0], 0x1b);
      if (rc < 0) return rc;

      // usleep_range(5000, 6000);

      rc = _read(0x00, data, data.length);
      if (rc < 0) return rc;
      if (data[2] & 0x40 == 0) continue;

      val = data[2] & 0x3f;

      if (cfg.xtal == 16000000 && (val > 29 || val < 23)) break;

      if (val != 0x3f) break;
    }

    if (i == r82xxXtalCapacitor.length) return -1;

    return r82xxXtalCapacitor[i][1];
  }

  /// r82xx_init
  int r82xxInit() {
    int rc;

    // TODO: R828D might need r82xx_xtal_check()
    xtalCapSel = R82xxXtalCap.highCap0p;

    // Initialize registers
    regs.fillRange(0, numRegs, 0);
    rc = _write(0x05, Uint8List.fromList(r82xxInitArray), r82xxInitArray.length);

    rc = _setTvStandard(3, R82xxTunerType.digitalTv, 0);
    if (rc >= 0) {
      rc = _sysfreqSel(0, R82xxTunerType.digitalTv, R82xxDeliverySystem.dvbt);

      initDone = 1;
    }

    // err:
    if (rc < 0) rtlsdrLog('r82xx_init: failed=$rc');
    return rc;
  }

  // #if 0 r82xx_gpio(): not used, not ported.
}

String _hex2(int v) => (v & 0xff).toRadixString(16).padLeft(2, '0');

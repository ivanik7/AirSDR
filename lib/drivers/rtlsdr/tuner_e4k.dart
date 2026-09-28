// Dart port of the Elonics E4000 tuner driver.
//
// Source: ~/prj/ref/rtl-sdr/src/tuner_e4k.c (osmocom rtl-sdr v2.0.3, 1000
// lines) and include/tuner_e4k.h, include/reg_field.h (struct reg_field).
//
// Elonics E4000 tuner driver
//
// (C) 2011-2012 by Harald Welte <laforge@gnumonks.org>
// (C) 2012 by Sylvain Munaut <tnt@246tNt.com>
// (C) 2012 by Hoernchen <la@tfc-server.de>
//
// All Rights Reserved
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version. (Distributed in this app under GPL-3.0.)
//
// Porting notes:
//  * C integer types are reproduced with explicit masks: uint8_t (& 0xff),
//    int8_t (toSigned(8)), uint16_t (& 0xffff), uint32_t (& 0xffffffff).
//    e4k_reg_set_mask() truncates a failed read (-1) to 0xff exactly like the
//    C `uint8_t tmp = e4k_reg_read(...)`.
//  * e4k_tune_freq() keeps the C `uint32_t rc` quirk: a failed SYNTH1 read
//    (-1 -> 0xffffffff) is treated as "PLL locked".
//  * Code under `#if 0` in the C source is not ported (kept as comments).
//  * fprintf(stderr) -> rtlsdrLog.

import 'dart:typed_data';

import 'rtl_sdr.dart' show rtlsdrLog;
import 'rtlsdr_i2c.dart';

// ---- include/tuner_e4k.h ----

const int e4kI2cAddr = 0xc8; // E4K_I2C_ADDR
const int e4kCheckAddr = 0x02; // E4K_CHECK_ADDR
const int e4kCheckVal = 0x40; // E4K_CHECK_VAL

/// enum e4k_reg
abstract final class E4kReg {
  static const master1 = 0x00;
  static const master2 = 0x01;
  static const master3 = 0x02;
  static const master4 = 0x03;
  static const master5 = 0x04;
  static const clkInp = 0x05;
  static const refClk = 0x06;
  static const synth1 = 0x07;
  static const synth2 = 0x08;
  static const synth3 = 0x09;
  static const synth4 = 0x0a;
  static const synth5 = 0x0b;
  static const synth6 = 0x0c;
  static const synth7 = 0x0d;
  static const synth8 = 0x0e;
  static const synth9 = 0x0f;
  static const filt1 = 0x10;
  static const filt2 = 0x11;
  static const filt3 = 0x12;
  // gap
  static const gain1 = 0x14;
  static const gain2 = 0x15;
  static const gain3 = 0x16;
  static const gain4 = 0x17;
  // gap
  static const agc1 = 0x1a;
  static const agc2 = 0x1b;
  static const agc3 = 0x1c;
  static const agc4 = 0x1d;
  static const agc5 = 0x1e;
  static const agc6 = 0x1f;
  static const agc7 = 0x20;
  static const agc8 = 0x21;
  // gap
  static const agc11 = 0x24;
  static const agc12 = 0x25;
  // gap
  static const dc1 = 0x29;
  static const dc2 = 0x2a;
  static const dc3 = 0x2b;
  static const dc4 = 0x2c;
  static const dc5 = 0x2d;
  static const dc6 = 0x2e;
  static const dc7 = 0x2f;
  static const dc8 = 0x30;
  // gap
  static const qlut0 = 0x50;
  static const qlut1 = 0x51;
  static const qlut2 = 0x52;
  static const qlut3 = 0x53;
  // gap
  static const ilut0 = 0x60;
  static const ilut1 = 0x61;
  static const ilut2 = 0x62;
  static const ilut3 = 0x63;
  // gap
  static const dctime1 = 0x70;
  static const dctime2 = 0x71;
  static const dctime3 = 0x72;
  static const dctime4 = 0x73;
  static const pwm1 = 0x74;
  static const pwm2 = 0x75;
  static const pwm3 = 0x76;
  static const pwm4 = 0x77;
  static const bias = 0x78;
  static const clkoutPwdn = 0x7a;
  static const chfiltCalib = 0x7b;
  static const i2cRegAddr = 0x7d;
}

const int e4kMaster1Reset = 1 << 0; // E4K_MASTER1_RESET
const int e4kMaster1NormStby = 1 << 1; // E4K_MASTER1_NORM_STBY
const int e4kMaster1PorDet = 1 << 2; // E4K_MASTER1_POR_DET

const int e4kSynth1PllLock = 1 << 0; // E4K_SYNTH1_PLL_LOCK
const int e4kSynth1BandShif = 1; // E4K_SYNTH1_BAND_SHIF

const int e4kSynth7ThreephaseEn = 1 << 3; // E4K_SYNTH7_3PHASE_EN

const int e4kSynth8VcocalUpd = 1 << 2; // E4K_SYNTH8_VCOCAL_UPD

const int e4kFilt3Disable = 1 << 5; // E4K_FILT3_DISABLE

const int e4kAgc1LinMode = 1 << 4; // E4K_AGC1_LIN_MODE
const int e4kAgc1LnaUpdate = 1 << 5; // E4K_AGC1_LNA_UPDATE
const int e4kAgc1LnaGLow = 1 << 6; // E4K_AGC1_LNA_G_LOW
const int e4kAgc1LnaGHigh = 1 << 7; // E4K_AGC1_LNA_G_HIGH

const int e4kAgc6LnaCalReq = 1 << 4; // E4K_AGC6_LNA_CAL_REQ

const int e4kAgc7MixGainAuto = 1 << 0; // E4K_AGC7_MIX_GAIN_AUTO
const int e4kAgc7GainStep5dB = 1 << 5; // E4K_AGC7_GAIN_STEP_5dB

const int e4kAgc8SensLinAuto = 1 << 0; // E4K_AGC8_SENS_LIN_AUTO

const int e4kAgc11LnaGainEnh = 1 << 0; // E4K_AGC11_LNA_GAIN_ENH

const int e4kDc1CalReq = 1 << 0; // E4K_DC1_CAL_REQ

const int e4kDc5ILutEn = 1 << 0; // E4K_DC5_I_LUT_EN
const int e4kDc5QLutEn = 1 << 1; // E4K_DC5_Q_LUT_EN
const int e4kDc5RangeDetEn = 1 << 2; // E4K_DC5_RANGE_DET_EN
const int e4kDc5RangeEn = 1 << 3; // E4K_DC5_RANGE_EN
const int e4kDc5TimevarEn = 1 << 4; // E4K_DC5_TIMEVAR_EN

const int e4kClkoutDisable = 0x96; // E4K_CLKOUT_DISABLE

const int e4kChfcalibCmd = 1 << 0; // E4K_CHFCALIB_CMD

const int e4kAgc1ModMask = 0xF; // E4K_AGC1_MOD_MASK

/// enum e4k_agc_mode
abstract final class E4kAgcMode {
  static const serial = 0x0;
  static const ifPwmLnaSerial = 0x1;
  static const ifPwmLnaAutonl = 0x2;
  static const ifPwmLnaSuperv = 0x3;
  static const ifSerialLnaPwm = 0x4;
  static const ifPwmLnaPwm = 0x5;
  static const ifDigLnaSerial = 0x6;
  static const ifDigLnaAuton = 0x7;
  static const ifDigLnaSuperv = 0x8;
  static const ifSerialLnaAuton = 0x9;
  static const ifSerialLnaSuperv = 0xa;
}

/// enum e4k_band
abstract final class E4kBand {
  static const vhf2 = 0;
  static const vhf3 = 1;
  static const uhf = 2;
  static const l = 3;
}

/// enum e4k_mixer_filter_bw
abstract final class E4kMixBw {
  static const bw27M = 0;
  static const bw4M6 = 8;
  static const bw4M2 = 9;
  static const bw3M8 = 10;
  static const bw3M4 = 11;
  static const bw3M = 12;
  static const bw2M7 = 13;
  static const bw2M3 = 14;
  static const bw1M9 = 15;
}

/// enum e4k_if_filter
abstract final class E4kIfFilter {
  static const mix = 0;
  static const chan = 1;
  static const rc = 2;
}

/// struct e4k_pll_params
class E4kPllParams {
  int fosc = 0; // uint32_t
  int intendedFlo = 0; // uint32_t
  int flo = 0; // uint32_t
  int x = 0; // uint16_t
  int z = 0; // uint8_t
  int r = 0; // uint8_t
  int rIdx = 0; // uint8_t
  int threephase = 0; // uint8_t

  /// memcpy(&e4k->vco, p, sizeof(e4k->vco))
  void copyFrom(E4kPllParams p) {
    fosc = p.fosc;
    intendedFlo = p.intendedFlo;
    flo = p.flo;
    x = p.x;
    z = p.z;
    r = p.r;
    rIdx = p.rIdx;
    threephase = p.threephase;
  }
}

/// struct reg_field (include/reg_field.h)
class RegField {
  final int reg;
  final int shift;
  final int width;
  const RegField(this.reg, this.shift, this.width);
}

// ---- src/tuner_e4k.c ----

const int _einval = 22; // EINVAL

int _mhz(int x) => x * 1000 * 1000; // MHZ(x)
int _khz(int x) => x * 1000; // KHZ(x)

/// unsigned_delta
int unsignedDelta(int a, int b) {
  a &= 0xffffffff;
  b &= 0xffffffff;
  if (a > b) {
    return a - b;
  } else {
    return b - a;
  }
}

/// look-up table bit-width -> mask
const List<int> _width2mask = [0, 1, 3, 7, 0xf, 0x1f, 0x3f, 0x7f, 0xff];

// ---- Filter Control ----

final List<int> _rfFiltCenterUhf = [
  _mhz(360), _mhz(380), _mhz(405), _mhz(425), //
  _mhz(450), _mhz(475), _mhz(505), _mhz(540),
  _mhz(575), _mhz(615), _mhz(670), _mhz(720),
  _mhz(760), _mhz(840), _mhz(890), _mhz(970),
];

final List<int> _rfFiltCenterL = [
  _mhz(1300), _mhz(1320), _mhz(1360), _mhz(1410), //
  _mhz(1445), _mhz(1460), _mhz(1490), _mhz(1530),
  _mhz(1560), _mhz(1590), _mhz(1640), _mhz(1660),
  _mhz(1680), _mhz(1700), _mhz(1720), _mhz(1750),
];

int _closestArrIdx(List<int> arr, int freq) {
  int bi = 0;
  int bestDelta = 0xffffffff;

  // iterate over the array containing a list of the center
  // frequencies, selecting the closest one
  for (var i = 0; i < arr.length; i++) {
    final delta = unsignedDelta(freq, arr[i]);
    if (delta < bestDelta) {
      bestDelta = delta;
      bi = i;
    }
  }

  return bi;
}

/// return 4-bit index as to which RF filter to select
int _chooseRfFilter(int band, int freq) {
  int rc;

  switch (band) {
    case E4kBand.vhf2:
    case E4kBand.vhf3:
      rc = 0;
    case E4kBand.uhf:
      rc = _closestArrIdx(_rfFiltCenterUhf, freq);
    case E4kBand.l:
      rc = _closestArrIdx(_rfFiltCenterL, freq);
    default:
      rc = -_einval;
  }

  return rc;
}

/// Mixer Filter
final List<int> _mixFilterBw = [
  _khz(27000), _khz(27000), _khz(27000), _khz(27000), //
  _khz(27000), _khz(27000), _khz(27000), _khz(27000),
  _khz(4600), _khz(4200), _khz(3800), _khz(3400),
  _khz(3300), _khz(2700), _khz(2300), _khz(1900),
];

/// IF RC Filter
final List<int> _ifrcFilterBw = [
  _khz(21400), _khz(21000), _khz(17600), _khz(14700), //
  _khz(12400), _khz(10600), _khz(9000), _khz(7700),
  _khz(6400), _khz(5300), _khz(4400), _khz(3400),
  _khz(2600), _khz(1800), _khz(1200), _khz(1000),
];

/// IF Channel Filter
final List<int> _ifchFilterBw = [
  _khz(5500), _khz(5300), _khz(5000), _khz(4800), //
  _khz(4600), _khz(4400), _khz(4300), _khz(4100),
  _khz(3900), _khz(3800), _khz(3700), _khz(3600),
  _khz(3400), _khz(3300), _khz(3200), _khz(3100),
  _khz(3000), _khz(2950), _khz(2900), _khz(2800),
  _khz(2750), _khz(2700), _khz(2600), _khz(2550),
  _khz(2500), _khz(2450), _khz(2400), _khz(2300),
  _khz(2280), _khz(2240), _khz(2200), _khz(2150),
];

final List<List<int>> _ifFilterBw = [
  _mixFilterBw,
  _ifchFilterBw,
  _ifrcFilterBw,
];

const List<RegField> _ifFilterFields = [
  RegField(E4kReg.filt2, 4, 4),
  RegField(E4kReg.filt3, 0, 5),
  RegField(E4kReg.filt2, 0, 4),
];

int _findIfBw(int filter, int bw) {
  if (filter >= _ifFilterBw.length) return -_einval;

  return _closestArrIdx(_ifFilterBw[filter], bw);
}

// ---- Frequency Control ----

const int e4kFvcoMinKhz = 2600000; // 2.6 GHz
const int e4kFvcoMaxKhz = 3900000; // 3.9 GHz
const int e4kPllY = 65536;

// OUT_OF_SPEC is defined
const int e4kFloMinMhz = 50;
const int e4kFloMaxMhz = 2200;

/// struct pll_settings
class _PllSettings {
  final int freq;
  final int regSynth7;
  final int mult;
  const _PllSettings(this.freq, this.regSynth7, this.mult);
}

const List<_PllSettings> _pllVars = [
  _PllSettings(72400 * 1000, (1 << 3) | 7, 48),
  _PllSettings(81200 * 1000, (1 << 3) | 6, 40),
  _PllSettings(108300 * 1000, (1 << 3) | 5, 32),
  _PllSettings(162500 * 1000, (1 << 3) | 4, 24),
  _PllSettings(216600 * 1000, (1 << 3) | 3, 16),
  _PllSettings(325000 * 1000, (1 << 3) | 2, 12),
  _PllSettings(350000 * 1000, (1 << 3) | 1, 8),
  _PllSettings(432000 * 1000, (0 << 3) | 3, 8),
  _PllSettings(667000 * 1000, (0 << 3) | 2, 6),
  _PllSettings(1200000 * 1000, (0 << 3) | 1, 4),
];

// is_fvco_valid: only used under #if 0 in compute_fvco (not ported)

bool _isFoscValid(int fosc) {
  if (fosc < _mhz(16) || fosc > _mhz(30)) {
    rtlsdrLog('[E4K] Fosc $fosc invalid');
    return false;
  }

  return true;
}

// is_z_valid / use_3ph_mixing: unused static helpers in the C source

/// compute Fvco based on Fosc, Z and X
/// returns positive value (Fvco in Hz), 0 in case of error
int _computeFvco(int fOsc, int z, int x) {
  // We use the following transformation in order to
  // handle the fractional part with integer arithmetic:
  //  Fvco = Fosc * (Z + X/Y) <=> Fvco = Fosc * Z + (Fosc * X)/Y
  // This avoids X/Y = 0.  However, then we would overflow a 32bit
  // integer, as we cannot hold e.g. 26 MHz * 65536 either.
  final fvcoZ = fOsc * z;

  final fvcoX = (fOsc * x) ~/ e4kPllY;

  return fvcoZ + fvcoX;
}

/// compute_flo(uint32_t f_osc, uint8_t z, uint16_t x, uint8_t r) -> uint32_t
int _computeFlo(int fOsc, int z, int x, int r) {
  final fvco = _computeFvco(fOsc & 0xffffffff, z & 0xff, x & 0xffff);
  if (fvco == 0) return (-_einval) & 0xffffffff;

  return (fvco ~/ (r & 0xff)) & 0xffffffff;
}

/// e4k_state + the E4000 API as methods (struct e4k_state).
class E4kState {
  // void *i2c_dev: unused by the C driver
  int i2cAddr = 0; // uint8_t
  int band = E4kBand.vhf2; // enum e4k_band
  final E4kPllParams vco = E4kPllParams();
  RtlSdrI2c? rtlDev; // void *rtl_dev

  // ---- Register Access ----

  /// Write a register of the tuner chip. 0 on success, negative on error.
  int _regWrite(int reg, int val) {
    final data = Uint8List(2);
    data[0] = reg;
    data[1] = val;

    final r = rtlDev!.i2cWriteFn(i2cAddr, data, 2);
    return r == 2 ? 0 : -1;
  }

  /// Read a register of the tuner chip. Positive 8bit register contents on
  /// success, negative in case of error.
  int _regRead(int reg) {
    final data = Uint8List(1)..[0] = reg;

    if (rtlDev!.i2cWriteFn(i2cAddr, data, 1) < 1) return -1;

    if (rtlDev!.i2cReadFn(i2cAddr, data, 1) < 1) return -1;

    return data[0];
  }

  /// Set or clear some (masked) bits inside a register.
  int _regSetMask(int reg, int mask, int val) {
    mask &= 0xff;
    val &= 0xff;
    final tmp = _regRead(reg) & 0xff;

    if ((tmp & mask) == val) return 0;

    return _regWrite(reg, ((tmp & ~mask) | (val & mask)) & 0xff);
  }

  /// Write a given field inside a register.
  int _fieldWrite(RegField field, int val) {
    int rc;
    int mask;

    rc = _regRead(field.reg);
    if (rc < 0) return rc;

    mask = (_width2mask[field.width] << field.shift) & 0xff;

    return _regSetMask(field.reg, mask, ((val & 0xff) << field.shift) & 0xff);
  }

  /// Read a given field inside a register.
  int _fieldRead(RegField field) {
    int rc;

    rc = _regRead(field.reg);
    if (rc < 0) return rc;

    rc = (rc >> field.shift) & _width2mask[field.width];

    return rc;
  }

  // ---- Filter Control ----

  /// Automatically select apropriate RF filter based on e4k state
  int e4kRfFilterSet() {
    int rc;

    rc = _chooseRfFilter(band, vco.flo);
    if (rc < 0) return rc;

    return _regSetMask(E4kReg.filt1, 0xF, rc);
  }

  /// Set the filter band-width of any of the IF filters.
  /// Returns positive actual filter band-width, negative in case of error.
  int e4kIfFilterBwSet(int filter, int bandwidth) {
    int bwIdx;
    RegField field;

    if (filter >= _ifFilterBw.length) return -_einval;

    bwIdx = _findIfBw(filter, bandwidth & 0xffffffff);

    field = _ifFilterFields[filter];

    return _fieldWrite(field, bwIdx);
  }

  /// Enables / Disables the channel filter
  int e4kIfFilterChanEnable(int on) {
    return _regSetMask(
      E4kReg.filt3,
      e4kFilt3Disable,
      on != 0 ? 0 : e4kFilt3Disable,
    );
  }

  int e4kIfFilterBwGet(int filter) {
    List<int> arr;
    int rc;
    RegField field;

    if (filter >= _ifFilterBw.length) return -_einval;

    field = _ifFilterFields[filter];

    rc = _fieldRead(field);
    if (rc < 0) return rc;

    arr = _ifFilterBw[filter];

    return arr[rc];
  }

  // ---- Frequency Control ----

  int _bandSet(int band) {
    int rc;

    switch (band) {
      case E4kBand.vhf2:
      case E4kBand.vhf3:
      case E4kBand.uhf:
        _regWrite(E4kReg.bias, 3);
      case E4kBand.l:
        _regWrite(E4kReg.bias, 0);
    }

    // workaround: if we don't reset this register before writing to it,
    // we get a gap between 325-350 MHz
    rc = _regSetMask(E4kReg.synth1, 0x06, 0);
    rc = _regSetMask(E4kReg.synth1, 0x06, band << 1);
    if (rc >= 0) this.band = band;

    return rc;
  }

  /// Compute PLL parameters for given target frequency.
  /// Returns actual PLL frequency, as close as possible to intended_flo,
  /// 0 in case of error.
  static int e4kComputePllParams(E4kPllParams oscp, int fosc, int intendedFlo) {
    fosc &= 0xffffffff;
    intendedFlo &= 0xffffffff;
    int r = 2;
    int intendedFvco, remainder;
    int z = 0;
    int x;
    int flo;
    int threePhaseMixing = 0;
    oscp.rIdx = 0;

    if (!_isFoscValid(fosc)) return 0;

    for (var i = 0; i < _pllVars.length; ++i) {
      if (intendedFlo < _pllVars[i].freq) {
        threePhaseMixing = (_pllVars[i].regSynth7 & 0x08) != 0 ? 1 : 0;
        oscp.rIdx = _pllVars[i].regSynth7;
        r = _pllVars[i].mult;
        break;
      }
    }

    // flo(max) = 1700MHz, R(max) = 48, we need 64bit!
    intendedFvco = intendedFlo * r;

    // compute integral component of multiplier
    z = intendedFvco ~/ fosc;

    // compute fractional part.  this will not overflow,
    // as fosc(max) = 30MHz and z(max) = 255
    remainder = intendedFvco - (fosc * z);
    // remainder(max) = 30MHz, E4K_PLL_Y = 65536 -> 64bit!
    x = ((remainder * e4kPllY) ~/ fosc) & 0xffffffff;
    // x(max) as result of this computation is 65536

    // int flo = (uint32_t)compute_flo(...)
    flo = _computeFlo(fosc, z, x, r).toSigned(32);

    oscp.fosc = fosc;
    oscp.flo = flo & 0xffffffff;
    oscp.intendedFlo = intendedFlo;
    oscp.r = r;
    // oscp->r_idx = pll_vars[i].reg_synth7 & 0x0;
    oscp.threephase = threePhaseMixing;
    oscp.x = x & 0xffff;
    oscp.z = z & 0xff;

    return flo & 0xffffffff;
  }

  int e4kTuneParams(E4kPllParams p) {
    // program R + 3phase/2phase
    _regWrite(E4kReg.synth7, p.rIdx);
    // program Z
    _regWrite(E4kReg.synth3, p.z);
    // program X
    _regWrite(E4kReg.synth4, p.x & 0xff);
    _regWrite(E4kReg.synth5, p.x >> 8);

    // we're in auto calibration mode, so there's no need to trigger it

    vco.copyFrom(p);

    // set the band
    if (vco.flo < _mhz(140)) {
      _bandSet(E4kBand.vhf2);
    } else if (vco.flo < _mhz(350)) {
      _bandSet(E4kBand.vhf3);
    } else if (vco.flo < _mhz(1135)) {
      _bandSet(E4kBand.uhf);
    } else {
      _bandSet(E4kBand.l);
    }

    // select and set proper RF filter
    e4kRfFilterSet();

    return vco.flo.toSigned(32);
  }

  /// High-level tuning API, just specify frequency.
  /// Returns 0 (C: "actual tuned frequency"), negative in case of error.
  int e4kTuneFreq(int freq) {
    int rc; // uint32_t
    final p = E4kPllParams();

    // determine PLL parameters
    rc = e4kComputePllParams(p, vco.fosc, freq);
    if (rc == 0) return -_einval;

    // actually tune to those parameters
    rc = e4kTuneParams(p) & 0xffffffff;

    // check PLL lock
    rc = _regRead(E4kReg.synth1) & 0xffffffff;
    if ((rc & 0x01) == 0) {
      rtlsdrLog('[E4K] PLL not locked for ${freq & 0xffffffff} Hz!');
      return -1;
    }

    return 0;
  }

  // ---- Gain Control ----

  int e4kSetLnaGain(int gain) {
    for (var i = 0; i < _lnagain.length ~/ 2; ++i) {
      if (_lnagain[i * 2] == gain) {
        _regSetMask(E4kReg.gain1, 0xf, _lnagain[i * 2 + 1]);
        return gain;
      }
    }
    return -_einval;
  }

  int e4kSetEnhGain(int gain) {
    for (var i = 0; i < _enhgain.length; ++i) {
      if (_enhgain[i] == gain) {
        _regSetMask(E4kReg.agc11, 0x7, e4kAgc11LnaGainEnh | (i << 1));
        return gain;
      }
    }
    _regSetMask(E4kReg.agc11, 0x7, 0);

    // special case: 0 = off
    if (0 == gain) {
      return 0;
    } else {
      return -_einval;
    }
  }

  int e4kEnableManualGain(int manual) {
    if ((manual & 0xff) != 0) {
      // Set LNA mode to manual
      _regSetMask(E4kReg.agc1, e4kAgc1ModMask, E4kAgcMode.serial);

      // Set Mixer Gain Control to manual
      _regSetMask(E4kReg.agc7, e4kAgc7MixGainAuto, 0);
    } else {
      // Set LNA mode to auto
      _regSetMask(E4kReg.agc1, e4kAgc1ModMask, E4kAgcMode.ifSerialLnaAuton);
      // Set Mixer Gain Control to auto
      _regSetMask(E4kReg.agc7, e4kAgc7MixGainAuto, 1);

      _regSetMask(E4kReg.agc11, 0x7, 0);
    }

    return 0;
  }

  /// Set the gain of one of the IF gain stages ([stage] 1..6, [value] dB).
  int e4kIfGainSet(int stage, int value) {
    int rc;
    int mask;
    RegField field;

    stage &= 0xff;
    value = value.toSigned(8);

    rc = _findStageGain(stage, value);
    if (rc < 0) return rc;

    // compute the bit-mask for the given gain field
    field = _ifStageGainRegs[stage];
    mask = (_width2mask[field.width] << field.shift) & 0xff;

    return _regSetMask(field.reg, mask, rc << field.shift);
  }

  int e4kMixerGainSet(int value) {
    int bit;

    switch (value.toSigned(8)) {
      case 4:
        bit = 0;
      case 12:
        bit = 1;
      default:
        return -_einval;
    }

    return _regSetMask(E4kReg.gain2, 1, bit);
  }

  int e4kCommonmodeSet(int value) {
    value = value.toSigned(8);
    if (value < 0) {
      return -_einval;
    } else if (value > 7) {
      return -_einval;
    }

    return _regSetMask(E4kReg.dc7, 7, value);
  }

  // ---- DC Offset ----

  int e4kManualDcOffset(int iofs, int irange, int qofs, int qrange) {
    int res;
    iofs = iofs.toSigned(8);
    irange = irange.toSigned(8);
    qofs = qofs.toSigned(8);
    qrange = qrange.toSigned(8);

    if ((iofs < 0x00) || (iofs > 0x3f)) return -_einval;
    if ((irange < 0x00) || (irange > 0x03)) return -_einval;
    if ((qofs < 0x00) || (qofs > 0x3f)) return -_einval;
    if ((qrange < 0x00) || (qrange > 0x03)) return -_einval;

    res = _regSetMask(E4kReg.dc2, 0x3f, iofs);
    if (res < 0) return res;

    res = _regSetMask(E4kReg.dc3, 0x3f, qofs);
    if (res < 0) return res;

    res = _regSetMask(E4kReg.dc4, 0x33, (qrange << 4) | irange);
    return res;
  }

  /// Perform a DC offset calibration right now
  int e4kDcOffsetCalibrate() {
    // make sure the DC range detector is enabled
    _regSetMask(E4kReg.dc5, e4kDc5RangeDetEn, e4kDc5RangeDetEn);

    return _regWrite(E4kReg.dc1, 0x01);
  }

  int e4kDcOffsetGenTable() {
    // FIXME: read ont current gain values and write them back
    // before returning to the caller

    // disable auto mixer gain
    _regSetMask(E4kReg.agc7, e4kAgc7MixGainAuto, 0);

    // set LNA/IF gain to full manual
    _regSetMask(E4kReg.agc1, e4kAgc1ModMask, E4kAgcMode.serial);

    // set all 'other' gains to maximum
    for (var i = 2; i <= 6; i++) {
      e4kIfGainSet(i, _ifGainsMax[i]);
    }

    // iterate over all mixer + if_stage_1 gain combinations
    for (var i = 0; i < _dcGainComb.length; i++) {
      int offsI, offsQ, range, rangeI, rangeQ;

      // set the combination of mixer / if1 gain
      e4kMixerGainSet(_dcGainComb[i].mixerGain);
      e4kIfGainSet(1, _dcGainComb[i].if1Gain);

      // perform actual calibration
      e4kDcOffsetCalibrate();

      // extract I/Q offset and range values
      offsI = _regRead(E4kReg.dc2) & 0x3f;
      offsQ = _regRead(E4kReg.dc3) & 0x3f;
      range = _regRead(E4kReg.dc4) & 0xff;
      rangeI = range & 0x3;
      rangeQ = (range >> 4) & 0x3;

      rtlsdrLog('[E4K] Table $i I=$rangeI/$offsI, Q=$rangeQ/$offsQ');

      // write into the table
      _regWrite(_dcGainComb[i].reg, _toLut(offsQ, rangeQ) & 0xff);
      _regWrite(_dcGainComb[i].reg + 0x10, _toLut(offsI, rangeI) & 0xff);
    }

    return 0;
  }

  // ---- Standby ----

  /// Enable/disable standby mode
  int e4kStandby(int enable) {
    _regSetMask(
      E4kReg.master1,
      e4kMaster1NormStby,
      enable != 0 ? 0 : e4kMaster1NormStby,
    );

    return 0;
  }

  // ---- Initialization ----

  int _magicInit() {
    _regWrite(0x7e, 0x01);
    _regWrite(0x7f, 0xfe);
    _regWrite(0x82, 0x00);
    _regWrite(0x86, 0x50); // polarity A
    _regWrite(0x87, 0x20);
    _regWrite(0x88, 0x01);
    _regWrite(0x9f, 0x7f);
    _regWrite(0xa0, 0x07);

    return 0;
  }

  /// Initialize the E4K tuner
  int e4kInit() {
    // make a dummy i2c read or write command, will not be ACKed!
    _regRead(0);

    // Make sure we reset everything and clear POR indicator
    _regWrite(
      E4kReg.master1,
      e4kMaster1Reset | e4kMaster1NormStby | e4kMaster1PorDet,
    );

    // Configure clock input
    _regWrite(E4kReg.clkInp, 0x00);

    // Disable clock output
    _regWrite(E4kReg.refClk, 0x00);
    _regWrite(E4kReg.clkoutPwdn, 0x96);

    // Write some magic values into registers
    _magicInit();
    // #if 0: e4k_commonmode_set(4), e4k_dc_offset_gen_table(),
    //        DCTIME1/DCTIME2 = 0x01 (time variant DC correction)

    // Set LNA mode to manual
    _regWrite(E4kReg.agc4, 0x10); // High threshold
    _regWrite(E4kReg.agc5, 0x04); // Low threshold
    _regWrite(E4kReg.agc6, 0x1a); // LNA calib + loop rate

    _regSetMask(E4kReg.agc1, e4kAgc1ModMask, E4kAgcMode.serial);

    // Set Mixer Gain Control to manual
    _regSetMask(E4kReg.agc7, e4kAgc7MixGainAuto, 0);

    // #if 0: LNA gain enhancement, automatic IF gain mode switching

    // Use auto-gain as default
    e4kEnableManualGain(0);

    // Select moderate gain levels
    e4kIfGainSet(1, 6);
    e4kIfGainSet(2, 0);
    e4kIfGainSet(3, 0);
    e4kIfGainSet(4, 0);
    e4kIfGainSet(5, 9);
    e4kIfGainSet(6, 9);

    // Set the most narrow filter we can possibly use
    e4kIfFilterBwSet(E4kIfFilter.mix, _khz(1900));
    e4kIfFilterBwSet(E4kIfFilter.rc, _khz(1000));
    e4kIfFilterBwSet(E4kIfFilter.chan, _khz(2150));
    e4kIfFilterChanEnable(1);

    // Disable time variant DC correction and LUT
    _regSetMask(E4kReg.dc5, 0x03, 0);
    _regSetMask(E4kReg.dctime1, 0x03, 0);
    _regSetMask(E4kReg.dctime2, 0x03, 0);

    return 0;
  }
}

// ---- Gain Control tables ----

const List<int> _ifStage1Gain = [-3, 6];

const List<int> _ifStage23Gain = [0, 3, 6, 9];

const List<int> _ifStage4Gain = [0, 1, 2, 2];

const List<int> _ifStage56Gain = [3, 6, 9, 12, 15, 15, 15, 15];

const List<List<int>> _ifStageGain = [
  [], // 0
  _ifStage1Gain,
  _ifStage23Gain,
  _ifStage23Gain,
  _ifStage4Gain,
  _ifStage56Gain,
  _ifStage56Gain,
];

const List<RegField> _ifStageGainRegs = [
  RegField(0, 0, 0),
  RegField(E4kReg.gain3, 0, 1),
  RegField(E4kReg.gain3, 1, 2),
  RegField(E4kReg.gain3, 3, 2),
  RegField(E4kReg.gain3, 5, 2),
  RegField(E4kReg.gain4, 0, 3),
  RegField(E4kReg.gain4, 3, 3),
];

const List<int> _lnagain = [
  -50, 0, //
  -25, 1,
  0, 4,
  25, 5,
  50, 6,
  75, 7,
  100, 8,
  125, 9,
  150, 10,
  175, 11,
  200, 12,
  250, 13,
  300, 14,
];

const List<int> _enhgain = [10, 30, 50, 70];

int _findStageGain(int stage, int val) {
  List<int> arr;

  if (stage >= _ifStageGain.length) return -_einval;

  arr = _ifStageGain[stage];

  for (var i = 0; i < arr.length; i++) {
    if (arr[i] == val) return i;
  }
  return -_einval;
}

const List<int> _ifGainsMax = [0, 6, 9, 9, 2, 15, 15];

/// struct gain_comb
class _GainComb {
  final int mixerGain;
  final int if1Gain;
  final int reg;
  const _GainComb(this.mixerGain, this.if1Gain, this.reg);
}

const List<_GainComb> _dcGainComb = [
  _GainComb(4, -3, 0x50),
  _GainComb(4, 6, 0x51),
  _GainComb(12, -3, 0x52),
  _GainComb(12, 6, 0x53),
];

int _toLut(int offset, int range) => offset | (range << 6); // TO_LUT

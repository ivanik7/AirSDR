// Dart port of librtlsdr (RTL2832U core).
//
// Source: ~/prj/ref/rtl-sdr/src/librtlsdr.c (osmocom rtl-sdr v2.0.3, 797f814,
// 2057 lines). Section map (C line numbers):
//   tuner glue ................. 129-298   (r820t_* wrappers, tuners[] table)
//   known_devices .............. 300-352
//   register access ............ 405-578   (read/write_array, i2c, demod, gpio)
//   FIR / baseband init ........ 580-684
//   IF / xtal / ppm ............ 686-778
//   usb strings / eeprom ....... 780-882
//   tuning, gains, sample rate . 884-1280
//   open / close ............... 1435-1700 (libusb enumeration removed: the Dart
//                                           port receives an opened UsbDeviceHandle)
//   buffers / sync / async ..... 1702-2011 (async built on UsbDeviceHandle.openBulkIn)
//   i2c fn / bias tee .......... 2013-2057
//
// rtl-sdr, turns your Realtek RTL2832 based DVB dongle into a SDR receiver
// Copyright (C) 2012-2014 by Steve Markgraf <steve@steve-m.de>
// Copyright (C) 2012 by Dimitri Stolnikov <horiz0n@gmx.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// (at your option) any later version. (Distributed in this app under GPL-3.0.)
//
// Porting notes:
//  * Every C `uint32_t`/`uint16_t`/`uint8_t` truncation that can matter is
//    reproduced with explicit masks; C double->integer conversions use
//    truncate() exactly where C converts.
//  * libusb errors: UsbDeviceHandle throws UsbException(code); the port maps
//    it back to the libusb return code, so control flow is identical.
//  * fprintf(stderr, ...) -> rtlsdrLog(...).

import 'dart:async';
import 'dart:io' show sleep;
import 'dart:typed_data';

import '../../usb/usb_transport.dart';
import 'rtl_sdr.dart';
import 'rtlsdr_i2c.dart';
import 'tuner_r82xx.dart';

export 'rtl_sdr.dart';

/// rtlsdr_read_async_cb_t. [block] is valid only during the callback: the
/// slot is released (resubmitted) when the callback returns, exactly like
/// the libusb transfer in the C driver. View the bytes with
/// `Pointer<Uint8>.fromAddress(block.address).asTypedList(block.length)`.
typedef RtlSdrReadAsyncCb = void Function(UsbBlock block);

/// rtlsdr_tuner_iface_t
class RtlSdrTunerIface {
  // tuner interface
  final int Function(RtlSdrDev dev)? init;
  final int Function(RtlSdrDev dev)? exit;
  final int Function(RtlSdrDev dev, int freq /* Hz */)? setFreq;
  final int Function(RtlSdrDev dev, int bw /* Hz */)? setBw;
  final int Function(RtlSdrDev dev, int gain /* tenth dB */)? setGain;
  final int Function(RtlSdrDev dev, int stage, int gain /* tenth dB */)?
      setIfGain;
  final int Function(RtlSdrDev dev, int manual)? setGainMode;
  const RtlSdrTunerIface({
    this.init,
    this.exit,
    this.setFreq,
    this.setBw,
    this.setGain,
    this.setIfGain,
    this.setGainMode,
  });
}

/// enum rtlsdr_async_status
abstract final class RtlSdrAsyncStatus {
  static const inactive = 0; // RTLSDR_INACTIVE
  static const canceling = 1; // RTLSDR_CANCELING
  static const running = 2; // RTLSDR_RUNNING
}

const int firLen = 16; // FIR_LEN

/// FIR coefficients.
///
/// The filter is running at XTal frequency. It is symmetric filter with 32
/// coefficients. Only first 16 coefficients are specified, the other 16
/// use the same values but in reversed order. The first coefficient in
/// the array is the outer one, the last, the last is the inner one.
/// First 8 coefficients are 8 bit signed integers, the next 8 coefficients
/// are 12 bit signed integers. All coefficients have the same weight.
///
/// Default FIR coefficients used for DAB/FM by the Windows driver,
/// the DVB driver uses different ones
const List<int> firDefault = [
  -54, -36, -41, -40, -32, -14, 14, 53, // 8 bit signed
  101, 156, 215, 273, 327, 372, 404, 421 // 12 bit signed
];

// ---- generic tuner interface functions (librtlsdr.c:129-298) ----
// E4000 / FC0012 / FC0013 / FC2580 drivers are not ported yet (see
// STATUS-rtlsdr.md): they are probed and reported, but get an empty interface.

int _r820tInit(RtlSdrDev devt) {
  devt.r82xxP.rtlDev = devt;

  if (devt.tunerType == RtlSdrTuner.r828d) {
    devt.r82xxC.i2cAddr = r828dI2cAddr;
    devt.r82xxC.rafaelChip = R82xxChip.r828d;
  } else {
    devt.r82xxC.i2cAddr = r820tI2cAddr;
    devt.r82xxC.rafaelChip = R82xxChip.r820t;
  }

  devt.r82xxC.xtal = devt.getXtalFreq().tunerFreq;

  devt.r82xxC.maxI2cMsgLen = 8;
  devt.r82xxC.usePredetect = 0;
  devt.r82xxP.cfg = devt.r82xxC;

  return devt.r82xxP.r82xxInit();
}

int _r820tExit(RtlSdrDev devt) => devt.r82xxP.r82xxStandby();

int _r820tSetFreq(RtlSdrDev devt, int freq) => devt.r82xxP.r82xxSetFreq(freq);

int _r820tSetBw(RtlSdrDev devt, int bw) {
  int r;

  r = devt.r82xxP.r82xxSetBandwidth(bw, devt.rate);
  if (r < 0) return r;
  r = devt._setIfFreq(r);
  if (r != 0) return r;
  return devt.setCenterFreq(devt.freq);
}

int _r820tSetGain(RtlSdrDev devt, int gain) =>
    devt.r82xxP.r82xxSetGain(1, gain);

int _r820tSetGainMode(RtlSdrDev devt, int manual) =>
    devt.r82xxP.r82xxSetGain(manual, 0);

/// definition order must match enum rtlsdr_tuner
const List<RtlSdrTunerIface> tuners = [
  RtlSdrTunerIface(), // dummy for unknown tuners
  RtlSdrTunerIface(), // E4000: not ported
  RtlSdrTunerIface(), // FC0012: not ported
  RtlSdrTunerIface(), // FC0013: not ported
  RtlSdrTunerIface(), // FC2580: not ported
  RtlSdrTunerIface(
    init: _r820tInit,
    exit: _r820tExit,
    setFreq: _r820tSetFreq,
    setBw: _r820tSetBw,
    setGain: _r820tSetGain,
    setGainMode: _r820tSetGainMode,
  ),
  RtlSdrTunerIface(
    init: _r820tInit,
    exit: _r820tExit,
    setFreq: _r820tSetFreq,
    setBw: _r820tSetBw,
    setGain: _r820tSetGain,
    setGainMode: _r820tSetGainMode,
  ),
];

/// rtlsdr_dongle_t
class RtlSdrDongle {
  final int vid;
  final int pid;
  final String name;
  const RtlSdrDongle(this.vid, this.pid, this.name);
}

/// Please add your device here and send a patch to osmocom-sdr@lists.osmocom.org
const List<RtlSdrDongle> knownDevices = [
  RtlSdrDongle(0x0bda, 0x2832, 'Generic RTL2832U'),
  RtlSdrDongle(0x0bda, 0x2838, 'Generic RTL2832U OEM'),
  RtlSdrDongle(0x0413, 0x6680, 'DigitalNow Quad DVB-T PCI-E card'),
  RtlSdrDongle(0x0413, 0x6f0f, 'Leadtek WinFast DTV Dongle mini D'),
  RtlSdrDongle(0x0458, 0x707f, 'Genius TVGo DVB-T03 USB dongle (Ver. B)'),
  RtlSdrDongle(0x0ccd, 0x00a9, 'Terratec Cinergy T Stick Black (rev 1)'),
  RtlSdrDongle(0x0ccd, 0x00b3, 'Terratec NOXON DAB/DAB+ USB dongle (rev 1)'),
  RtlSdrDongle(0x0ccd, 0x00b4, 'Terratec Deutschlandradio DAB Stick'),
  RtlSdrDongle(0x0ccd, 0x00b5, 'Terratec NOXON DAB Stick - Radio Energy'),
  RtlSdrDongle(0x0ccd, 0x00b7, 'Terratec Media Broadcast DAB Stick'),
  RtlSdrDongle(0x0ccd, 0x00b8, 'Terratec BR DAB Stick'),
  RtlSdrDongle(0x0ccd, 0x00b9, 'Terratec WDR DAB Stick'),
  RtlSdrDongle(0x0ccd, 0x00c0, 'Terratec MuellerVerlag DAB Stick'),
  RtlSdrDongle(0x0ccd, 0x00c6, 'Terratec Fraunhofer DAB Stick'),
  RtlSdrDongle(0x0ccd, 0x00d3, 'Terratec Cinergy T Stick RC (Rev.3)'),
  RtlSdrDongle(0x0ccd, 0x00d7, 'Terratec T Stick PLUS'),
  RtlSdrDongle(0x0ccd, 0x00e0, 'Terratec NOXON DAB/DAB+ USB dongle (rev 2)'),
  RtlSdrDongle(0x1554, 0x5020, 'PixelView PV-DT235U(RN)'),
  RtlSdrDongle(0x15f4, 0x0131, 'Astrometa DVB-T/DVB-T2'),
  RtlSdrDongle(0x15f4, 0x0133, 'HanfTek DAB+FM+DVB-T'),
  RtlSdrDongle(0x185b, 0x0620, 'Compro Videomate U620F'),
  RtlSdrDongle(0x185b, 0x0650, 'Compro Videomate U650F'),
  RtlSdrDongle(0x185b, 0x0680, 'Compro Videomate U680F'),
  RtlSdrDongle(0x1b80, 0xd393, 'GIGABYTE GT-U7300'),
  RtlSdrDongle(0x1b80, 0xd394, 'DIKOM USB-DVBT HD'),
  RtlSdrDongle(0x1b80, 0xd395, 'Peak 102569AGPK'),
  RtlSdrDongle(0x1b80, 0xd397, 'KWorld KW-UB450-T USB DVB-T Pico TV'),
  RtlSdrDongle(0x1b80, 0xd398, 'Zaapa ZT-MINDVBZP'),
  RtlSdrDongle(0x1b80, 0xd39d, 'SVEON STV20 DVB-T USB & FM'),
  RtlSdrDongle(0x1b80, 0xd3a4, 'Twintech UT-40'),
  RtlSdrDongle(0x1b80, 0xd3a8, 'ASUS U3100MINI_PLUS_V2'),
  RtlSdrDongle(0x1b80, 0xd3af, 'SVEON STV27 DVB-T USB & FM'),
  RtlSdrDongle(0x1b80, 0xd3b0, 'SVEON STV21 DVB-T USB & FM'),
  RtlSdrDongle(0x1d19, 0x1101, 'Dexatek DK DVB-T Dongle (Logilink VG0002A)'),
  RtlSdrDongle(
      0x1d19, 0x1102, 'Dexatek DK DVB-T Dongle (MSI DigiVox mini II V3.0)'),
  RtlSdrDongle(0x1d19, 0x1103, 'Dexatek Technology Ltd. DK 5217 DVB-T Dongle'),
  RtlSdrDongle(0x1d19, 0x1104, 'MSI DigiVox Micro HD'),
  RtlSdrDongle(0x1f4d, 0xa803, 'Sweex DVB-T USB'),
  RtlSdrDongle(0x1f4d, 0xb803, 'GTek T803'),
  RtlSdrDongle(0x1f4d, 0xc803, 'Lifeview LV5TDeluxe'),
  RtlSdrDongle(0x1f4d, 0xd286, 'MyGica TD312'),
  RtlSdrDongle(0x1f4d, 0xd803, 'PROlectrix DV107669'),
];

/// find_known_device
RtlSdrDongle? findKnownDevice(int vid, int pid) {
  for (final d in knownDevices) {
    if (d.vid == vid && d.pid == pid) return d;
  }
  return null;
}

const int defaultBufNumber = 15; // DEFAULT_BUF_NUMBER
const int defaultBufLength = 16 * 32 * 512; // DEFAULT_BUF_LENGTH

const int defRtlXtalFreq = 28800000; // DEF_RTL_XTAL_FREQ
const int minRtlXtalFreq = defRtlXtalFreq - 1000; // MIN_RTL_XTAL_FREQ
const int maxRtlXtalFreq = defRtlXtalFreq + 1000; // MAX_RTL_XTAL_FREQ

const int ctrlIn = UsbReqType.typeVendor | UsbReqType.endpointIn; // CTRL_IN
const int ctrlOut = UsbReqType.typeVendor | UsbReqType.endpointOut; // CTRL_OUT
const int ctrlTimeout = 300; // CTRL_TIMEOUT
const int bulkTimeout = 0; // BULK_TIMEOUT

const int eepromAddr = 0xa0; // EEPROM_ADDR

/// enum usb_reg
abstract final class UsbReg {
  static const usbSysctl = 0x2000; // USB_SYSCTL
  static const usbCtrl = 0x2010; // USB_CTRL
  static const usbStat = 0x2014; // USB_STAT
  static const usbEpaCfg = 0x2144; // USB_EPA_CFG
  static const usbEpaCtl = 0x2148; // USB_EPA_CTL
  static const usbEpaMaxpkt = 0x2158; // USB_EPA_MAXPKT
  static const usbEpaMaxpkt2 = 0x215a; // USB_EPA_MAXPKT_2
  static const usbEpaFifoCfg = 0x2160; // USB_EPA_FIFO_CFG
}

/// enum sys_reg
abstract final class SysReg {
  static const demodCtl = 0x3000; // DEMOD_CTL
  static const gpo = 0x3001; // GPO
  static const gpi = 0x3002; // GPI
  static const gpoe = 0x3003; // GPOE
  static const gpd = 0x3004; // GPD
  static const sysinte = 0x3005; // SYSINTE
  static const sysints = 0x3006; // SYSINTS
  static const gpCfg0 = 0x3007; // GP_CFG0
  static const gpCfg1 = 0x3008; // GP_CFG1
  static const sysinte1 = 0x3009; // SYSINTE_1
  static const sysints1 = 0x300a; // SYSINTS_1
  static const demodCtl1 = 0x300b; // DEMOD_CTL_1
  static const irSuspend = 0x300c; // IR_SUSPEND
}

/// enum blocks
abstract final class Blocks {
  static const demodb = 0; // DEMODB
  static const usbb = 1; // USBB
  static const sysb = 2; // SYSB
  static const tunb = 3; // TUNB
  static const romb = 4; // ROMB
  static const irb = 5; // IRB
  static const iicb = 6; // IICB
}

// Tuner probe constants (include/tuner_*.h)
const int e4kI2cAddr = 0xc8; // E4K_I2C_ADDR
const int e4kCheckAddr = 0x02; // E4K_CHECK_ADDR
const int e4kCheckVal = 0x40; // E4K_CHECK_VAL
const int fc0012I2cAddr = 0xc6; // FC0012_I2C_ADDR
const int fc0012CheckAddr = 0x00; // FC0012_CHECK_ADDR
const int fc0012CheckVal = 0xa1; // FC0012_CHECK_VAL
const int fc0013I2cAddr = 0xc6; // FC0013_I2C_ADDR
const int fc0013CheckAddr = 0x00; // FC0013_CHECK_ADDR
const int fc0013CheckVal = 0xa3; // FC0013_CHECK_VAL
const int fc2580I2cAddr = 0xac; // FC2580_I2C_ADDR
const int fc2580CheckAddr = 0x01; // FC2580_CHECK_ADDR
const int fc2580CheckVal = 0x56; // FC2580_CHECK_VAL

/// two raised to the power of n (TWO_POW, a double in C)
double _twoPow(int n) => (1 << n).toDouble();

/// C `(uint32_t)` of a double (values here are always in range).
int _u32(double v) => v.truncate() & 0xffffffff;

/// struct rtlsdr_dev + the librtlsdr API as methods.
class RtlSdrDev implements RtlSdrI2c {
  final UsbDeviceHandle devh;
  int xferBufNum = 0;
  int xferBufLen = 0;
  RtlSdrReadAsyncCb? cb;
  int asyncStatus = RtlSdrAsyncStatus.inactive;
  int asyncCancel = 0;
  // rtl demod context
  int rate = 0; // Hz
  int rtlXtal = 0; // Hz
  final List<int> fir = List<int>.filled(firLen, 0);
  int directSampling = 0;
  // tuner context
  int tunerType = RtlSdrTuner.unknown;
  RtlSdrTunerIface? tuner;
  int tunXtal = 0; // Hz
  int freq = 0; // Hz
  int bw = 0;
  int offsFreq = 0; // Hz
  int corr = 0; // ppm
  int gain = 0; // tenth dB
  // struct e4k_state e4k_s: not ported
  final R82xxConfig r82xxC = R82xxConfig();
  late final R82xxPriv r82xxP = R82xxPriv(r82xxC, this);
  // status
  int devLost = 0;
  int driverActive = 0;
  int xferErrors = 0;
  String manufact = '';
  String product = '';

  // async state (Dart replacement of xfer[] / libusb event loop)
  BulkInStream? _stream;
  Completer<void>? _asyncWake;

  RtlSdrDev._(this.devh);

  // ------------------------------------------------------------------
  // register access (librtlsdr.c:405-578)
  // ------------------------------------------------------------------

  int _controlTransfer(int requestType, int request, int value, int index,
      Uint8List data, int length, int timeout) {
    try {
      return devh.controlTransfer(
          requestType, request, value & 0xffff, index & 0xffff, data, length,
          timeoutMs: timeout);
    } on UsbException catch (e) {
      return e.code;
    }
  }

  /// rtlsdr_read_array
  int readArray(int block, int addr, Uint8List array, int len) {
    final index = (block << 8) & 0xffff;
    return _controlTransfer(ctrlIn, 0, addr, index, array, len, ctrlTimeout);
  }

  /// rtlsdr_write_array
  int writeArray(int block, int addr, Uint8List array, int len) {
    final index = ((block << 8) | 0x10) & 0xffff;
    return _controlTransfer(ctrlOut, 0, addr, index, array, len, ctrlTimeout);
  }

  /// rtlsdr_i2c_write_reg
  int i2cWriteReg(int i2cAddr, int reg, int val) {
    final data = Uint8List(2);
    data[0] = reg;
    data[1] = val;
    return writeArray(Blocks.iicb, i2cAddr & 0xff, data, 2);
  }

  /// rtlsdr_i2c_read_reg
  int i2cReadReg(int i2cAddr, int reg) {
    final addr = i2cAddr & 0xff;
    final data = Uint8List(1); // uint8_t data = 0;

    writeArray(Blocks.iicb, addr, Uint8List.fromList([reg & 0xff]), 1);
    readArray(Blocks.iicb, addr, data, 1);

    return data[0];
  }

  /// rtlsdr_i2c_write
  int i2cWrite(int i2cAddr, Uint8List buffer, int len) =>
      writeArray(Blocks.iicb, i2cAddr & 0xff, buffer, len);

  /// rtlsdr_i2c_read
  int i2cRead(int i2cAddr, Uint8List buffer, int len) =>
      readArray(Blocks.iicb, i2cAddr & 0xff, buffer, len);

  /// rtlsdr_read_reg
  int readReg(int block, int addr, int len) {
    int r;
    final data = Uint8List(2);
    final index = (block << 8) & 0xffff;
    int reg;

    r = _controlTransfer(ctrlIn, 0, addr, index, data, len, ctrlTimeout);

    if (r < 0) rtlsdrLog('rtlsdr_read_reg failed with $r');

    reg = (data[1] << 8) | data[0];

    return reg;
  }

  /// rtlsdr_write_reg
  int writeReg(int block, int addr, int val, int len) {
    int r;
    final data = Uint8List(2);
    final index = ((block << 8) | 0x10) & 0xffff;
    val &= 0xffff;

    if (len == 1) {
      data[0] = val & 0xff;
    } else {
      data[0] = val >> 8;
    }

    data[1] = val & 0xff;

    r = _controlTransfer(ctrlOut, 0, addr, index, data, len, ctrlTimeout);

    if (r < 0) rtlsdrLog('rtlsdr_write_reg failed with $r');

    return r;
  }

  /// rtlsdr_demod_read_reg
  int demodReadReg(int page, int addr, int len) {
    int r;
    final data = Uint8List(2);

    final index = page & 0xff;
    int reg;
    addr = ((addr << 8) | 0x20) & 0xffff;

    r = _controlTransfer(ctrlIn, 0, addr, index, data, len, ctrlTimeout);

    if (r < 0) rtlsdrLog('rtlsdr_demod_read_reg failed with $r');

    reg = (data[1] << 8) | data[0];

    return reg;
  }

  /// rtlsdr_demod_write_reg
  int demodWriteReg(int page, int addr, int val, int len) {
    int r;
    final data = Uint8List(2);
    final index = (0x10 | page) & 0xffff;
    addr = ((addr << 8) | 0x20) & 0xffff;
    val &= 0xffff;

    if (len == 1) {
      data[0] = val & 0xff;
    } else {
      data[0] = val >> 8;
    }

    data[1] = val & 0xff;

    r = _controlTransfer(ctrlOut, 0, addr, index, data, len, ctrlTimeout);

    if (r < 0) rtlsdrLog('rtlsdr_demod_write_reg failed with $r');

    demodReadReg(0x0a, 0x01, 1);

    return (r == len) ? 0 : -1;
  }

  /// rtlsdr_set_gpio_bit
  void setGpioBit(int gpio, int val) {
    int r;

    gpio = (1 << gpio) & 0xff;
    r = readReg(Blocks.sysb, SysReg.gpo, 1);
    r = val != 0 ? (r | gpio) : (r & ~gpio);
    writeReg(Blocks.sysb, SysReg.gpo, r, 1);
  }

  /// rtlsdr_set_gpio_output
  void setGpioOutput(int gpio) {
    int r;
    gpio = (1 << gpio) & 0xff;

    r = readReg(Blocks.sysb, SysReg.gpd, 1);
    writeReg(Blocks.sysb, SysReg.gpd, r & ~gpio, 1);
    r = readReg(Blocks.sysb, SysReg.gpoe, 1);
    writeReg(Blocks.sysb, SysReg.gpoe, r | gpio, 1);
  }

  /// rtlsdr_set_i2c_repeater
  void setI2cRepeater(int on) {
    demodWriteReg(1, 0x01, on != 0 ? 0x18 : 0x10, 1);
  }

  /// rtlsdr_set_fir
  int setFir() {
    final fir = Uint8List(20);

    int i;
    // format: int8_t[8]
    for (i = 0; i < 8; ++i) {
      final val = this.fir[i];
      if (val < -128 || val > 127) {
        return -1;
      }
      fir[i] = val;
    }
    // format: int12_t[8]
    for (i = 0; i < 8; i += 2) {
      final val0 = this.fir[8 + i];
      final val1 = this.fir[8 + i + 1];
      if (val0 < -2048 || val0 > 2047 || val1 < -2048 || val1 > 2047) {
        return -1;
      }
      fir[8 + i * 3 ~/ 2] = val0 >> 4;
      fir[8 + i * 3 ~/ 2 + 1] = (val0 << 4) | ((val1 >> 8) & 0x0f);
      fir[8 + i * 3 ~/ 2 + 2] = val1;
    }

    for (i = 0; i < fir.length; i++) {
      if (demodWriteReg(1, 0x1c + i, fir[i], 1) != 0) return -1;
    }

    return 0;
  }

  /// rtlsdr_init_baseband
  void initBaseband() {
    int i;

    // initialize USB
    writeReg(Blocks.usbb, UsbReg.usbSysctl, 0x09, 1);
    writeReg(Blocks.usbb, UsbReg.usbEpaMaxpkt, 0x0002, 2);
    writeReg(Blocks.usbb, UsbReg.usbEpaCtl, 0x1002, 2);

    // poweron demod
    writeReg(Blocks.sysb, SysReg.demodCtl1, 0x22, 1);
    writeReg(Blocks.sysb, SysReg.demodCtl, 0xe8, 1);

    // reset demod (bit 3, soft_rst)
    demodWriteReg(1, 0x01, 0x14, 1);
    demodWriteReg(1, 0x01, 0x10, 1);

    // disable spectrum inversion and adjacent channel rejection
    demodWriteReg(1, 0x15, 0x00, 1);
    demodWriteReg(1, 0x16, 0x0000, 2);

    // clear both DDC shift and IF frequency registers
    for (i = 0; i < 6; i++) {
      demodWriteReg(1, 0x16 + i, 0x00, 1);
    }

    setFir();

    // enable SDR mode, disable DAGC (bit 5)
    demodWriteReg(0, 0x19, 0x05, 1);

    // init FSM state-holding register
    demodWriteReg(1, 0x93, 0xf0, 1);
    demodWriteReg(1, 0x94, 0x0f, 1);

    // disable AGC (en_dagc, bit 0) (this seems to have no effect)
    demodWriteReg(1, 0x11, 0x00, 1);

    // disable RF and IF AGC loop
    demodWriteReg(1, 0x04, 0x00, 1);

    // disable PID filter (enable_PID = 0)
    demodWriteReg(0, 0x61, 0x60, 1);

    // opt_adc_iq = 0, default ADC_I/ADC_Q datapath
    demodWriteReg(0, 0x06, 0x80, 1);

    // Enable Zero-IF mode (en_bbin bit), DC cancellation (en_dc_est),
    // IQ estimation/compensation (en_iq_comp, en_iq_est)
    demodWriteReg(1, 0xb1, 0x1b, 1);

    // disable 4.096 MHz clock output on pin TP_CK0
    demodWriteReg(0, 0x0d, 0x83, 1);
  }

  /// rtlsdr_deinit_baseband
  int deinitBaseband() {
    int r = 0;

    if (tuner != null && tuner!.exit != null) {
      setI2cRepeater(1);
      r = tuner!.exit!(this); // deinitialize tuner
      setI2cRepeater(0);
    }

    // poweroff demodulator and ADCs
    writeReg(Blocks.sysb, SysReg.demodCtl, 0x20, 1);

    return r;
  }

  /// rtlsdr_set_if_freq (static in C)
  int _setIfFreq(int freq) {
    int ifFreq;
    int tmp;
    int r;

    freq &= 0xffffffff;

    // read corrected clock value
    final x = getXtalFreq();
    if (x.r != 0) return -2;
    final rtlXtal = x.rtlFreq;

    // int32_t if_freq = double
    ifFreq = (((freq * _twoPow(22)) / rtlXtal) * (-1)).truncate();

    tmp = (ifFreq >> 16) & 0x3f;
    r = demodWriteReg(1, 0x19, tmp, 1);
    tmp = (ifFreq >> 8) & 0xff;
    r |= demodWriteReg(1, 0x1a, tmp, 1);
    tmp = ifFreq & 0xff;
    r |= demodWriteReg(1, 0x1b, tmp, 1);

    return r;
  }

  /// rtlsdr_set_sample_freq_correction
  int setSampleFreqCorrection(int ppm) {
    int r = 0;
    int tmp;
    // int16_t offs = ppm * (-1) * TWO_POW(24) / 1000000;
    int offs = ((ppm * (-1)) * _twoPow(24) / 1000000).truncate();
    offs = (offs & 0xffff).toSigned(16);

    tmp = offs & 0xff;
    r |= demodWriteReg(1, 0x3f, tmp, 1);
    tmp = (offs >> 8) & 0x3f;
    r |= demodWriteReg(1, 0x3e, tmp, 1);

    return r;
  }

  // ------------------------------------------------------------------
  // public API (rtl-sdr.h)
  // ------------------------------------------------------------------

  /// rtlsdr_set_xtal_freq
  int setXtalFreq(int rtlFreq, int tunerFreq) {
    int r = 0;
    rtlFreq &= 0xffffffff;
    tunerFreq &= 0xffffffff;

    if (rtlFreq > 0 && (rtlFreq < minRtlXtalFreq || rtlFreq > maxRtlXtalFreq)) {
      return -2;
    }

    if (rtlFreq > 0 && rtlXtal != rtlFreq) {
      rtlXtal = rtlFreq;

      // update xtal-dependent settings
      if (rate != 0) r = setSampleRate(rate);
    }

    if (tunXtal != tunerFreq) {
      if (0 == tunerFreq) {
        tunXtal = rtlXtal;
      } else {
        tunXtal = tunerFreq;
      }

      // read corrected clock value into e4k and r82xx structure
      r82xxC.xtal = getXtalFreq().tunerFreq;

      // update xtal-dependent settings
      if (freq != 0) r = setCenterFreq(freq);
    }

    return r;
  }

  /// rtlsdr_get_xtal_freq
  ({int r, int rtlFreq, int tunerFreq}) getXtalFreq() {
    // #define APPLY_PPM_CORR(val,ppm) (((val) * (1.0 + (ppm) / 1e6)))
    double applyPpmCorr(int val, int ppm) => val * (1.0 + ppm / 1e6);

    return (
      r: 0,
      rtlFreq: _u32(applyPpmCorr(rtlXtal, corr)),
      tunerFreq: _u32(applyPpmCorr(tunXtal, corr)),
    );
  }

  /// rtlsdr_get_usb_strings. A string is only fetched when requested (the C
  /// function skips NULL output buffers); unrequested strings are ''.
  ({int r, String manufact, String product, String serial}) getUsbStrings(
      {bool manufact = true, bool product = true, bool serial = true}) {
    final dd = devh.deviceDescriptor;

    String str(int index) {
      try {
        return devh.getStringDescriptorAscii(index) ?? '';
      } on UsbException {
        return '';
      }
    }

    final m = manufact ? str(dd.iManufacturer) : '';
    final p = product ? str(dd.iProduct) : '';
    final s = serial ? str(dd.iSerialNumber) : '';
    return (r: 0, manufact: m, product: p, serial: s);
  }

  /// rtlsdr_write_eeprom
  int writeEeprom(Uint8List data, int offset, int len) {
    int r = 0;
    int i;
    final cmd = Uint8List(2);

    if ((len + offset) > 256) return -2;

    for (i = 0; i < len; i++) {
      cmd[0] = i + offset;
      r = writeArray(Blocks.iicb, eepromAddr, cmd, 1);
      r = readArray(Blocks.iicb, eepromAddr, Uint8List.sublistView(cmd, 1), 1);

      // only write the byte if it differs
      if (cmd[1] == data[i]) continue;

      cmd[1] = data[i];
      r = writeArray(Blocks.iicb, eepromAddr, cmd, 2);
      if (r != cmd.length) return -3;

      // for some EEPROMs (e.g. ATC 240LC02) we need a delay
      // between write operations, otherwise they will fail
      sleep(const Duration(milliseconds: 5));
    }

    return 0;
  }

  /// rtlsdr_read_eeprom
  int readEeprom(Uint8List data, int offset, int len) {
    int r = 0;
    int i;

    if ((len + offset) > 256) return -2;

    r = writeArray(
        Blocks.iicb, eepromAddr, Uint8List.fromList([offset & 0xff]), 1);
    if (r < 0) return -3;

    for (i = 0; i < len; i++) {
      r = readArray(
          Blocks.iicb, eepromAddr, Uint8List.sublistView(data, i), 1);

      if (r < 0) return -3;
    }

    return r;
  }

  /// rtlsdr_set_center_freq
  int setCenterFreq(int freq) {
    int r = -1;
    freq &= 0xffffffff;

    if (tuner == null) return -1;

    if (directSampling != 0) {
      r = _setIfFreq(freq);
    } else if (tuner != null && tuner!.setFreq != null) {
      setI2cRepeater(1);
      r = tuner!.setFreq!(this, (freq - offsFreq) & 0xffffffff);
      setI2cRepeater(0);
    }

    if (r == 0) {
      this.freq = freq;
    } else {
      this.freq = 0;
    }

    return r;
  }

  /// rtlsdr_get_center_freq
  int getCenterFreq() => freq;

  /// rtlsdr_set_freq_correction
  int setFreqCorrection(int ppm) {
    int r = 0;

    if (corr == ppm) return -2;

    corr = ppm;

    r |= setSampleFreqCorrection(ppm);

    // read corrected clock value into e4k and r82xx structure
    r82xxC.xtal = getXtalFreq().tunerFreq;

    if (freq != 0) {
      // retune to apply new correction value
      r |= setCenterFreq(freq);
    }

    return r;
  }

  /// rtlsdr_get_freq_correction
  int getFreqCorrection() => corr;

  /// rtlsdr_get_tuner_type
  int getTunerType() => tunerType;

  /// rtlsdr_get_tuner_gains: all gain values are expressed in tenths of a dB.
  /// (C returns the count and fills a caller buffer; here the list is returned.)
  List<int> getTunerGains() {
    const e4kGains = [
      -10, 15, 40, 65, 90, 115, 140, 165, 190, 215, 240, 290, 340, 420 //
    ];
    const fc0012Gains = [-99, -40, 71, 179, 192];
    const fc0013Gains = [
      -99, -73, -65, -63, -60, -58, -54, 58, 61, 63, 65, 67, 68, 70, 71, 179,
      181, 182, 184, 186, 188, 191, 197 //
    ];
    const fc2580Gains = [0 /* no gain values */];
    const r82xxGains = [
      0, 9, 14, 27, 37, 77, 87, 125, 144, 157, 166, 197, 207, 229, 254, 280,
      297, 328, 338, 364, 372, 386, 402, 421, 434, 439, 445, 480, 496 //
    ];
    const unknownGains = [0 /* no gain values */];

    switch (tunerType) {
      case RtlSdrTuner.e4000:
        return List.of(e4kGains);
      case RtlSdrTuner.fc0012:
        return List.of(fc0012Gains);
      case RtlSdrTuner.fc0013:
        return List.of(fc0013Gains);
      case RtlSdrTuner.fc2580:
        return List.of(fc2580Gains);
      case RtlSdrTuner.r820t:
      case RtlSdrTuner.r828d:
        return List.of(r82xxGains);
      default:
        return List.of(unknownGains);
    }
  }

  /// rtlsdr_set_tuner_bandwidth
  int setTunerBandwidth(int bw) {
    int r = 0;
    bw &= 0xffffffff;

    if (tuner == null) return -1;

    if (tuner!.setBw != null) {
      setI2cRepeater(1);
      r = tuner!.setBw!(this, bw > 0 ? bw : rate);
      setI2cRepeater(0);
      if (r != 0) return r;
      this.bw = bw;
    }
    return r;
  }

  /// rtlsdr_set_tuner_gain
  int setTunerGain(int gain) {
    int r = 0;

    if (tuner == null) return -1;

    if (tuner!.setGain != null) {
      setI2cRepeater(1);
      r = tuner!.setGain!(this, gain);
      setI2cRepeater(0);
    }

    if (r == 0) {
      this.gain = gain;
    } else {
      this.gain = 0;
    }

    return r;
  }

  /// rtlsdr_get_tuner_gain
  int getTunerGain() => gain;

  /// rtlsdr_set_tuner_if_gain
  int setTunerIfGain(int stage, int gain) {
    int r = 0;

    if (tuner == null) return -1;

    if (tuner!.setIfGain != null) {
      setI2cRepeater(1);
      r = tuner!.setIfGain!(this, stage, gain);
      setI2cRepeater(0);
    }

    return r;
  }

  /// rtlsdr_set_tuner_gain_mode
  int setTunerGainMode(int mode) {
    int r = 0;

    if (tuner == null) return -1;

    if (tuner!.setGainMode != null) {
      setI2cRepeater(1);
      r = tuner!.setGainMode!(this, mode);
      setI2cRepeater(0);
    }

    return r;
  }

  /// rtlsdr_set_sample_rate
  int setSampleRate(int sampRate) {
    int r = 0;
    int tmp;
    int rsampRatio, realRsampRatio;
    double realRate;
    sampRate &= 0xffffffff;

    // check if the rate is supported by the resampler
    if ((sampRate <= 225000) ||
        (sampRate > 3200000) ||
        ((sampRate > 300000) && (sampRate <= 900000))) {
      rtlsdrLog('Invalid sample rate: $sampRate Hz');
      return -Errno.einval;
    }

    rsampRatio = _u32((rtlXtal * _twoPow(22)) / sampRate);
    rsampRatio &= 0x0ffffffc;

    realRsampRatio = rsampRatio | ((rsampRatio & 0x08000000) << 1);
    realRate = (rtlXtal * _twoPow(22)) / realRsampRatio;

    if (sampRate.toDouble() != realRate) {
      rtlsdrLog('Exact sample rate is: ${realRate.toStringAsFixed(6)} Hz');
    }

    rate = _u32(realRate);

    if (tuner != null && tuner!.setBw != null) {
      setI2cRepeater(1);
      tuner!.setBw!(this, bw > 0 ? bw : rate);
      setI2cRepeater(0);
    }

    tmp = (rsampRatio >> 16) & 0xffff;
    r |= demodWriteReg(1, 0x9f, tmp, 2);
    tmp = rsampRatio & 0xffff;
    r |= demodWriteReg(1, 0xa1, tmp, 2);

    r |= setSampleFreqCorrection(corr);

    // reset demod (bit 3, soft_rst)
    r |= demodWriteReg(1, 0x01, 0x14, 1);
    r |= demodWriteReg(1, 0x01, 0x10, 1);

    // recalculate offset frequency if offset tuning is enabled
    if (offsFreq != 0) setOffsetTuning(1);

    return r;
  }

  /// rtlsdr_get_sample_rate
  int getSampleRate() => rate;

  /// rtlsdr_set_testmode
  int setTestmode(int on) => demodWriteReg(0, 0x19, on != 0 ? 0x03 : 0x05, 1);

  /// rtlsdr_set_agc_mode
  int setAgcMode(int on) => demodWriteReg(0, 0x19, on != 0 ? 0x25 : 0x05, 1);

  /// rtlsdr_set_direct_sampling
  int setDirectSampling(int on) {
    int r = 0;

    if (on != 0) {
      if (tuner != null && tuner!.exit != null) {
        setI2cRepeater(1);
        r = tuner!.exit!(this);
        setI2cRepeater(0);
      }

      // disable Zero-IF mode
      r |= demodWriteReg(1, 0xb1, 0x1a, 1);

      // disable spectrum inversion
      r |= demodWriteReg(1, 0x15, 0x00, 1);

      // only enable In-phase ADC input
      r |= demodWriteReg(0, 0x08, 0x4d, 1);

      // swap I and Q ADC, this allows to select between two inputs
      r |= demodWriteReg(0, 0x06, (on > 1) ? 0x90 : 0x80, 1);

      rtlsdrLog('Enabled direct sampling mode, input $on');
      directSampling = on;
    } else {
      if (tuner != null && tuner!.init != null) {
        setI2cRepeater(1);
        r |= tuner!.init!(this);
        setI2cRepeater(0);
      }

      if ((tunerType == RtlSdrTuner.r820t) || (tunerType == RtlSdrTuner.r828d)) {
        r |= _setIfFreq(r82xxIfFreq);

        // enable spectrum inversion
        r |= demodWriteReg(1, 0x15, 0x01, 1);
      } else {
        r |= _setIfFreq(0);

        // enable In-phase + Quadrature ADC input
        r |= demodWriteReg(0, 0x08, 0xcd, 1);

        // Enable Zero-IF mode
        r |= demodWriteReg(1, 0xb1, 0x1b, 1);
      }

      // opt_adc_iq = 0, default ADC_I/ADC_Q datapath
      r |= demodWriteReg(0, 0x06, 0x80, 1);

      rtlsdrLog('Disabled direct sampling mode');
      directSampling = 0;
    }

    r |= setCenterFreq(freq);

    return r;
  }

  /// rtlsdr_get_direct_sampling
  int getDirectSampling() => directSampling;

  /// rtlsdr_set_offset_tuning
  int setOffsetTuning(int on) {
    int r = 0;
    int bw;

    if ((tunerType == RtlSdrTuner.r820t) || (tunerType == RtlSdrTuner.r828d)) {
      return -2;
    }

    if (directSampling != 0) return -3;

    // based on keenerds 1/f noise measurements
    offsFreq = on != 0 ? (((rate ~/ 2) * 170 ~/ 100) & 0xffffffff) : 0;
    r |= _setIfFreq(offsFreq);

    if (tuner != null && tuner!.setBw != null) {
      setI2cRepeater(1);
      if (on != 0) {
        bw = 2 * offsFreq;
      } else if (this.bw > 0) {
        bw = this.bw;
      } else {
        bw = rate;
      }
      tuner!.setBw!(this, bw);
      setI2cRepeater(0);
    }

    if (freq > offsFreq) r |= setCenterFreq(freq);

    return r;
  }

  /// rtlsdr_get_offset_tuning
  int getOffsetTuning() => (offsFreq != 0) ? 1 : 0;

  /// rtlsdr_check_dongle_model: Returns true if the manufact_check and
  /// product_check strings match what is in the dongles EEPROM
  @override
  bool checkDongleModel(String manufactCheck, String productCheck) =>
      manufact == manufactCheck && product == productCheck;

  /// rtlsdr_open, minus libusb enumeration/libusb_open: takes an already
  /// opened [devh] (Android: UsbDeviceConnection fd). On failure the handle
  /// is closed, as rtlsdr_open does with the libusb handle.
  static ({int r, RtlSdrDev? dev}) open(UsbDeviceHandle devh) {
    int r;
    final dev = RtlSdrDev._(devh);
    int reg;

    dev.fir.setAll(0, firDefault);

    dev.devLost = 1;

    // libusb_kernel_driver_active / detach: not applicable (Android never
    // binds dvb_usb_rtl28xxu to the device for apps).

    try {
      devh.claimInterface(0);
    } on UsbException catch (e) {
      r = e.code;
      rtlsdrLog('usb_claim_interface error $r');
      devh.close();
      return (r: r, dev: null);
    }

    dev.rtlXtal = defRtlXtalFreq;

    // perform a dummy write, if it fails, reset the device
    if (dev.writeReg(Blocks.usbb, UsbReg.usbSysctl, 0x09, 1) < 0) {
      rtlsdrLog('Resetting device...');
      try {
        devh.resetDevice();
      } on UsbException catch (_) {}
    }

    dev.initBaseband();
    dev.devLost = 0;

    // Get device manufacturer and product id
    final strings = dev.getUsbStrings(serial: false);
    r = strings.r;
    dev.manufact = strings.manufact;
    dev.product = strings.product;

    // Probe tuners
    dev.setI2cRepeater(1);

    found:
    {
      reg = dev.i2cReadReg(e4kI2cAddr, e4kCheckAddr);
      if (reg == e4kCheckVal) {
        rtlsdrLog('Found Elonics E4000 tuner');
        dev.tunerType = RtlSdrTuner.e4000;
        break found;
      }

      reg = dev.i2cReadReg(fc0013I2cAddr, fc0013CheckAddr);
      if (reg == fc0013CheckVal) {
        rtlsdrLog('Found Fitipower FC0013 tuner');
        dev.tunerType = RtlSdrTuner.fc0013;
        break found;
      }

      reg = dev.i2cReadReg(r820tI2cAddr, r82xxCheckAddr);
      if (reg == r82xxCheckVal) {
        rtlsdrLog('Found Rafael Micro R820T tuner');

        if (dev.checkDongleModel('RTLSDRBlog', 'Blog V4L')) {
          rtlsdrLog('RTL-SDR Blog V4 Lite Detected');
        }

        dev.tunerType = RtlSdrTuner.r820t;

        break found;
      }

      reg = dev.i2cReadReg(r828dI2cAddr, r82xxCheckAddr);
      if (reg == r82xxCheckVal) {
        rtlsdrLog('Found Rafael Micro R828D tuner');

        if (dev.checkDongleModel('RTLSDRBlog', 'Blog V4')) {
          rtlsdrLog('RTL-SDR Blog V4 Detected');
        }

        dev.tunerType = RtlSdrTuner.r828d;
        break found;
      }

      // initialise GPIOs
      dev.setGpioOutput(4);

      // reset tuner before probing
      dev.setGpioBit(4, 1);
      dev.setGpioBit(4, 0);

      reg = dev.i2cReadReg(fc2580I2cAddr, fc2580CheckAddr);
      if ((reg & 0x7f) == fc2580CheckVal) {
        rtlsdrLog('Found FCI 2580 tuner');
        dev.tunerType = RtlSdrTuner.fc2580;
        break found;
      }

      reg = dev.i2cReadReg(fc0012I2cAddr, fc0012CheckAddr);
      if (reg == fc0012CheckVal) {
        rtlsdrLog('Found Fitipower FC0012 tuner');
        dev.setGpioOutput(6);
        dev.tunerType = RtlSdrTuner.fc0012;
        break found;
      }
    }

    // found:
    // use the rtl clock value by default
    dev.tunXtal = dev.rtlXtal;
    dev.tuner = tuners[dev.tunerType];

    switch (dev.tunerType) {
      case RtlSdrTuner.r828d:
      case RtlSdrTuner.r820t:
        if (dev.tunerType == RtlSdrTuner.r828d) {
          // If NOT an RTL-SDR Blog V4, set typical R828D 16 MHz freq.
          // Otherwise, keep at 28.8 MHz.
          if (!(dev.checkDongleModel('RTLSDRBlog', 'Blog V4'))) {
            dev.tunXtal = r828dXtalFreq;
          }
        }
        // fall-through
        // disable Zero-IF mode
        dev.demodWriteReg(1, 0xb1, 0x1a, 1);

        // only enable In-phase ADC input
        dev.demodWriteReg(0, 0x08, 0x4d, 1);

        // the R82XX use 3.57 MHz IF for the DVB-T 6 MHz mode, and
        // 4.57 MHz for the 8 MHz mode
        dev._setIfFreq(r82xxIfFreq);

        // enable spectrum inversion
        dev.demodWriteReg(1, 0x15, 0x01, 1);
      case RtlSdrTuner.unknown:
        rtlsdrLog('No supported tuner found');
        dev.setDirectSampling(1);
      case RtlSdrTuner.e4000:
      case RtlSdrTuner.fc0012:
      case RtlSdrTuner.fc0013:
      case RtlSdrTuner.fc2580:
        // Dart port: driver for this tuner not ported yet
        rtlsdrLog('Tuner ${RtlSdrTuner.names[dev.tunerType]} is not '
            'supported by the Dart port (unsupported tuner)');
      default:
        break;
    }

    if (dev.tuner!.init != null) r = dev.tuner!.init!(dev);

    dev.setI2cRepeater(0);

    return (r: 0, dev: dev);
  }

  /// rtlsdr_close. Waits (asynchronously, the C version sleeps) until a
  /// running [readAsync] has finished.
  Future<int> close() async {
    if (devLost == 0) {
      // block until all async operations have been completed (if any)
      while (RtlSdrAsyncStatus.inactive != asyncStatus) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      deinitBaseband();
    }

    try {
      devh.releaseInterface(0);
    } on UsbException catch (_) {}

    devh.close();

    return 0;
  }

  /// rtlsdr_reset_buffer
  int resetBuffer() {
    writeReg(Blocks.usbb, UsbReg.usbEpaCtl, 0x1002, 2);
    writeReg(Blocks.usbb, UsbReg.usbEpaCtl, 0x0000, 2);

    return 0;
  }

  /// rtlsdr_read_sync: returns (libusb result, n_read).
  ({int r, int nRead}) readSync(Uint8List buf, int len) {
    try {
      final n = devh.bulkTransfer(0x81, buf, len, timeoutMs: bulkTimeout);
      return (r: 0, nRead: n);
    } on UsbException catch (e) {
      return (r: e.code, nRead: 0);
    }
  }

  /// rtlsdr_wait_async
  Future<int> waitAsync(RtlSdrReadAsyncCb cb) => readAsync(cb, 0, 0);

  /// rtlsdr_read_async, built on [UsbDeviceHandle.openBulkIn]: the stream
  /// keeps [bufNum] transfers of [bufLen] bytes in flight on EP 0x81 (the
  /// reader isolate replaces the libusb event loop). Each block is handed to
  /// [cb] and released (resubmitted) when [cb] returns. Completes when
  /// [cancelAsync] is called or the device is lost.
  Future<int> readAsync(RtlSdrReadAsyncCb cb, int bufNum, int bufLen) async {
    int r = 0;

    if (RtlSdrAsyncStatus.inactive != asyncStatus) return -2;

    asyncStatus = RtlSdrAsyncStatus.running;
    asyncCancel = 0;

    this.cb = cb;

    if (bufNum > 0) {
      xferBufNum = bufNum;
    } else {
      xferBufNum = defaultBufNumber;
    }

    if (bufLen > 0 && bufLen % 512 == 0) {
      // len must be multiple of 512
      xferBufLen = bufLen;
    } else {
      xferBufLen = defaultBufLength;
    }

    final wake = Completer<void>();
    _asyncWake = wake;

    BulkInStream stream;
    try {
      stream = await devh.openBulkIn(0x81,
          numBuffers: xferBufNum, bufferLength: xferBufLen);
    } on UsbException catch (e) {
      rtlsdrLog('Failed to submit transfers (${e.code})\n'
          'Please increase your allowed usbfs buffer size with the '
          'following command:\n'
          'echo 0 > /sys/module/usbcore/parameters/usbfs_memory_mb');
      _asyncWake = null;
      asyncStatus = RtlSdrAsyncStatus.inactive;
      this.cb = null;
      return e.code;
    }
    _stream = stream;

    void wakeUp() {
      if (!wake.isCompleted) wake.complete();
    }

    // _libusb_callback equivalent
    final sub = stream.blocks.listen(
      (UsbBlock block) {
        try {
          if (RtlSdrAsyncStatus.running == asyncStatus) {
            this.cb?.call(block);
          }
        } finally {
          stream.release(block); // resubmit transfer
        }
        xferErrors = 0;
      },
      onError: (Object e) {
        if (e is UsbException && e.code == UsbError.noDevice) {
          devLost = 1;
        } else {
          xferErrors++;
          if (xferErrors >= xferBufNum) devLost = 1;
        }
        if (devLost != 0) {
          rtlsdrLog('cb transfer status: $e, canceling...');
          wakeUp();
        }
      },
      onDone: () {
        // reader ended without being canceled: treat as lost device
        if (RtlSdrAsyncStatus.running == asyncStatus) devLost = 1;
        wakeUp();
      },
    );

    if (asyncCancel != 0 || RtlSdrAsyncStatus.running != asyncStatus) {
      wakeUp();
    }
    await wake.future;

    // Check if device was lost due to transfer errors
    if (devLost != 0 && RtlSdrAsyncStatus.running == asyncStatus) {
      asyncStatus = RtlSdrAsyncStatus.canceling;
    }

    try {
      await stream.cancel();
    } on UsbException catch (e) {
      r = e.code;
    }
    await sub.cancel();

    _stream = null;
    _asyncWake = null;
    this.cb = null;
    asyncStatus = RtlSdrAsyncStatus.inactive;

    if (devLost != 0) return -1;

    return r;
  }

  /// Number of device buffers dropped by the reader because the consumer
  /// held all slots (no C equivalent; see BulkInStream.droppedBuffers).
  int get droppedBuffers => _stream?.droppedBuffers ?? 0;

  /// rtlsdr_cancel_async
  int cancelAsync() {
    // if streaming, try to cancel gracefully
    if (RtlSdrAsyncStatus.running == asyncStatus) {
      asyncStatus = RtlSdrAsyncStatus.canceling;
      asyncCancel = 1;
      final w = _asyncWake;
      if (w != null && !w.isCompleted) w.complete();
      return 0;
    }

    return -2;
  }

  /// rtlsdr_get_tuner_clock
  @override
  int getTunerClock() => getXtalFreq().tunerFreq;

  /// rtlsdr_i2c_write_fn
  @override
  int i2cWriteFn(int addr, Uint8List buf, int len) => i2cWrite(addr, buf, len);

  /// rtlsdr_i2c_read_fn
  @override
  int i2cReadFn(int addr, Uint8List buf, int len) => i2cRead(addr, buf, len);

  /// rtlsdr_set_bias_tee_gpio
  @override
  int setBiasTeeGpio(int gpio, int on) {
    setGpioOutput(gpio);
    setGpioBit(gpio, on);

    return 0;
  }

  /// rtlsdr_set_bias_tee
  int setBiasTee(int on) => setBiasTeeGpio(0, on);
}

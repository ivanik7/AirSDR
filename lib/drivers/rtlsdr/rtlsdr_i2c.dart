// Dart port of the tuner <-> RTL2832U glue interface.
//
// Source: ~/prj/ref/rtl-sdr/include/rtlsdr_i2c.h (osmocom rtl-sdr v2.0.3)
// and the implementations in src/librtlsdr.c:1436-1442, 2013-2052.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// (at your option) any later version. (Distributed in this app under GPL-3.0.)

import 'dart:typed_data';

/// Services a tuner driver needs from the RTL2832U (the `void *dev` the C
/// tuner drivers receive).
abstract interface class RtlSdrI2c {
  /// rtlsdr_check_dongle_model: true if the USB manufacturer/product strings
  /// equal [manufactCheck]/[productCheck].
  bool checkDongleModel(String manufactCheck, String productCheck);

  /// rtlsdr_set_bias_tee_gpio
  int setBiasTeeGpio(int gpio, int on);

  /// rtlsdr_get_tuner_clock: corrected tuner xtal in Hz (0 on error).
  int getTunerClock();

  /// rtlsdr_i2c_write_fn: returns bytes written or a negative error.
  int i2cWriteFn(int addr, Uint8List buf, int len);

  /// rtlsdr_i2c_read_fn: returns bytes read or a negative error.
  int i2cReadFn(int addr, Uint8List buf, int len);
}

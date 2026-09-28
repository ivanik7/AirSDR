// Dart port of librtlsdr public constants and logging hook.
//
// Source: ~/prj/ref/rtl-sdr/include/rtl-sdr.h (osmocom rtl-sdr v2.0.3, 797f814),
//         enum rtlsdr_tuner (lines 172-180).
//
// rtl-sdr, turns your Realtek RTL2832 based DVB dongle into a SDR receiver
// Copyright (C) 2012-2013 by Steve Markgraf <steve@steve-m.de>
// Copyright (C) 2012 by Dimitri Stolnikov <horiz0n@gmx.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// (at your option) any later version. (Distributed in this app under GPL-3.0.)

import 'dart:io' show stderr;

/// enum rtlsdr_tuner. Index order must match the tuner interface table
/// in librtlsdr.dart (`tuners`).
abstract final class RtlSdrTuner {
  static const unknown = 0; // RTLSDR_TUNER_UNKNOWN
  static const e4000 = 1; // RTLSDR_TUNER_E4000
  static const fc0012 = 2; // RTLSDR_TUNER_FC0012
  static const fc0013 = 3; // RTLSDR_TUNER_FC0013
  static const fc2580 = 4; // RTLSDR_TUNER_FC2580
  static const r820t = 5; // RTLSDR_TUNER_R820T
  static const r828d = 6; // RTLSDR_TUNER_R828D

  static const List<String> names = [
    'UNKNOWN',
    'E4000',
    'FC0012',
    'FC0013',
    'FC2580',
    'R820T',
    'R828D',
  ];
}

/// errno values returned (negated) by librtlsdr, e.g. -EINVAL from
/// rtlsdr_set_sample_rate.
abstract final class Errno {
  static const enomem = 12;
  static const einval = 22;
}

/// Replacement for the fprintf(stderr, ...) diagnostics of librtlsdr.
/// Override (e.g. to route into the app log, or silence in tests).
void Function(String message) rtlsdrLog = _defaultLog;

void _defaultLog(String message) => stderr.writeln(message);

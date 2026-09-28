// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ decoder_modules/radio/src/demod.h (lines 1-70) and radio_interface.h
// (lines 1-26) @8c9f5ee.
//
// `demod::Demodulator` is a block reading `ifChain.out` and writing a stereo stream. In the
// synchronous Dart graph it exposes [Demodulator.process] (complex IF in → stereo AF out,
// returns the output frame count) instead of `setInput/getOutput/start/stop`. The ImGui
// `showMenu()` is replaced by the declarative [Demodulator.options] / [Demodulator.setOption]
// pair, which persists the value to the config exactly like the menu handlers do.
import 'dart:typed_data';

import '../../core/config.dart';
import '../../signal_path/vfo_manager.dart';

/// demod.h:7-13.
enum DeemphasisMode { mode22us, mode50us, mode75us, none }

/// demod.h:15-20.
enum IFNRPreset { noaaApt, voice, narrowBand, broadcast }

/// demod.h:22-30.
enum SquelchMode { off, power, snr, ctcssMute, ctcssDecode, dcsMute, dcsDecode }

/// radio_interface.h:3-16.
abstract final class RadioIfaceCmd {
  static const int getMode = 0;
  static const int setMode = 1;
  static const int getBandwidth = 2;
  static const int setBandwidth = 3;
  static const int getSquelchMode = 4;
  static const int setSquelchMode = 5;
  static const int getSquelchLevel = 6;
  static const int setSquelchLevel = 7;
  static const int getCtcssTone = 8;
  static const int setCtcssTone = 9;
  static const int getHighpass = 10;
  static const int setHighpass = 11;
}

/// radio_interface.h:18-26 / RadioModule::DemodID (radio_module.h:176-186).
enum DemodID {
  nfm(0),
  wfm(1),
  am(2),
  dsb(3),
  usb(4),
  cw(5),
  lsb(6),
  raw(7);

  const DemodID(this.id);
  final int id;

  static DemodID? fromId(int id) {
    for (final d in DemodID.values) {
      if (d.id == id) return d;
    }
    return null;
  }
}

/// A demodulator-specific setting (replaces the ImGui widgets of `showMenu`).
class DemodOption {
  const DemodOption(this.key, this.value, {this.min, this.max});
  final String key;
  final Object value;
  final double? min;
  final double? max;
}

/// `demod::Demodulator` (demod.h:32-60).
abstract class Demodulator {
  /// demod.h:35 `init(name, config, input, bandwidth, audioSR)`; the input stream is implicit.
  void init(String name, ConfigManager config, double bandwidth, double audioSR);

  void start() {}
  void stop() {}

  void setBandwidth(double bandwidth);

  void afSampRateChanged(double newSR);

  /// Demodulates [count] complex IF samples from [input] into stereo frames in [output]
  /// (interleaved l/r, at [getAFSampleRate]); returns the frame count. [output] must hold
  /// 2·count floats. Replaces the block thread reading `ifChain.out`.
  int process(int count, Float32List input, Float32List output);

  String getName();
  double getIFSampleRate();
  double getAFSampleRate();
  double getDefaultBandwidth();
  double getMinBandwidth();
  double getMaxBandwidth();
  bool getBandwidthLocked();
  double getDefaultSnapInterval();
  VFOReference getVFOReference();
  bool getDeempAllowed();
  bool getPostProcEnabled();
  DeemphasisMode getDefaultDeemphasisMode();
  bool getFMIFNRAllowed();
  bool getNBAllowed();
  bool getHighPassAllowed();
  bool getSquelchAllowed();

  /// Current menu values (showMenu replacement).
  List<DemodOption> get options => const <DemodOption>[];

  /// Applies a menu change and saves it to the config, as the showMenu handlers do.
  /// Returns false for an unknown key.
  bool setOption(String key, Object value) => false;
}

/// Helpers shared by the demodulators for `config->conf[name][getName()]`.
Map<String, dynamic> demodConf(ConfigManager config, String name, String demodName) =>
    config.obj(demodName, config.obj(name));

double confDouble(Map<String, dynamic> c, String key, double def) {
  final v = c[key];
  return v is num ? v.toDouble() : def;
}

bool confBool(Map<String, dynamic> c, String key, bool def) {
  final v = c[key];
  return v is bool ? v : def;
}

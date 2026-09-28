// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ decoder_modules/radio/src/demodulators/raw.h (lines 1-71) @8c9f5ee.
// `ComplexToStereo` (I→L, Q→R); post-processing disabled, IF rate = audio rate.
import 'dart:typed_data';

import '../../../core/config.dart';
import '../../../dsp/dsp.dart' as dsp;
import '../../../signal_path/vfo_manager.dart';
import '../demod.dart';

class RAW extends Demodulator {
  late String name;
  double audioSampleRate = 48000;

  @override
  void init(String name, ConfigManager config, double bandwidth, double audioSR) {
    this.name = name;
    audioSampleRate = audioSR;
  }

  @override
  void setBandwidth(double bandwidth) {}

  @override
  void afSampRateChanged(double newSR) {
    audioSampleRate = newSR;
  }

  @override
  int process(int count, Float32List input, Float32List output) => dsp.complexToStereo(count, input, output);

  // ============= INFO =============

  @override
  String getName() => 'RAW';
  @override
  double getIFSampleRate() => audioSampleRate;
  @override
  double getAFSampleRate() => audioSampleRate;
  @override
  double getDefaultBandwidth() => audioSampleRate;
  @override
  double getMinBandwidth() => audioSampleRate;
  @override
  double getMaxBandwidth() => audioSampleRate;
  @override
  bool getBandwidthLocked() => true;
  @override
  double getDefaultSnapInterval() => 2500.0;
  @override
  VFOReference getVFOReference() => VFOReference.center;
  @override
  bool getDeempAllowed() => false;
  @override
  bool getPostProcEnabled() => false;
  @override
  DeemphasisMode getDefaultDeemphasisMode() => DeemphasisMode.none;
  @override
  bool getFMIFNRAllowed() => false;
  @override
  bool getNBAllowed() => true;
  @override
  bool getHighPassAllowed() => false;
  @override
  bool getSquelchAllowed() => false;
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Common body of SDR++ decoder_modules/radio/src/demodulators/{usb,lsb,dsb}.h (@8c9f5ee,
// lines 1-96 each). The three C++ files are identical except for the SSB mode, the name,
// the default/min bandwidth and the VFO reference; the Dart port factors that body here and
// keeps one file per demodulator (usb.dart, lsb.dart, dsb.dart) with the differences.
import 'dart:typed_data';

import '../../../core/config.dart';
import '../../../dsp/dsp.dart' as dsp;
import '../../../signal_path/vfo_manager.dart';
import '../demod.dart';

abstract class SSBDemodBase extends Demodulator {
  late String name;
  late ConfigManager _config;
  late dsp.SSB demod;

  double agcAttack = 50.0;
  double agcDecay = 5.0;

  /// `dsp::demod::SSB<stereo_t>::Mode` of this demodulator.
  dsp.SSBMode get ssbMode;

  @override
  void init(String name, ConfigManager config, double bandwidth, double audioSR) {
    this.name = name;
    _config = config;

    // Load config
    config.acquire();
    final c = demodConf(config, name, getName());
    agcAttack = confDouble(c, 'agcAttack', agcAttack);
    agcDecay = confDouble(c, 'agcDecay', agcDecay);
    config.release();

    // Define structure
    demod = dsp.SSB(dsp.SampleType.stereo, ssbMode, bandwidth, getIFSampleRate(), agcAttack / getIFSampleRate(),
        agcDecay / getIFSampleRate());
  }

  @override
  void setBandwidth(double bandwidth) => demod.setBandwidth(bandwidth);

  @override
  void afSampRateChanged(double newSR) {}

  @override
  int process(int count, Float32List input, Float32List output) => demod.process(count, input, output);

  @override
  List<DemodOption> get options => <DemodOption>[
        DemodOption('agcAttack', agcAttack, min: 1, max: 200),
        DemodOption('agcDecay', agcDecay, min: 1, max: 20),
      ];

  @override
  bool setOption(String key, Object value) {
    switch (key) {
      case 'agcAttack':
        agcAttack = (value as num).toDouble();
        demod.setAGCAttack(agcAttack / getIFSampleRate());
      case 'agcDecay':
        agcDecay = (value as num).toDouble();
        demod.setAGCDecay(agcDecay / getIFSampleRate());
      default:
        return false;
    }
    _config.acquire();
    demodConf(_config, name, getName())[key] = value;
    _config.release(true);
    return true;
  }

  // ============= INFO =============

  @override
  double getIFSampleRate() => 24000.0;
  @override
  double getAFSampleRate() => getIFSampleRate();
  @override
  double getMaxBandwidth() => getIFSampleRate() / 2.0;
  @override
  bool getBandwidthLocked() => false;
  @override
  double getDefaultSnapInterval() => 100.0;
  @override
  bool getDeempAllowed() => false;
  @override
  bool getPostProcEnabled() => true;
  @override
  DeemphasisMode getDefaultDeemphasisMode() => DeemphasisMode.none;
  @override
  bool getFMIFNRAllowed() => false;
  @override
  bool getNBAllowed() => true;
  @override
  bool getHighPassAllowed() => true;
  @override
  bool getSquelchAllowed() => true;
}

/// `demod::USB` (usb.h).
class USB extends SSBDemodBase {
  @override
  dsp.SSBMode get ssbMode => dsp.SSBMode.usb;
  @override
  String getName() => 'USB';
  @override
  double getDefaultBandwidth() => 2800.0;
  @override
  double getMinBandwidth() => 500.0;
  @override
  VFOReference getVFOReference() => VFOReference.lower;
}

/// `demod::LSB` (lsb.h).
class LSB extends SSBDemodBase {
  @override
  dsp.SSBMode get ssbMode => dsp.SSBMode.lsb;
  @override
  String getName() => 'LSB';
  @override
  double getDefaultBandwidth() => 2800.0;
  @override
  double getMinBandwidth() => 500.0;
  @override
  VFOReference getVFOReference() => VFOReference.upper;
}

/// `demod::DSB` (dsb.h).
class DSB extends SSBDemodBase {
  @override
  dsp.SSBMode get ssbMode => dsp.SSBMode.dsb;
  @override
  String getName() => 'DSB';
  @override
  double getDefaultBandwidth() => 4600.0;
  @override
  double getMinBandwidth() => 1000.0;
  @override
  VFOReference getVFOReference() => VFOReference.center;
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ decoder_modules/radio/src/demodulators/am.h (lines 1-103) @8c9f5ee.
import 'dart:typed_data';

import '../../../core/config.dart';
import '../../../dsp/dsp.dart' as dsp;
import '../../../signal_path/vfo_manager.dart';
import '../demod.dart';

class AM extends Demodulator {
  late String name;
  late ConfigManager _config;
  late dsp.AM demod;

  double agcAttack = 50.0;
  double agcDecay = 5.0;
  bool carrierAgc = false;

  @override
  void init(String name, ConfigManager config, double bandwidth, double audioSR) {
    this.name = name;
    _config = config;

    // Load config
    config.acquire();
    final c = demodConf(config, name, getName());
    agcAttack = confDouble(c, 'agcAttack', agcAttack);
    agcDecay = confDouble(c, 'agcDecay', agcDecay);
    carrierAgc = confBool(c, 'carrierAgc', carrierAgc);
    config.release();

    // Define structure
    demod = dsp.AM(dsp.SampleType.stereo, carrierAgc ? dsp.AGCMode.carrier : dsp.AGCMode.audio, bandwidth,
        agcAttack / getIFSampleRate(), agcDecay / getIFSampleRate(), 100.0 / getIFSampleRate(), getIFSampleRate());
  }

  @override
  void setBandwidth(double bandwidth) => demod.setBandwidth(bandwidth);

  @override
  void afSampRateChanged(double newSR) {}

  @override
  int process(int count, Float32List input, Float32List output) => demod.process(count, input, output);

  @override
  List<DemodOption> get options => <DemodOption>[
        DemodOption('carrierAgc', carrierAgc),
        DemodOption('agcAttack', agcAttack, min: 1, max: 200),
        DemodOption('agcDecay', agcDecay, min: 1, max: 20),
      ];

  @override
  bool setOption(String key, Object value) {
    switch (key) {
      case 'carrierAgc':
        carrierAgc = value as bool;
        demod.setAGCMode(carrierAgc ? dsp.AGCMode.carrier : dsp.AGCMode.audio);
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
  String getName() => 'AM';
  @override
  double getIFSampleRate() => 15000.0;
  @override
  double getAFSampleRate() => getIFSampleRate();
  @override
  double getDefaultBandwidth() => 10000.0;
  @override
  double getMinBandwidth() => 1000.0;
  @override
  double getMaxBandwidth() => getIFSampleRate();
  @override
  bool getBandwidthLocked() => false;
  @override
  double getDefaultSnapInterval() => 1000.0;
  @override
  VFOReference getVFOReference() => VFOReference.center;
  @override
  bool getDeempAllowed() => false;
  @override
  bool getPostProcEnabled() => true;
  @override
  DeemphasisMode getDefaultDeemphasisMode() => DeemphasisMode.none;
  @override
  bool getFMIFNRAllowed() => false;
  @override
  bool getNBAllowed() => false;
  @override
  bool getHighPassAllowed() => true;
  @override
  bool getSquelchAllowed() => true;
}

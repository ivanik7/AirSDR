// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ decoder_modules/radio/src/demodulators/nfm.h (lines 1-81) @8c9f5ee.
import 'dart:typed_data';

import '../../../core/config.dart';
import '../../../dsp/dsp.dart' as dsp;
import '../../../signal_path/vfo_manager.dart';
import '../demod.dart';

class NFM extends Demodulator {
  late String name;
  late ConfigManager _config;
  late dsp.FM demod;
  bool _lowPass = true;

  @override
  void init(String name, ConfigManager config, double bandwidth, double audioSR) {
    this.name = name;
    _config = config;

    // Load config
    _config.acquire();
    _lowPass = confBool(demodConf(config, name, getName()), 'lowPass', _lowPass);
    _config.release();

    // Define structure
    demod = dsp.FM(dsp.SampleType.stereo, getIFSampleRate(), bandwidth, _lowPass);
  }

  @override
  void setBandwidth(double bandwidth) {
    demod.setBandwidth(bandwidth);
  }

  @override
  void afSampRateChanged(double newSR) {}

  @override
  int process(int count, Float32List input, Float32List output) => demod.process(count, input, output);

  @override
  List<DemodOption> get options => <DemodOption>[DemodOption('lowPass', _lowPass)];

  @override
  bool setOption(String key, Object value) {
    if (key != 'lowPass') return false;
    _lowPass = value as bool;
    demod.setLowPass(_lowPass);
    _config.acquire();
    demodConf(_config, name, getName())['lowPass'] = _lowPass;
    _config.release(true);
    return true;
  }

  // ============= INFO =============

  @override
  String getName() => 'FM';
  @override
  double getIFSampleRate() => 50000.0;
  @override
  double getAFSampleRate() => getIFSampleRate();
  @override
  double getDefaultBandwidth() => 12500.0;
  @override
  double getMinBandwidth() => 1000.0;
  @override
  double getMaxBandwidth() => getIFSampleRate();
  @override
  bool getBandwidthLocked() => false;
  @override
  double getDefaultSnapInterval() => 2500.0;
  @override
  VFOReference getVFOReference() => VFOReference.center;
  @override
  bool getDeempAllowed() => true;
  @override
  bool getPostProcEnabled() => true;
  @override
  DeemphasisMode getDefaultDeemphasisMode() => DeemphasisMode.none;
  @override
  bool getFMIFNRAllowed() => true;
  @override
  bool getNBAllowed() => false;
  @override
  bool getHighPassAllowed() => true;
  @override
  bool getSquelchAllowed() => true;
}

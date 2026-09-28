// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ decoder_modules/radio/src/demodulators/cw.h (lines 1-110) @8c9f5ee.
import 'dart:typed_data';

import '../../../core/config.dart';
import '../../../dsp/dsp.dart' as dsp;
import '../../../signal_path/vfo_manager.dart';
import '../demod.dart';

class CW extends Demodulator {
  late String name;
  late ConfigManager _config;
  late dsp.CW demod;

  double agcAttack = 100.0;
  double agcDecay = 5.0;
  int tone = 800;

  @override
  void init(String name, ConfigManager config, double bandwidth, double audioSR) {
    this.name = name;
    _config = config;

    // Load config
    config.acquire();
    final c = demodConf(config, name, getName());
    agcAttack = confDouble(c, 'agcAttack', agcAttack);
    agcDecay = confDouble(c, 'agcDecay', agcDecay);
    tone = confDouble(c, 'tone', tone.toDouble()).round();
    config.release();

    // Define structure
    demod = dsp.CW(dsp.SampleType.stereo, tone.toDouble(), agcAttack / getIFSampleRate(), agcDecay / getIFSampleRate(),
        getIFSampleRate());
  }

  /// cw.h: the VFO LPF does the filtering.
  @override
  void setBandwidth(double bandwidth) {}

  @override
  void afSampRateChanged(double newSR) {}

  @override
  int process(int count, Float32List input, Float32List output) => demod.process(count, input, output);

  @override
  List<DemodOption> get options => <DemodOption>[
        DemodOption('agcAttack', agcAttack, min: 1, max: 200),
        DemodOption('agcDecay', agcDecay, min: 1, max: 20),
        DemodOption('tone', tone, min: 250, max: 1250),
      ];

  @override
  bool setOption(String key, Object value) {
    Object saved = value;
    switch (key) {
      case 'agcAttack':
        agcAttack = (value as num).toDouble();
        demod.setAGCAttack(agcAttack / getIFSampleRate());
      case 'agcDecay':
        agcDecay = (value as num).toDouble();
        demod.setAGCDecay(agcDecay / getIFSampleRate());
      case 'tone':
        tone = (value as num).round().clamp(250, 1250);
        demod.setTone(tone.toDouble());
        saved = tone;
      default:
        return false;
    }
    _config.acquire();
    demodConf(_config, name, getName())[key] = saved;
    _config.release(true);
    return true;
  }

  // ============= INFO =============

  @override
  String getName() => 'CW';
  @override
  double getIFSampleRate() => 3000.0;
  @override
  double getAFSampleRate() => getIFSampleRate();
  @override
  double getDefaultBandwidth() => 200.0;
  @override
  double getMinBandwidth() => 50.0;
  @override
  double getMaxBandwidth() => 500.0;
  @override
  bool getBandwidthLocked() => false;
  @override
  double getDefaultSnapInterval() => 10.0;
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
  bool getHighPassAllowed() => false;
  @override
  bool getSquelchAllowed() => false;
}

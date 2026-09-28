// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ decoder_modules/radio/src/demodulators/wfm.h (lines 1-378) @8c9f5ee.
//
// DSP: `BroadcastFM(dev = bw/2, 250 kHz, stereo, lowPass, rds)`. The RDS decoder
// (rds_demod.h, rds.cpp) and its ImGui symbol diagram are NOT ported (docs/02 §6.4 item 45):
// the `rds*` config keys are loaded/saved, and `rds = true` enables the BroadcastFM RDS
// baseband output (`BroadcastFM.rdsOutBuf`), but nothing decodes it yet.
import 'dart:typed_data';

import '../../../core/config.dart';
import '../../../dsp/dsp.dart' as dsp;
import '../../../signal_path/vfo_manager.dart';
import '../demod.dart';

class WFM extends Demodulator {
  late String name;
  late ConfigManager _config;
  late dsp.BroadcastFM demod;

  bool _stereo = false;
  bool _lowPass = true;
  bool _rds = false;
  bool _rdsInfo = false;
  bool _rdsIncremental = true;
  String _rdsRegion = 'eu';

  bool get stereo => _stereo;

  @override
  void init(String name, ConfigManager config, double bandwidth, double audioSR) {
    this.name = name;
    _config = config;

    // Load config
    _config.acquire();
    final c = demodConf(config, name, getName());
    _stereo = confBool(c, 'stereo', _stereo);
    _lowPass = confBool(c, 'lowPass', _lowPass);
    _rds = confBool(c, 'rds', _rds);
    _rdsIncremental = confBool(c, 'rdsIncremental', _rdsIncremental);
    _rdsInfo = confBool(c, 'rdsInfo', _rdsInfo);
    final region = c['rdsRegion'];
    if (region == 'eu' || region == 'na') _rdsRegion = region as String;
    _config.release();

    // Init DSP
    demod = dsp.BroadcastFM(bandwidth / 2.0, getIFSampleRate(), stereo: _stereo, lowPass: _lowPass, rdsOut: _rds);
  }

  @override
  void setBandwidth(double bandwidth) {
    demod.setDeviation(bandwidth / 2.0);
  }

  @override
  void afSampRateChanged(double newSR) {}

  @override
  int process(int count, Float32List input, Float32List output) => demod.process(count, input, output);

  /// wfm.h:287.
  void setStereo(bool stereo) {
    _stereo = stereo;
    demod.setStereo(_stereo);
  }

  @override
  List<DemodOption> get options => <DemodOption>[
        DemodOption('stereo', _stereo),
        DemodOption('lowPass', _lowPass),
        DemodOption('rds', _rds),
        DemodOption('rdsIncremental', _rdsIncremental),
        DemodOption('rdsInfo', _rdsInfo),
        DemodOption('rdsRegion', _rdsRegion),
      ];

  @override
  bool setOption(String key, Object value) {
    switch (key) {
      case 'lowPass':
        _lowPass = value as bool;
        demod.setLowPass(_lowPass);
      case 'stereo':
        setStereo(value as bool);
      case 'rds':
        _rds = value as bool;
        demod.setRDSOut(_rds);
      case 'rdsIncremental':
        _rdsIncremental = value as bool;
      case 'rdsInfo':
        _rdsInfo = value as bool;
      case 'rdsRegion':
        if (value != 'eu' && value != 'na') return false;
        _rdsRegion = value as String;
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
  String getName() => 'WFM';
  @override
  double getIFSampleRate() => 250000.0;
  @override
  double getAFSampleRate() => getIFSampleRate();
  @override
  double getDefaultBandwidth() => 150000.0;
  @override
  double getMinBandwidth() => 50000.0;
  @override
  double getMaxBandwidth() => getIFSampleRate();
  @override
  bool getBandwidthLocked() => false;
  @override
  double getDefaultSnapInterval() => 100000.0;
  @override
  VFOReference getVFOReference() => VFOReference.center;
  @override
  bool getDeempAllowed() => true;
  @override
  bool getPostProcEnabled() => true;
  @override
  DeemphasisMode getDefaultDeemphasisMode() => DeemphasisMode.mode50us;
  @override
  bool getFMIFNRAllowed() => true;
  @override
  bool getNBAllowed() => false;
  @override
  bool getHighPassAllowed() => true;
  @override
  bool getSquelchAllowed() => true;
}

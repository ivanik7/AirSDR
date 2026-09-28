// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ decoder_modules/radio/src/radio_module.h (lines 1-914, minus ImGui) and
// main.cpp (lines 1-28) @8c9f5ee.
//
// Wiring (radio_module.h:40-135, docs/02 §4.2):
//   VFO (RxVFO) ─► ifChain [NoiseBlanker, PowerSquelch, (FMIF)] ─► Demodulator (stereo AF)
//               ─► afChain [(CTCSS), RationalResampler AF→48k, HPF 300 Hz, Deemphasis]
//               ─► SinkManager::Stream (splitter, volume², sink)
//
// The graph runs synchronously: the VFO output handler calls [RadioModule.processIF] for
// every VFO block. The chains are run in place; buffers grow on demand, then stay.
//
// Not ported yet (DSP blocks missing in lib/sdrpp/dsp, see STATUS-sigpath.md):
//  * FMIF (`dsp::noise_reduction::FMIF`, the FM IF noise reduction): the enable flag and the
//    preset are stored and saved exactly as in C++, but no block is inserted in the IF chain.
//  * CTCSSSquelch: SQUELCH_MODE_CTCSS_MUTE/_DECODE are accepted and saved but pass audio
//    through unmodified.
//  * RDS decoding (see demodulators/wfm.dart).
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/config.dart';
import '../../core/core.dart';
import '../../core/event.dart';
import '../../core/module.dart';
import '../../dsp/dsp.dart' as dsp;
import '../../signal_path/sink_manager.dart';
import '../../signal_path/vfo_manager.dart';
import 'demod.dart';
import 'demodulators/am.dart';
import 'demodulators/cw.dart';
import 'demodulators/nfm.dart';
import 'demodulators/raw.dart';
import 'demodulators/ssb_common.dart';
import 'demodulators/wfm.dart';

export 'demod.dart';

/// radio_module.h:25-29.
const Map<DeemphasisMode, double> deempTaus = <DeemphasisMode, double>{
  DeemphasisMode.mode22us: 22e-6,
  DeemphasisMode.mode50us: 50e-6,
  DeemphasisMode.mode75us: 75e-6,
};

/// radio_module.h:31-36.
const Map<IFNRPreset, int> ifnrTaps = <IFNRPreset, int>{
  IFNRPreset.noaaApt: 9,
  IFNRPreset.voice: 15,
  IFNRPreset.narrowBand: 31,
  IFNRPreset.broadcast: 32,
};

/// `OptionList` keys of radio_module.h:44-59 (key string ↔ enum).
const Map<String, DeemphasisMode> deempModeKeys = <String, DeemphasisMode>{
  'None': DeemphasisMode.none,
  '22us': DeemphasisMode.mode22us,
  '50us': DeemphasisMode.mode50us,
  '75us': DeemphasisMode.mode75us,
};
const Map<String, IFNRPreset> ifnrPresetKeys = <String, IFNRPreset>{
  'NOAA APT': IFNRPreset.noaaApt,
  'Voice': IFNRPreset.voice,
  'Narrow Band': IFNRPreset.narrowBand,
};
const Map<String, SquelchMode> squelchModeKeys = <String, SquelchMode>{
  'off': SquelchMode.off,
  'power': SquelchMode.power,
  'ctcss_mute': SquelchMode.ctcssMute,
  'ctcss_decode': SquelchMode.ctcssDecode,
};

String _keyOf<T>(Map<String, T> m, T v) => m.entries.firstWhere((e) => e.value == v, orElse: () => m.entries.first).key;

class RadioModule extends ModuleInstance {
  static const double minNb = 1.0;
  static const double maxNb = 10.0;
  static const double minSquelch = -100.0;
  static const double maxSquelch = 0.0;

  /// radio_module.h:40-135.
  RadioModule(this.name, this.core, this.config) {
    // Initialize the config if it doesn't exist
    bool created = false;
    config.acquire();
    if (config.conf[name] is! Map<String, dynamic>) {
      config.conf[name] = <String, dynamic>{'selectedDemodId': 1};
      created = true;
    }
    final sel = (config.conf[name] as Map<String, dynamic>)['selectedDemodId'];
    selectedDemodID = sel is num ? sel.toInt() : 1;
    config.release(created);

    // Initialize the VFO
    vfo = core.sigpath.vfoManager.createVFO(name, VFOReference.center, 0, 200000, 200000, 50000, 200000, false);
    vfo!.output = processIF;

    // Initialize IF DSP chain
    nb = dsp.NoiseBlanker(500.0 / 24000.0, 10.0);
    powerSquelch = dsp.PowerSquelch(minSquelch);
    ifChain.addBlock(nb, false);
    ifChain.addBlock(powerSquelch, false);

    // Initialize audio DSP chain
    resamp = dsp.RationalResampler(dsp.SampleType.stereo, 250000.0, 48000.0);
    hpTaps = dsp.highPass(300.0, 100.0, 48000.0);
    hpf = dsp.FIR(dsp.SampleType.stereo, hpTaps);
    deemp = dsp.Deemphasis(dsp.SampleType.stereo, 50e-6, 48000.0);
    afChain.addBlock(resamp, true);
    afChain.addBlock(hpf, false);
    afChain.addBlock(deemp, false);

    // Initialize the sink
    stream = SinkStream(EventHandler<double>(setAudioSampleRate), audioSampleRate);
    core.sigpath.sinkManager.registerStream(name, stream);

    // Select the demodulator
    selectDemodByID(DemodID.fromId(selectedDemodID) ?? DemodID.wfm);

    // Start stream, the rest was started when selecting the demodulator
    stream.start();

    // Register the module interface
    core.modComManager.registerInterface('radio', name, _moduleInterfaceHandler);
  }

  final String name;
  final Core core;

  /// Module-global `ConfigManager config` (radio_config.json).
  final ConfigManager config;

  VFO? vfo;

  // IF chain
  final dsp.Chain ifChain = dsp.Chain(dsp.SampleType.complex);
  late final dsp.NoiseBlanker nb;
  late final dsp.PowerSquelch powerSquelch;

  // Audio chain
  final dsp.Chain afChain = dsp.Chain(dsp.SampleType.stereo);
  late final dsp.RationalResampler resamp;
  late dsp.Taps hpTaps;
  late final dsp.FIR hpf;
  late final dsp.Deemphasis deemp;

  late final SinkStream stream;

  Demodulator? selectedDemod;

  double audioSampleRate = 48000.0;
  double minBandwidth = 0;
  double maxBandwidth = 0;
  double bandwidth = 0;
  bool bandwidthLocked = false;
  double snapInterval = 0;
  int selectedDemodID = 1;
  bool postProcEnabled = false;

  SquelchMode squelchMode = SquelchMode.off;
  double squelchLevel = minSquelch;
  int ctcssToneX10 = 670;
  bool squelchAllowed = false;

  bool highPass = false;
  bool highPassAllowed = false;

  DeemphasisMode deempMode = DeemphasisMode.none;
  bool deempAllowed = false;

  bool fmIFNRAllowed = false;
  bool fmIFNREnabled = false;
  IFNRPreset fmIFPreset = IFNRPreset.voice;

  bool nbAllowed = false;
  bool nbEnabled = false;
  double nbLevel = 10.0;

  bool enabled = true;

  /// Audio frames produced (diagnostics).
  int audioFrames = 0;

  // Working buffer for demod output + AF chain (stereo, in place)
  Float32List _afBuf = Float32List(0);

  // ---------------------------------------------------------------------------
  // ModuleManager::Instance
  // ---------------------------------------------------------------------------

  @override
  void postInit() {}

  /// radio_module.h:149-159.
  @override
  void enable() {
    enabled = true;
    if (vfo == null) {
      vfo = core.sigpath.vfoManager.createVFO(name, VFOReference.center, 0, 200000, 200000, 50000, 200000, false);
      vfo!.output = processIF;
    }
    selectDemodByID(DemodID.fromId(selectedDemodID) ?? DemodID.wfm);
  }

  /// radio_module.h:161-168.
  @override
  void disable() {
    enabled = false;
    selectedDemod?.stop();
    final v = vfo;
    if (v != null) core.sigpath.vfoManager.deleteVFO(v);
    vfo = null;
  }

  @override
  bool isEnabled() => enabled;

  /// radio_module.h:137-145 (destructor).
  @override
  void dispose() {
    core.modComManager.unregisterInterface(name);
    stream.stop();
    if (enabled) {
      disable();
    }
    core.sigpath.sinkManager.unregisterStream(name);
  }

  // ---------------------------------------------------------------------------
  // DSP (replaces the block threads)
  // ---------------------------------------------------------------------------

  /// VFO output handler: IF chain → demod → AF chain → sink stream. [iq] is modified in place.
  void processIF(Float32List iq, int count) {
    final demod = selectedDemod;
    if (!enabled || demod == null || count <= 0) return;
    final n = ifChain.process(count, iq);
    if (n <= 0) return;
    final int need = 2 * math.max<int>(n, resamp.maxOutput(n));
    if (_afBuf.length < need) _afBuf = dsp.growBuffer(_afBuf, need, 0);
    int a = demod.process(n, iq, _afBuf);
    a = afChain.process(a, _afBuf);
    audioFrames += a;
    stream.process(_afBuf, a);
  }

  // ---------------------------------------------------------------------------
  // Demodulator selection (radio_module.h:365-562)
  // ---------------------------------------------------------------------------

  /// radio_module.h:365-399.
  Demodulator? instantiateDemod(DemodID id) {
    final Demodulator demod;
    switch (id) {
      case DemodID.nfm:
        demod = NFM();
      case DemodID.wfm:
        demod = WFM();
      case DemodID.am:
        demod = AM();
      case DemodID.dsb:
        demod = DSB();
      case DemodID.usb:
        demod = USB();
      case DemodID.cw:
        demod = CW();
      case DemodID.lsb:
        demod = LSB();
      case DemodID.raw:
        demod = RAW();
    }

    // RAW's info getters depend on the audio SR set by init(); give it the current one.
    demod.afSampRateChanged(stream.getSampleRate());

    // Default config
    double bw = demod.getDefaultBandwidth();
    config.acquire();
    final modConf = config.obj(name);
    if (!modConf.containsKey(demod.getName())) {
      modConf[demod.getName()] = <String, dynamic>{
        'bandwidth': bw,
        'snapInterval': demod.getDefaultSnapInterval(),
        'squelchLevel': minSquelch,
        'squelchEnabled': false,
      };
      config.release(true);
    } else {
      config.release();
    }
    bw = bw.clamp(demod.getMinBandwidth(), demod.getMaxBandwidth()).toDouble();

    // Initialize
    demod.init(name, config, bw, stream.getSampleRate());

    return demod;
  }

  /// radio_module.h:401-417.
  void selectDemodByID(DemodID id) {
    final demod = instantiateDemod(id);
    selectedDemodID = id.id;
    selectDemod(demod!);

    // Save config
    config.acquire();
    config.obj(name)['selectedDemodId'] = id.id;
    config.release(true);
  }

  /// radio_module.h:419-562.
  void selectDemod(Demodulator demod) {
    // Stop currently selected demodulator and select new
    selectedDemod?.stop();
    selectedDemod = demod;

    // Give the demodulator the most recent audio SR
    demod.afSampRateChanged(audioSampleRate);

    // Load config
    bandwidth = demod.getDefaultBandwidth();
    minBandwidth = demod.getMinBandwidth();
    maxBandwidth = demod.getMaxBandwidth();
    bandwidthLocked = demod.getBandwidthLocked();
    snapInterval = demod.getDefaultSnapInterval();
    deempAllowed = demod.getDeempAllowed();
    deempMode = demod.getDefaultDeemphasisMode();
    squelchMode = SquelchMode.off;
    squelchLevel = minSquelch;
    ctcssToneX10 = 670; // CTCSS_TONE_67Hz
    highPass = false;

    postProcEnabled = demod.getPostProcEnabled();
    fmIFNRAllowed = demod.getFMIFNRAllowed();
    fmIFNREnabled = false;
    fmIFPreset = IFNRPreset.voice;
    nbAllowed = demod.getNBAllowed();
    squelchAllowed = demod.getSquelchAllowed();
    highPassAllowed = demod.getHighPassAllowed();
    nbEnabled = false;
    nbLevel = 0.0;
    final ifSamplerate = demod.getIFSampleRate();

    config.acquire();
    final c = demodConf(config, name, demod.getName());
    if (c['bandwidth'] is num) {
      bandwidth = (c['bandwidth'] as num).toDouble();
      bandwidth = bandwidth.clamp(minBandwidth, maxBandwidth).toDouble();
    }
    if (c['snapInterval'] is num) {
      snapInterval = (c['snapInterval'] as num).toDouble();
    }
    final sqm = c['squelchMode'];
    if (sqm is String && squelchModeKeys.containsKey(sqm)) {
      squelchMode = squelchModeKeys[sqm]!;
    }
    if (c['squelchLevel'] is num) {
      squelchLevel = (c['squelchLevel'] as num).toDouble();
    }
    if (c['ctcssTone'] is num) {
      ctcssToneX10 = (c['ctcssTone'] as num).toInt();
    }
    if (c['highPass'] is bool) {
      highPass = c['highPass'] as bool;
    }
    if (c.containsKey('deempMode')) {
      if (c['deempMode'] is! String) {
        c['deempMode'] = _keyOf(deempModeKeys, deempMode);
      }
      final deempOpt = c['deempMode'] as String;
      if (deempModeKeys.containsKey(deempOpt)) {
        deempMode = deempModeKeys[deempOpt]!;
      }
    }
    if (c['FMIFNREnabled'] is bool) {
      fmIFNREnabled = c['FMIFNREnabled'] as bool;
    }
    final presetOpt = c['fmifnrPreset'];
    if (presetOpt is String && ifnrPresetKeys.containsKey(presetOpt)) {
      fmIFPreset = ifnrPresetKeys[presetOpt]!;
    }
    if (c['noiseBlankerEnabled'] is bool) {
      nbEnabled = c['noiseBlankerEnabled'] as bool;
    }
    if (c['noiseBlankerLevel'] is num) {
      nbLevel = (c['noiseBlankerLevel'] as num).toDouble();
    }
    config.release();

    // Configure VFO
    final v = vfo;
    if (v != null) {
      v.setBandwidthLimits(minBandwidth, maxBandwidth, demod.getBandwidthLocked());
      v.setReference(demod.getVFOReference());
      v.setSnapInterval(snapInterval);
      v.setSampleRate(ifSamplerate, bandwidth);
    }

    // Configure bandwidth
    setBandwidth(bandwidth);

    // Configure noise blanker
    nb.setRate(500.0 / ifSamplerate);
    setNBLevel(nbLevel);
    setNBEnabled(nbAllowed && nbEnabled);

    // Configure FM IF Noise Reduction
    setIFNRPreset((selectedDemodID == DemodID.nfm.id) ? fmIFPreset : IFNRPreset.broadcast);
    setFMIFNREnabled(fmIFNRAllowed ? fmIFNREnabled : false);

    // Configure squelch
    setSquelchMode(squelchAllowed ? squelchMode : SquelchMode.off);
    setSquelchLevel(squelchLevel);

    // Configure AF chain
    if (postProcEnabled) {
      // Configure resampler
      final afsr = demod.getAFSampleRate();
      resamp.setInSamplerate(afsr);
      afChain.enableBlock(resamp);
      setAudioSampleRate(audioSampleRate);

      // Configure the HPF
      setHighPass(highPass && highPassAllowed);

      // Configure deemphasis
      setDeemphasisMode(deempMode);
    } else {
      // Disable everything if post processing is disabled
      afChain.disableAllBlocks();
    }

    // Start new demodulator
    demod.start();
  }

  // ---------------------------------------------------------------------------
  // Setters (radio_module.h:565-762)
  // ---------------------------------------------------------------------------

  /// radio_module.h:565-575.
  void setBandwidth(double bw) {
    bw = bw.clamp(minBandwidth, maxBandwidth).toDouble();
    bandwidth = bw;
    final demod = selectedDemod;
    if (demod == null) {
      return;
    }
    vfo?.setBandwidth(bandwidth);
    demod.setBandwidth(bandwidth);

    config.acquire();
    demodConf(config, name, demod.getName())['bandwidth'] = bandwidth;
    config.release(true);
  }

  /// radio_module.h:577-604.
  void setAudioSampleRate(double sr) {
    audioSampleRate = sr;
    final demod = selectedDemod;
    if (demod == null) {
      return;
    }
    demod.afSampRateChanged(audioSampleRate);
    final v = vfo;
    if (!postProcEnabled && v != null) {
      // If postproc is disabled, IF SR = AF SR
      minBandwidth = demod.getMinBandwidth();
      maxBandwidth = demod.getMaxBandwidth();
      bandwidth = demod.getIFSampleRate();
      v.setBandwidthLimits(minBandwidth, maxBandwidth, demod.getBandwidthLocked());
      v.setSampleRate(demod.getIFSampleRate(), bandwidth);
      return;
    }

    // Configure resampler
    resamp.setOutSamplerate(audioSampleRate);

    // Configure the HPF sample rate
    hpTaps = dsp.highPass(300.0, 100.0, audioSampleRate);
    hpf.setTaps(hpTaps);

    // Configure deemphasis sample rate
    deemp.setSamplerate(audioSampleRate);
  }

  /// radio_module.h:606-620.
  void setHighPass(bool enabled) {
    highPass = enabled;
    final demod = selectedDemod;
    if (!postProcEnabled || demod == null) {
      return;
    }
    afChain.setBlockEnabled(hpf, enabled);

    config.acquire();
    demodConf(config, name, demod.getName())['highPass'] = enabled;
    config.release(true);
  }

  /// radio_module.h:622-633.
  void setDeemphasisMode(DeemphasisMode mode) {
    deempMode = mode;
    final demod = selectedDemod;
    if (!postProcEnabled || demod == null) {
      return;
    }
    final deempEnabled = (mode != DeemphasisMode.none);
    if (deempEnabled) {
      deemp.setTau(deempTaus[mode]!);
    }
    afChain.setBlockEnabled(deemp, deempEnabled);

    config.acquire();
    demodConf(config, name, demod.getName())['deempMode'] = _keyOf(deempModeKeys, deempMode);
    config.release(true);
  }

  /// radio_module.h:635-644.
  void setNBEnabled(bool enable) {
    nbEnabled = enable;
    final demod = selectedDemod;
    if (demod == null) {
      return;
    }
    ifChain.setBlockEnabled(nb, nbEnabled);

    config.acquire();
    demodConf(config, name, demod.getName())['noiseBlankerEnabled'] = nbEnabled;
    config.release(true);
  }

  /// radio_module.h:646-655.
  void setNBLevel(double level) {
    nbLevel = level.clamp(minNb, maxNb).toDouble();
    nb.setLevel(nbLevel);
    final demod = selectedDemod;
    if (demod == null) {
      return;
    }
    config.acquire();
    demodConf(config, name, demod.getName())['noiseBlankerLevel'] = nbLevel;
    config.release(true);
  }

  /// radio_module.h:657-704.
  void setSquelchMode(SquelchMode mode) {
    squelchMode = mode;
    final demod = selectedDemod;
    if (demod == null) {
      return;
    }

    // Disable all squelch blocks
    ifChain.disableBlock(powerSquelch);

    // Enable the block depending on the mode
    switch (mode) {
      case SquelchMode.power:
        ifChain.enableBlock(powerSquelch);
      case SquelchMode.off:
      case SquelchMode.snr:
      case SquelchMode.ctcssMute:
      case SquelchMode.ctcssDecode:
      case SquelchMode.dcsMute:
      case SquelchMode.dcsDecode:
        // SNR/DCS: TODO in SDR++. CTCSS: block not ported (see header).
        break;
    }

    config.acquire();
    final key = squelchModeKeys.entries.where((e) => e.value == squelchMode).map((e) => e.key).firstOrNull ?? 'off';
    demodConf(config, name, demod.getName())['squelchMode'] = key;
    config.release(true);
  }

  /// radio_module.h:706-715.
  void setSquelchLevel(double level) {
    squelchLevel = level.clamp(minSquelch, maxSquelch).toDouble();
    powerSquelch.setLevel(squelchLevel);
    final demod = selectedDemod;
    if (demod == null) {
      return;
    }
    config.acquire();
    demodConf(config, name, demod.getName())['squelchLevel'] = squelchLevel;
    config.release(true);
  }

  /// radio_module.h:735-744 (FMIF block not ported: flag stored and saved only).
  void setFMIFNREnabled(bool enabled) {
    fmIFNREnabled = enabled;
    final demod = selectedDemod;
    if (demod == null) {
      return;
    }
    config.acquire();
    demodConf(config, name, demod.getName())['FMIFNREnabled'] = fmIFNREnabled;
    config.release(true);
  }

  /// radio_module.h:746-762.
  void setIFNRPreset(IFNRPreset preset) {
    // Don't save if in broadcast mode
    if (preset == IFNRPreset.broadcast) {
      return;
    }
    fmIFPreset = preset;
    final demod = selectedDemod;
    if (demod == null) {
      return;
    }
    config.acquire();
    demodConf(config, name, demod.getName())['fmifnrPreset'] = _keyOf(ifnrPresetKeys, fmIFPreset);
    config.release(true);
  }

  /// Snap interval edit of the menu (radio_module.h:219-232).
  void setSnapInterval(double interval) {
    snapInterval = interval;
    final demod = selectedDemod;
    if (demod == null) return;
    vfo?.setSnapInterval(snapInterval);
    config.acquire();
    demodConf(config, name, demod.getName())['snapInterval'] = snapInterval;
    config.release(true);
  }

  // ---------------------------------------------------------------------------
  // module_com interface (radio_module.h:780-842)
  // ---------------------------------------------------------------------------

  Object? _moduleInterfaceHandler(int code, Object? input) {
    if (selectedDemod == null) {
      return null;
    }
    switch (code) {
      case RadioIfaceCmd.getMode:
        return selectedDemodID;
      case RadioIfaceCmd.setMode:
        final id = input is int ? DemodID.fromId(input) : null;
        if (id != null && enabled) selectDemodByID(id);
      case RadioIfaceCmd.getBandwidth:
        return bandwidth;
      case RadioIfaceCmd.setBandwidth:
        if (input is num && enabled && !bandwidthLocked) setBandwidth(input.toDouble());
      case RadioIfaceCmd.getSquelchMode:
        return squelchMode;
      case RadioIfaceCmd.setSquelchMode:
        if (input is SquelchMode && enabled) setSquelchMode(input);
      case RadioIfaceCmd.getSquelchLevel:
        return squelchLevel;
      case RadioIfaceCmd.setSquelchLevel:
        if (input is num && enabled) setSquelchLevel(input.toDouble());
      case RadioIfaceCmd.getHighpass:
        return highPass;
      case RadioIfaceCmd.setHighpass:
        if (input is bool && enabled) setHighPass(input);
    }
    return null;
  }
}

/// `SDRPP_MOD_INFO` + `_INIT_/_CREATE_INSTANCE_/_DELETE_INSTANCE_/_END_` of radio/src/main.cpp.
class RadioModuleFactory extends ModuleFactory {
  /// [configPath]: `<root>/radio_config.json`; null keeps the config in memory (tests).
  RadioModuleFactory(this.core, {this.configPath, ConfigManager? config}) : config = config ?? ConfigManager();

  final Core core;
  final String? configPath;
  final ConfigManager config;

  @override
  ModuleInfo get info => const ModuleInfo(
      name: 'radio',
      description: 'Analog radio decoder',
      author: 'Ryzerth',
      versionMajor: 2,
      versionMinor: 0,
      versionBuild: 0,
      maxInstances: -1);

  @override
  void init() {
    config.setPath(configPath);
    config.load(<String, dynamic>{});
    config.enableAutoSave();
  }

  @override
  ModuleInstance createInstance(String name) => RadioModule(name, core, config);

  @override
  void end() {
    config.disableAutoSave();
    config.save();
  }
}

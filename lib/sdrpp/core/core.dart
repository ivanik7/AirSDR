// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/core.h / core.cpp (@8c9f5ee): namespace `core` globals (lines 34-38)
// and `core::setInputSampleRate` (lines 41-57).
//
// The globals become fields of an explicit [Core] object. `setInputSampleRate` updates the
// IQ frontend and, instead of touching `gui::waterfall` directly (bandwidth, view offset,
// view bandwidth, zoom slider), emits [Core.onInputSampleRateChanged] with the effective rate
// so the UI side can reset its zoom. No server mode.
import '../signal_path/iq_frontend.dart';
import '../signal_path/signal_path.dart';
import '../signal_path/source_handler.dart';
import 'config.dart';
import 'event.dart';
import 'module.dart';
import 'module_com.dart';

class Core implements SourceCore {
  Core({ConfigManager? configManager, SignalPath? sigpath, void Function(String message)? log})
      : log = log ?? ((_) {}),
        configManager = configManager ?? ConfigManager() {
    this.sigpath = sigpath ?? SignalPath(config: this.configManager, log: this.log);
    moduleManager = ModuleManager(log: this.log);
    modComManager = ModuleComManager(log: this.log);
    // IQFrontEnd::setDecimation → core::setInputSampleRate (iq_frontend.cpp:121).
    this.sigpath.iqFrontEnd.coreSetInputSampleRate = setInputSampleRate;
  }

  final void Function(String message) log;

  /// `core::configManager`.
  final ConfigManager configManager;

  /// `core::moduleManager`.
  late final ModuleManager moduleManager;

  /// `core::modComManager`.
  late final ModuleComManager modComManager;

  /// The `sigpath::` globals.
  late final SignalPath sigpath;

  /// Replaces the `gui::waterfall` / `gui::mainWindow` zoom reset in core.cpp:50-53.
  /// Argument: the new effective (post-decimation) sample rate.
  final Event<double> onInputSampleRateChanged = Event<double>();

  IQFrontEnd get iqFrontEnd => sigpath.iqFrontEnd;

  /// core.cpp:41-57.
  @override
  void setInputSampleRate(double samplerate) {
    // Update IQ frontend input samplerate and get effective samplerate
    sigpath.iqFrontEnd.setSampleRate(samplerate);
    final effectiveSr = sigpath.iqFrontEnd.getEffectiveSamplerate();

    // Reset zoom
    onInputSampleRateChanged.emit(effectiveSr);

    // Debug logs
    log('New DSP samplerate: $effectiveSr (source samplerate is $samplerate)');
  }
}

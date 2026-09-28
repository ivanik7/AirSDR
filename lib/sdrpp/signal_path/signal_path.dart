// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/signal_path/signal_path.h (lines 1-12) / signal_path.cpp.
//
// C++ exposes four SDRPP_EXPORT globals in namespace `sigpath`. The Dart port groups them in an
// explicit [SignalPath] object (no globals), so tests and the DSP isolate can own independent
// instances.
import '../core/config.dart';
import 'iq_frontend.dart';
import 'sink_manager.dart';
import 'source_manager.dart';
import 'vfo_manager.dart';

class SignalPath {
  SignalPath({IQFrontEnd? iqFrontEnd, ConfigManager? config, void Function(String message)? log})
      : iqFrontEnd = iqFrontEnd ?? IQFrontEnd() {
    vfoManager = VFOManager(this.iqFrontEnd);
    sourceManager = SourceManager(this.iqFrontEnd, log: log);
    sinkManager = SinkManager(config, log);
  }

  /// `sigpath::iqFrontEnd`.
  final IQFrontEnd iqFrontEnd;

  /// `sigpath::vfoManager`.
  late final VFOManager vfoManager;

  /// `sigpath::sourceManager`.
  late final SourceManager sourceManager;

  /// `sigpath::sinkManager`.
  late final SinkManager sinkManager;
}

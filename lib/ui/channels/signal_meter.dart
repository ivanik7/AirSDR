// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real signal level of the ONE tuned channel, from the DSP's FFT rows.
// Port of SDR++ `WaterFall::calculateVFOSignalInfo`
// (core/src/gui/widgets/waterfall.cpp:558-597): strength = max dB inside the
// VFO passband, SNR = strength − mean of the two side bands of one bandwidth
// each. Only the receiver's own channel has a level; other channel slots are
// not received and therefore never get one.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../radio_controller.dart';

@immutable
class SignalInfo {
  const SignalInfo({required this.strengthDb, required this.snrDb});
  final double strengthDb;
  final double snrDb;
}

/// `calculateVFOSignalInfo` on one FFT row covering `[lowFreq, highFreq)`.
/// [vfoCenter] is the absolute passband centre (LO + vfoCenterOffset).
/// Returns null when the passband or its side bands are outside the row.
SignalInfo? vfoSignalInfo(
  Float32List db,
  double lowFreq,
  double highFreq,
  double vfoCenter,
  double bandwidth,
) {
  final n = db.length;
  final span = highFreq - lowFreq;
  if (n == 0 || !(span > 0) || !(bandwidth > 0)) return null;
  int idx(double f) => ((f - lowFreq) / span * n).floor().clamp(0, n);
  final minSide = idx(vfoCenter - bandwidth);
  final minIn = idx(vfoCenter - bandwidth / 2);
  final maxIn = idx(vfoCenter + bandwidth / 2).clamp(0, n - 1);
  final maxSide = idx(vfoCenter + bandwidth);
  var sum = 0.0;
  var count = 0;
  for (var i = minSide; i < minIn; i++) {
    if (db[i].isFinite) {
      sum += db[i];
      count++;
    }
  }
  for (var i = maxIn + 1; i < maxSide; i++) {
    if (db[i].isFinite) {
      sum += db[i];
      count++;
    }
  }
  var max = double.negativeInfinity;
  for (var i = minIn; i <= maxIn && i < n; i++) {
    if (db[i] > max) max = db[i];
  }
  if (count == 0 || !max.isFinite) return null;
  return SignalInfo(strengthDb: max, snrDb: max - sum / count);
}

/// Live level of the tuned channel; null while stopped / no data.
class SignalMeter extends ValueNotifier<SignalInfo?> {
  SignalMeter(this.radio) : super(null) {
    _sub = radio.fftRows.listen(_onRow);
    radio.addListener(_onRadio);
  }
  final RadioController radio;
  late final StreamSubscription<FftRow> _sub;

  /// SDR++ `snrSmoothingAlpha/Beta` = 0.5.
  static const smoothing = 0.5;

  void _onRadio() {
    if (!radio.running && value != null) value = null;
  }

  void _onRow(FftRow row) {
    if (!radio.running) return;
    final info = vfoSignalInfo(
      row.db,
      row.lowFreq,
      row.highFreq,
      radio.centerFrequency + radio.vfoCenterOffset,
      radio.bandwidth,
    );
    final prev = value;
    value = info == null || prev == null
        ? info
        : SignalInfo(
            strengthDb: info.strengthDb,
            snrDb: smoothing * prev.snrDb + (1 - smoothing) * info.snrDb,
          );
  }

  @override
  void dispose() {
    _sub.cancel();
    radio.removeListener(_onRadio);
    super.dispose();
  }
}

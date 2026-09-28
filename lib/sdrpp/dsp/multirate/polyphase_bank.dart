// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/multirate/polyphase_bank.h (@8c9f5ee, lines 1-62).
//
// tapsPerPhase = ceil(N/P); phases[(P − 1) − (i % P)][i / P] = taps[i] (zero padded).
// Note the reversed phase index (docs/02 §3.6, §6.6).
// Dart: stored as one flat Float32List `phases[phase * tapsPerPhase + k]`, plus SIMD tap tables
// per phase built on demand for the data type actually used.
import 'dart:typed_data';

import '../kernels/dot.dart';
import '../taps/taps.dart';

class PolyphaseBank {
  PolyphaseBank._(this.phaseCount, this.tapsPerPhase, this.phases);

  final int phaseCount;
  final int tapsPerPhase;

  /// Flat bank: phase p occupies [p·tapsPerPhase, (p+1)·tapsPerPhase).
  final Float32List phases;

  List<TapsRR>? _rr;
  List<TapsCR>? _cr;

  /// View of phase [p].
  Float32List phase(int p) => Float32List.sublistView(phases, p * tapsPerPhase, (p + 1) * tapsPerPhase);

  /// SIMD tables for real data, one per phase.
  List<TapsRR> get simdRR => _rr ??= List.generate(phaseCount, (p) => TapsRR(phase(p)), growable: false);

  /// SIMD tables for complex/stereo data, one per phase.
  List<TapsCR> get simdCR => _cr ??= List.generate(phaseCount, (p) => TapsCR(phase(p)), growable: false);
}

/// buildPolyphaseBank(phaseCount, taps)
PolyphaseBank buildPolyphaseBank(int phaseCount, Taps taps) {
  final tapsPerPhase = (taps.size + phaseCount - 1) ~/ phaseCount;
  final bank = Float32List(phaseCount * tapsPerPhase);
  final totTapCount = phaseCount * tapsPerPhase;
  for (int i = 0; i < totTapCount; i++) {
    bank[((phaseCount - 1) - (i % phaseCount)) * tapsPerPhase + (i ~/ phaseCount)] =
        (i < taps.size) ? taps.taps[i] : 0;
  }
  return PolyphaseBank._(phaseCount, tapsPerPhase, bank);
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tuning policy. Port of sdrpp/core/src/gui/tuner.cpp (SDR++ @8c9f5ee, lines 1-140).
//
// SDR++ calls `sigpath::vfoManager.setOffset/setCenterOffset`,
// `gui::waterfall.setViewOffset/setCenterFrequency`, `gui::freqSelect.setFrequency`
// and `sigpath::sourceManager.tune`. Here the functions mutate an [FftViewport]
// (LO + view) and a [WaterfallVfo]; the caller (SdrUiState) then pushes the
// resulting `viewport.centerFreq` / `vfo.generalOffset` to the RadioController
// (which is where `sourceManager.tune` happens) and refreshes FrequencySelect.

import 'viewport.dart';

/// `tuner::TuningMode` (gui/tuner.h).
enum TuningMode {
  center,
  normal,
  lowerHalf,
  upperHalf,
  iqOnly;

  String get label => switch (this) {
        TuningMode.center => 'CENTER',
        TuningMode.normal => 'NORMAL',
        TuningMode.lowerHalf => 'LOWER',
        TuningMode.upperHalf => 'UPPER',
        TuningMode.iqOnly => 'IQ',
      };
}

/// `tuner::centerTuning` (tuner.cpp:8-20). [vfo] null = no VFO.
void centerTuning(FftViewport wf, WaterfallVfo? vfo, double freq) {
  if (vfo != null) {
    vfo.setOffset(0);
  }
  final bw = wf.wholeBandwidth;
  final viewBW = wf.viewBandwidth;
  wf.setViewOffset((bw / 2.0) - (viewBW / 2.0));
  wf.setCenterFrequency(freq);
  wf.setViewOffset(0);
  // gui::freqSelect.setFrequency(freq); sigpath::sourceManager.tune(freq); — done by caller
}

/// `tuner::normalTuning` (tuner.cpp:22-109).
void normalTuning(FftViewport wf, WaterfallVfo? vfo, double freq) {
  if (vfo == null) {
    centerTuning(wf, vfo, freq);
    return;
  }

  final viewBW = wf.viewBandwidth;
  final bw = wf.wholeBandwidth;

  final currentOff = vfo.centerOffset;
  final currentTune = wf.centerFreq + vfo.generalOffset;
  final delta = freq - currentTune;

  final newVFO = currentOff + delta;
  final vfoBW = vfo.bandwidth;
  final vfoBottom = newVFO - (vfoBW / 2.0);
  final vfoTop = newVFO + (vfoBW / 2.0);

  final view = wf.viewOffset;
  final viewBottom = view - (viewBW / 2.0);
  final viewTop = view + (viewBW / 2.0);

  final bottom = -(bw / 2.0);
  final top = (bw / 2.0);

  // VFO still fints in the view
  if (vfoBottom > viewBottom && vfoTop < viewTop) {
    vfo.setCenterOffset(newVFO);
    return;
  }

  // VFO too low for current SDR tuning
  if (vfoBottom < bottom) {
    wf.setViewOffset((bw / 2.0) - (viewBW / 2.0));
    final newVFOOffset = (bw / 2.0) - (vfoBW / 2.0) - (viewBW / 10.0);
    vfo.setOffset(newVFOOffset);
    wf.setCenterFrequency(freq - newVFOOffset);
    return;
  }

  // VFO too high for current SDR tuning
  if (vfoTop > top) {
    wf.setViewOffset((viewBW / 2.0) - (bw / 2.0));
    final newVFOOffset = (vfoBW / 2.0) - (bw / 2.0) + (viewBW / 10.0);
    vfo.setOffset(newVFOOffset);
    wf.setCenterFrequency(freq - newVFOOffset);
    return;
  }

  // VFO is still without the SDR's bandwidth
  if (delta < 0) {
    final newViewOff = vfoTop - (viewBW / 2.0) + (viewBW / 10.0);
    final newViewBottom = newViewOff - (viewBW / 2.0);

    if (newViewBottom > bottom) {
      wf.setViewOffset(newViewOff);
      vfo.setCenterOffset(newVFO);
      return;
    }

    wf.setViewOffset((bw / 2.0) - (viewBW / 2.0));
    final newVFOOffset = (bw / 2.0) - (vfoBW / 2.0) - (viewBW / 10.0);
    vfo.setCenterOffset(newVFOOffset);
    wf.setCenterFrequency(freq - newVFOOffset);
  } else {
    final newViewOff = vfoBottom + (viewBW / 2.0) - (viewBW / 10.0);
    final newViewTop = newViewOff + (viewBW / 2.0);

    if (newViewTop < top) {
      wf.setViewOffset(newViewOff);
      vfo.setCenterOffset(newVFO);
      return;
    }

    wf.setViewOffset((viewBW / 2.0) - (bw / 2.0));
    final newVFOOffset = (vfoBW / 2.0) - (bw / 2.0) + (viewBW / 10.0);
    vfo.setCenterOffset(newVFOOffset);
    wf.setCenterFrequency(freq - newVFOOffset);
  }
}

/// `tuner::iqTuning` (tuner.cpp): only the LO moves.
void iqTuning(FftViewport wf, double freq) {
  wf.setCenterFrequency(freq);
}

/// `tuner::tune` (tuner.cpp): dispatch by mode.
void tune(TuningMode mode, FftViewport wf, WaterfallVfo? vfo, double freq) {
  switch (mode) {
    case TuningMode.center:
      centerTuning(wf, vfo, freq);
    case TuningMode.normal:
    case TuningMode.lowerHalf:
    case TuningMode.upperHalf:
      normalTuning(wf, vfo, freq);
    case TuningMode.iqOnly:
      iqTuning(wf, freq);
  }
}

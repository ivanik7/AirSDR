// SPDX-License-Identifier: GPL-3.0-or-later
//
// UI-facing radio interface.
//
// This is the only thing the widgets in lib/ui/ know about the radio. It
// collects, in one object, what SDR++ spreads over MainWindow (play/stop,
// sdrpp/core/src/gui/main_window.cpp:676-691), the source menu
// (gui/menus/source.cpp: device, sample rate, gain), the radio module
// (decoder_modules/radio/src/radio_module.h: mode, bandwidth, squelch), the
// sink stream (volume) and the FFT path (signal_path/iq_frontend.cpp →
// WaterFall::pushFFT).
//
// Implementations:
//   * DemoRadioController (demo_radio_controller.dart) — synthetic rows, no DSP.
//   * The real controller (integrator) — on top of the DSP isolate
//     (lib/runtime/…), see docs/10-architecture.md §5.
//
// Threading: all members are called on, and all notifications/stream events
// are delivered on, the UI isolate.

import 'dart:async';
import 'package:flutter/foundation.dart';

/// Demodulator modes. [id] is the SDR++ radio mode id
/// (decoder_modules/radio/src/radio_interface.h: NFM=0, WFM=1, AM=2, DSB=3,
/// USB=4, CW=5, LSB=6, RAW=7).
enum DemodMode {
  wfm(1, 'WFM'),
  nfm(0, 'NFM'),
  am(2, 'AM'),
  usb(4, 'USB'),
  lsb(6, 'LSB'),
  dsb(3, 'DSB'),
  cw(5, 'CW'),
  raw(7, 'RAW');

  const DemodMode(this.id, this.label);

  /// SDR++ mode id (used in radio_config.json `selectedDemodId`).
  final int id;
  final String label;

  static DemodMode fromId(int id) => DemodMode.values.firstWhere((m) => m.id == id, orElse: () => DemodMode.wfm);

  /// Per-mode parameters (docs/02-sdrpp-dsp-radio.md §4.3).
  DemodParams get params => demodParams[this]!;
}

/// Where the "tuned frequency" (the red line) sits inside the VFO passband.
/// Port of `WaterfallVFO::REF_LOWER/REF_CENTER/REF_UPPER` (gui/widgets/waterfall.h:26-31).
enum VfoReference { lower, center, upper }

/// Per-demodulator constants (docs/02 §4.3, decoder_modules/radio/src/demodulators/*.h).
@immutable
class DemodParams {
  const DemodParams({
    required this.ifSampleRate,
    required this.defaultBandwidth,
    required this.minBandwidth,
    required this.maxBandwidth,
    required this.snapInterval,
    required this.reference,
    this.bandwidthLocked = false,
    this.squelchAllowed = true,
  });

  /// VFO output sample rate (Hz).
  final double ifSampleRate;
  final double defaultBandwidth;
  final double minBandwidth;
  final double maxBandwidth;

  /// Tap-to-tune snap interval (Hz) — `WaterfallVFO::snapInterval`.
  final double snapInterval;
  final VfoReference reference;

  /// True for RAW: bandwidth is the audio sample rate and cannot be changed.
  final bool bandwidthLocked;
  final bool squelchAllowed;

  double clampBandwidth(double bw) => bandwidthLocked ? defaultBandwidth : bw.clamp(minBandwidth, maxBandwidth).toDouble();
}

/// docs/02 §4.3 table.
const Map<DemodMode, DemodParams> demodParams = <DemodMode, DemodParams>{
  DemodMode.wfm: DemodParams(
      ifSampleRate: 250000, defaultBandwidth: 150000, minBandwidth: 50000, maxBandwidth: 250000,
      snapInterval: 100000, reference: VfoReference.center),
  DemodMode.nfm: DemodParams(
      ifSampleRate: 50000, defaultBandwidth: 12500, minBandwidth: 1000, maxBandwidth: 50000,
      snapInterval: 2500, reference: VfoReference.center),
  DemodMode.am: DemodParams(
      ifSampleRate: 15000, defaultBandwidth: 10000, minBandwidth: 1000, maxBandwidth: 15000,
      snapInterval: 1000, reference: VfoReference.center),
  DemodMode.usb: DemodParams(
      ifSampleRate: 24000, defaultBandwidth: 2800, minBandwidth: 500, maxBandwidth: 12000,
      snapInterval: 100, reference: VfoReference.lower),
  DemodMode.lsb: DemodParams(
      ifSampleRate: 24000, defaultBandwidth: 2800, minBandwidth: 500, maxBandwidth: 12000,
      snapInterval: 100, reference: VfoReference.upper),
  DemodMode.dsb: DemodParams(
      ifSampleRate: 24000, defaultBandwidth: 4600, minBandwidth: 1000, maxBandwidth: 12000,
      snapInterval: 100, reference: VfoReference.center),
  DemodMode.cw: DemodParams(
      ifSampleRate: 3000, defaultBandwidth: 200, minBandwidth: 50, maxBandwidth: 500,
      snapInterval: 10, reference: VfoReference.center, squelchAllowed: false),
  DemodMode.raw: DemodParams(
      ifSampleRate: 48000, defaultBandwidth: 48000, minBandwidth: 48000, maxBandwidth: 48000,
      snapInterval: 2500, reference: VfoReference.center, bandwidthLocked: true, squelchAllowed: false),
};

/// Gain control description of a device (source-module specific in SDR++).
@immutable
class GainRange {
  const GainRange({required this.min, required this.max, this.step = 0, this.unit = 'dB'});
  final double min;
  final double max;

  /// Discrete step (0 = continuous). RTL-SDR tuners have a table of gains;
  /// the controller snaps to the nearest supported value.
  final double step;
  final String unit;
}

/// A selectable IQ source (RTL-SDR, HackRF, file, demo…).
@immutable
class SdrDeviceInfo {
  const SdrDeviceInfo({
    required this.id,
    required this.name,
    required this.sampleRates,
    required this.gain,
    this.hasAgc = true,
    this.minFrequency = 0,
    this.maxFrequency = 999999999999,
  });

  /// Stable id (e.g. USB path / serial). Equality is by [id].
  final String id;
  final String name;

  /// Supported IQ sample rates (Hz).
  final List<double> sampleRates;
  final GainRange gain;
  final bool hasAgc;

  /// Tunable range of the hardware (Hz), for FrequencySelect limits.
  final double minFrequency;
  final double maxFrequency;

  @override
  bool operator ==(Object other) => other is SdrDeviceInfo && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SdrDeviceInfo($id, $name)';
}

/// One spectrum line for the waterfall/spectrum.
///
/// [db] holds power in dBFS (`10·log10(|X|²/N²)`, iq_frontend.cpp:95),
/// already MAX-decimated (SDR++ `doZoom`) to the width requested with
/// [RadioController.setFftWidth]. Pixel `i` covers absolute frequencies
/// `[lowFreq + i·w, lowFreq + (i+1)·w)`, `w = (highFreq − lowFreq)/db.length`.
///
/// The span normally equals the view requested with [RadioController.setFftView],
/// but may differ right after a view/LO change (rows already in flight); the UI
/// re-projects such rows.
@immutable
class FftRow {
  const FftRow({required this.db, required this.lowFreq, required this.highFreq});
  final Float32List db;
  final double lowFreq;
  final double highFreq;

  int get width => db.length;
  double get span => highFreq - lowFreq;
}

/// UI-facing radio controller.
///
/// State getters are synchronous snapshots; setters apply immediately to the
/// snapshot (so the UI is responsive) and forward to the backend. Every state
/// change calls [notifyListeners]. FFT data is delivered separately via
/// [fftRows] (25–30 events/s; does not call [notifyListeners]).
///
/// Frequency model (same as SDR++):
///   * [centerFrequency] — hardware LO (SDR++ `conf["frequency"]`,
///     `WaterFall::centerFreq`);
///   * [vfoOffset] — VFO reference point relative to the LO
///     (`WaterfallVFO::generalOffset`, saved as `conf["vfoOffsets"][name]`);
///   * [tunedFrequency] = [centerFrequency] + [vfoOffset] — what FrequencySelect shows;
///   * [vfoCenterOffset] — centre of the passband relative to the LO; this is
///     what the DSP VFO shifts by (`WaterfallVFO::centerOffset`), and depends
///     on [mode]'s [VfoReference] and [bandwidth].
/// The tuning *policy* (CENTER vs NORMAL, gui/tuner.cpp) is done in the UI
/// (lib/ui/tuner.dart), which then calls [setTuning].
abstract class RadioController extends ChangeNotifier {
  // ---- Devices -------------------------------------------------------------

  /// Currently known devices. May change at runtime (USB attach/detach).
  List<SdrDeviceInfo> get devices;

  /// Selected device, or null when none is available.
  SdrDeviceInfo? get selectedDevice;

  /// Selects a device. Only allowed while not [running] (SDR++ disables the
  /// source menu while playing, gui/menus/source.cpp). May reset
  /// [sampleRate] / [gain] to device defaults.
  Future<void> selectDevice(SdrDeviceInfo device);

  /// Re-enumerates devices (e.g. after granting USB permission).
  Future<void> refreshDevices();

  // ---- Play / stop ---------------------------------------------------------

  bool get running;

  /// `MainWindow::setPlayState(true)`: flush, `sourceManager.start()`,
  /// `sourceManager.tune(centerFrequency)`. Errors are reported via [lastError]
  /// (and [running] stays false).
  Future<void> start();

  /// `MainWindow::setPlayState(false)`.
  Future<void> stop();

  /// Human-readable last error (permission denied, device gone…), or null.
  String? get lastError;

  // ---- Frequency / VFO -----------------------------------------------------

  double get centerFrequency;
  double get vfoOffset;
  double get tunedFrequency => centerFrequency + vfoOffset;

  /// Centre of the passband relative to the LO (see class doc).
  double get vfoCenterOffset {
    switch (mode.params.reference) {
      case VfoReference.center:
        return vfoOffset;
      case VfoReference.lower:
        return vfoOffset + bandwidth / 2.0;
      case VfoReference.upper:
        return vfoOffset - bandwidth / 2.0;
    }
  }

  /// Atomically sets the LO and the VFO reference offset. The backend retunes
  /// the hardware only if [centerFrequency] changed.
  void setTuning({required double centerFrequency, required double vfoOffset});

  // ---- Demodulator ---------------------------------------------------------

  DemodMode get mode;

  /// Selects the demodulator (`RadioModule::selectDemodByID`). Resets
  /// [bandwidth] to the mode's (saved or default) bandwidth, clamped.
  void setMode(DemodMode mode);

  /// VFO / demodulator bandwidth (Hz), within `mode.params` limits.
  double get bandwidth;
  void setBandwidth(double hz);

  double get snapInterval => mode.params.snapInterval;

  // ---- Source --------------------------------------------------------------

  /// IQ sample rate (Hz) = the whole displayed band (`WaterFall::wholeBandwidth`
  /// when decimation is 1).
  double get sampleRate;
  void setSampleRate(double hz);

  /// Manual gain (units per [SdrDeviceInfo.gain]). Ignored by hardware while [agc].
  double get gain;
  void setGain(double value);

  bool get agc;
  void setAgc(bool enabled);

  // ---- Audio ---------------------------------------------------------------

  /// 0..1 slider value (SDR++ applies `volume²` as gain in SinkManager::Stream).
  double get volume;
  void setVolume(double value);

  bool get squelchEnabled;
  void setSquelchEnabled(bool enabled);

  /// Power squelch level, dB (SDR++ range −100..0).
  double get squelchLevel;
  void setSquelchLevel(double db);

  // ---- FFT -----------------------------------------------------------------

  /// Broadcast stream of spectrum rows, only while [running].
  Stream<FftRow> get fftRows;

  /// Number of pixels (columns) each [FftRow] should have.
  /// Called from widget layout: must NOT call [notifyListeners] synchronously.
  void setFftWidth(int pixels);

  /// Visible part of the band, relative to the LO (SDR++ `viewOffset`,
  /// `viewBandwidth`). The backend decimates (doZoom) this window of the full
  /// FFT to [setFftWidth] columns (SDR++ `pushFFT`: drawDataStart/drawDataSize +
  /// doZoom — see lib/ui/waterfall_math.dart `zoomWindow`/`doZoom`, reusable by
  /// the DSP isolate). Must NOT call [notifyListeners] synchronously.
  void setFftView({required double viewOffset, required double viewBandwidth});
}

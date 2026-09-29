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

import '../sdrpp/signal_path/source_handler.dart' show SourceSetting;

export '../sdrpp/signal_path/source_handler.dart'
    show SourceSetting, ChoiceSetting, SliderSetting, BoolSetting;

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

  static DemodMode fromId(int id) => DemodMode.values.firstWhere(
    (m) => m.id == id,
    orElse: () => DemodMode.wfm,
  );

  /// Per-mode parameters (docs/02-sdrpp-dsp-radio.md §4.3).
  DemodParams get params => demodParams[this]!;
}

/// Where the "tuned frequency" (the red line) sits inside the VFO passband.
/// Port of `WaterfallVFO::REF_LOWER/REF_CENTER/REF_UPPER` (gui/widgets/waterfall.h:26-31).
enum VfoReference { lower, center, upper }

/// Squelch mode shown in the UI: off, SDR++ power squelch with a manual level, or the
/// automatic squelch (app extension, lib/sdrpp/dsp/noise_reduction/auto_squelch.dart).
enum SquelchType {
  off('off'),
  manual('power'),
  auto('auto');

  const SquelchType(this.key);

  /// radio_config.json / protocol key.
  final String key;

  static SquelchType fromKey(Object? key) =>
      SquelchType.values.firstWhere((m) => m.key == key, orElse: () => SquelchType.off);
}

/// Automatic squelch detector: noise squelch (FM) or level squelch (AM/SSB/CW).
enum AutoSquelchKind { noise, level }

/// Live state of the automatic squelch.
@immutable
class AutoSquelchStatus {
  const AutoSquelchStatus({required this.open, this.metricDb, this.thresholdDb});

  final bool open;

  /// Noise squelch: discriminator quieting (dB); level squelch: channel power (dB).
  final double? metricDb;

  /// Current automatic threshold (same units); null while the noise floor is learnt.
  final double? thresholdDb;
}

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
    this.autoSquelch = AutoSquelchKind.level,
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

  /// SDR++ power (manual) squelch available (`Demodulator::getSquelchAllowed`).
  final bool squelchAllowed;

  /// Automatic squelch detector of this mode (app extension; null = none).
  final AutoSquelchKind? autoSquelch;

  double clampBandwidth(double bw) => bandwidthLocked
      ? defaultBandwidth
      : bw.clamp(minBandwidth, maxBandwidth).toDouble();
}

/// docs/02 §4.3 table.
const Map<DemodMode, DemodParams> demodParams = <DemodMode, DemodParams>{
  DemodMode.wfm: DemodParams(
    ifSampleRate: 250000,
    defaultBandwidth: 150000,
    minBandwidth: 50000,
    maxBandwidth: 250000,
    snapInterval: 100000,
    reference: VfoReference.center,
    autoSquelch: null,
  ),
  DemodMode.nfm: DemodParams(
    ifSampleRate: 50000,
    defaultBandwidth: 12500,
    minBandwidth: 1000,
    maxBandwidth: 50000,
    snapInterval: 2500,
    reference: VfoReference.center,
    autoSquelch: AutoSquelchKind.noise,
  ),
  DemodMode.am: DemodParams(
    ifSampleRate: 15000,
    defaultBandwidth: 10000,
    minBandwidth: 1000,
    maxBandwidth: 15000,
    snapInterval: 1000,
    reference: VfoReference.center,
  ),
  DemodMode.usb: DemodParams(
    ifSampleRate: 24000,
    defaultBandwidth: 2800,
    minBandwidth: 500,
    maxBandwidth: 12000,
    snapInterval: 100,
    reference: VfoReference.lower,
  ),
  DemodMode.lsb: DemodParams(
    ifSampleRate: 24000,
    defaultBandwidth: 2800,
    minBandwidth: 500,
    maxBandwidth: 12000,
    snapInterval: 100,
    reference: VfoReference.upper,
  ),
  DemodMode.dsb: DemodParams(
    ifSampleRate: 24000,
    defaultBandwidth: 4600,
    minBandwidth: 1000,
    maxBandwidth: 12000,
    snapInterval: 100,
    reference: VfoReference.center,
  ),
  DemodMode.cw: DemodParams(
    ifSampleRate: 3000,
    defaultBandwidth: 200,
    minBandwidth: 50,
    maxBandwidth: 500,
    snapInterval: 10,
    reference: VfoReference.center,
    squelchAllowed: false,
  ),
  DemodMode.raw: DemodParams(
    ifSampleRate: 48000,
    defaultBandwidth: 48000,
    minBandwidth: 48000,
    maxBandwidth: 48000,
    snapInterval: 2500,
    reference: VfoReference.center,
    bandwidthLocked: true,
    squelchAllowed: false,
    autoSquelch: null,
  ),
};

/// Gain control description of a device (source-module specific in SDR++).
@immutable
class GainRange {
  const GainRange({
    required this.min,
    required this.max,
    this.step = 0,
    this.unit = 'dB',
  });
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
  const FftRow({
    required this.db,
    required this.lowFreq,
    required this.highFreq,
  });
  final Float32List db;
  final double lowFreq;
  final double highFreq;

  int get width => db.length;
  double get span => highFreq - lowFreq;
}

/// Connection state of the receive chain, for the status line (no SDR++ equivalent: SDR++ has
/// no USB hot-plug). [receiving] whenever [RadioController.running].
enum DeviceLinkState {
  /// A device is selected but not running (manual mode, e.g. the synthetic source).
  idle,

  /// No supported USB SDR is connected; reception starts by itself when one is plugged in.
  waiting,

  /// Opening the device / waiting for the Android USB permission dialog.
  connecting,

  receiving,

  /// The user refused USB access: no new request until retry or re-plug.
  permissionDenied,

  /// The device was unplugged / lost while receiving; waiting for it (or another) to come back.
  disconnected,

  /// The user pressed Stop: nothing restarts until Start or a new device connection.
  stoppedByUser,

  /// Opening or starting the device failed (see [RadioController.lastError]).
  failed,
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

  // Automatic squelch (app extension). Defaults keep implementations without it working:
  // the mode mirrors [squelchEnabled], Auto is not offered.

  /// Off / manual (SDR++ power squelch, [squelchLevel]) / auto.
  SquelchType get squelchType => squelchEnabled ? SquelchType.manual : SquelchType.off;
  void setSquelchType(SquelchType type) {
    if (type != SquelchType.auto) setSquelchEnabled(type == SquelchType.manual);
  }

  /// Whether [SquelchType.auto] can be selected for the current [mode].
  bool get autoSquelchAvailable => false;

  /// Auto squelch threshold offset (dB, the "sensitivity" slider): + = needs a stronger
  /// signal, − = opens earlier; 0 = the automatic threshold.
  double get autoSquelchOffset => 0;
  void setAutoSquelchOffset(double db) {}

  /// Range of [autoSquelchOffset].
  static const double minAutoSquelchOffset = -10;
  static const double maxAutoSquelchOffset = 20;

  /// Live auto squelch state while [squelchType] is auto and receiving; else null.
  AutoSquelchStatus? get autoSquelchStatus => null;

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

  // ---- Optional extras (default: not supported) -----------------------------

  /// Device-specific settings of the selected source (SDR++ source menu), declarative.
  List<SourceSetting> get sourceSettings => const <SourceSetting>[];

  /// SourceHandler.applySetting on the selected source.
  void setSourceSetting(String id, Object value) {}

  /// Options of the current demodulator (e.g. WFM `stereo`), key → value.
  Map<String, Object?> get demodOptions => const <String, Object?>{};

  /// Demodulator.setOption (e.g. `setDemodOption('stereo', true)`).
  void setDemodOption(String key, Object value) {}

  /// Runtime statistics for a status line (sample rate, dropped buffers, audio output…).
  Map<String, Object?> get stats => const <String, Object?>{};

  /// Clears [lastError] (after the UI has shown it).
  void clearError() {}

  /// Audio mute, independent of [volume]. Every cold start is muted; a device re-connection
  /// keeps the current state.
  bool get muted => false;
  void setMuted(bool muted) {}

  /// Device connection state for the status line.
  DeviceLinkState get linkState =>
      running ? DeviceLinkState.receiving : DeviceLinkState.idle;

  /// Retries the automatic connection after a refused permission / failed open (the user's
  /// "retry" button). Does not override an explicit Stop.
  Future<void> retryDevice() async {}
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Message protocol between the UI isolate (SdrRadioController) and the DSP isolate.
//
// All messages are `Map<String, Object?>` holding only sendable primitives, lists, maps and
// TransferableTypedData. UI → DSP messages carry `cmd`; optional `req` (int) asks for an
// [DspEvt.ack] reply `{evt: 'ack', req, ok, error?}`. DSP → UI messages carry `evt`.

/// UI → DSP commands (key [DspMsg.cmd]).
abstract final class DspCmd {
  /// `{id: String, params: Map}` — creates the source from the SourceRegistry and selects it
  /// (stops the current one first).
  static const selectSource = 'selectSource';

  /// MainWindow::setPlayState(true/false).
  static const start = 'start';
  static const stop = 'stop';

  /// `{center: double?, offset: double?}` — LO (retunes the source only if changed) and the
  /// VFO reference offset (WaterfallVFO::generalOffset).
  static const tune = 'tune';

  /// `{mode: int}` — SDR++ demod id (radio_interface.h).
  static const setMode = 'setMode';

  /// `{hz: double}`.
  static const setBandwidth = 'setBandwidth';

  /// `{hz: double}` / `{value: double}` / `{enabled: bool}` — generic source controls.
  static const setSampleRate = 'setSampleRate';
  static const setGain = 'setGain';
  static const setAgc = 'setAgc';

  /// `{id: String, value: Object}` — SourceHandler.applySetting.
  static const sourceSetting = 'sourceSetting';

  /// `{value: double}` 0..1 (SDR++ applies value²).
  static const setVolume = 'setVolume';

  /// `{enabled: bool?, level: double?}` — power squelch.
  static const setSquelch = 'setSquelch';

  /// `{key: String, value: Object}` — Demodulator.setOption (e.g. WFM stereo).
  static const demodOption = 'demodOption';

  /// `{width: int?, viewOffset: double?, viewBandwidth: double?, size: int?, rate: double?,
  ///   window: String?}`.
  static const setFft = 'setFft';

  /// `{enabled: bool}` — also send audio blocks to the UI (tests, recording).
  static const audioTap = 'audioTap';

  /// Replies with a [DspEvt.state].
  static const getState = 'getState';

  /// Stops everything, saves configs, closes the isolate.
  static const shutdown = 'shutdown';
}

/// DSP → UI events (key [DspMsg.evt]).
abstract final class DspEvt {
  /// `{port: SendPort}` — first message.
  static const ready = 'ready';
  static const ack = 'ack';

  /// `{data: TransferableTypedData (Float32 dB), low: double, high: double, seq: int}`.
  static const fft = 'fft';

  /// Full state snapshot (see DspEngine.stateMap).
  static const state = 'state';

  /// `{message: String, fatal: bool}`.
  static const error = 'error';

  /// `{samplesIn, audioFrames, fftRows, audioDropped, ...}` ~2×/s while running.
  static const stats = 'stats';

  /// `{data: TransferableTypedData (Float32 stereo interleaved), frames: int}` (audio tap).
  static const audio = 'audio';

  /// Sent when the isolate is about to exit.
  static const closed = 'closed';
}

abstract final class DspMsg {
  static const cmd = 'cmd';
  static const evt = 'evt';
  static const req = 'req';
}

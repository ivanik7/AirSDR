// SPDX-License-Identifier: GPL-3.0-or-later
// The real [RadioController]: a UI-isolate façade over the DSP isolate (docs/10 §5).
//
//  * State getters are local snapshots updated optimistically by setters (UI stays responsive)
//    and reconciled from the DSP isolate's `state` events once no command is in flight.
//  * Every UI call maps to one protocol message (dsp_protocol.dart); ordering is preserved.
//  * FFT rows arrive as TransferableTypedData (already doZoom-decimated to [setFftWidth]).
//  * Devices come from a list of [DeviceProvider]s. Built in: [SynthDeviceProvider] and
//    [FileDeviceProvider]. The integrator adds a USB provider (lib/usb/android_usb.dart
//    listDevices/open → fd) that returns `SourceSelection('usb', {fd, vid, pid, …})` and a
//    `registerSources` hook registering the 'usb' factory in the DSP isolate
//    (see source_registry.dart).
//
// lib/main.dart is NOT switched here (the integrator does it).
import 'dart:async';
import 'dart:isolate';

import '../ui/radio_controller.dart';
import '../sdrpp/modules/sources/synth_source.dart';
import 'dsp_engine.dart';
import 'dsp_isolate.dart';
import 'dsp_protocol.dart';
import 'source_registry.dart';

/// How to create a device's source inside the DSP isolate.
class SourceSelection {
  const SourceSelection(this.sourceId, [this.params = const <String, Object?>{}]);

  /// SourceRegistry id ('synth', 'file', 'usb', …).
  final String sourceId;

  /// Sendable params (e.g. `{fd, vid, pid, deviceName}` for USB).
  final Map<String, Object?> params;
}

/// Extension point for device enumeration/opening (UI isolate).
abstract class DeviceProvider {
  /// Devices currently available from this provider.
  Future<List<SdrDeviceInfo>> listDevices();

  /// True if [device] belongs to this provider.
  bool owns(SdrDeviceInfo device);

  /// Opens the device (USB: permission + fd) and returns how to create its source.
  Future<SourceSelection> open(SdrDeviceInfo device);

  /// Called when the device is deselected or the controller disposed (USB: close the fd).
  Future<void> close(SdrDeviceInfo device) async {}

  /// Fires when the device list may have changed (USB attach/detach). Optional.
  Stream<void> get changes => const Stream<void>.empty();
}

/// The synthetic generator (demo band around 100 MHz, see SynthSource.defaultCarriers).
class SynthDeviceProvider extends DeviceProvider {
  SynthDeviceProvider({this.params = const <String, Object?>{}});

  /// Extra SynthSource params (carriers, noiseLevel…).
  final Map<String, Object?> params;

  static final SdrDeviceInfo device = SdrDeviceInfo(
    id: 'synth:0',
    name: 'Synthetic signal generator',
    sampleRates: SynthSource.sampleRates,
    gain: const GainRange(min: 0, max: 0),
    hasAgc: false,
  );

  @override
  Future<List<SdrDeviceInfo>> listDevices() async => <SdrDeviceInfo>[device];
  @override
  bool owns(SdrDeviceInfo d) => d.id.startsWith('synth:');
  @override
  Future<SourceSelection> open(SdrDeviceInfo d) async => SourceSelection('synth', params);
}

/// IQ recordings (WAV or raw cf32/cu8/cs8/cs16).
class FileDeviceProvider extends DeviceProvider {
  FileDeviceProvider(this.files);

  /// Entries: `{path, format?, sampleRate?, centerFreq?, name?}`.
  final List<Map<String, Object?>> files;

  @override
  Future<List<SdrDeviceInfo>> listDevices() async => <SdrDeviceInfo>[
        for (final f in files)
          SdrDeviceInfo(
            id: 'file:${f['path']}',
            name: (f['name'] as String?) ?? 'File: ${(f['path'] as String).split('/').last}',
            sampleRates: <double>[((f['sampleRate'] as num?) ?? 0).toDouble()],
            gain: const GainRange(min: 0, max: 0),
            hasAgc: false,
          )
      ];
  @override
  bool owns(SdrDeviceInfo d) => d.id.startsWith('file:');
  @override
  Future<SourceSelection> open(SdrDeviceInfo d) async {
    final path = d.id.substring(5);
    final f = files.firstWhere((e) => e['path'] == path);
    return SourceSelection('file', <String, Object?>{...f, 'pump': 'realTime'});
  }
}

class SdrRadioController extends RadioController {
  SdrRadioController({
    List<DeviceProvider>? providers,
    this.options = const DspEngineOptions(),
    this.registerSources,
    this.spawnTimeout = const Duration(seconds: 20),
  }) : providers = providers ?? <DeviceProvider>[SynthDeviceProvider()] {
    for (final p in this.providers) {
      _subs.add(p.changes.listen((_) => refreshDevices()));
    }
    _ready = _init();
  }

  final List<DeviceProvider> providers;
  final DspEngineOptions options;
  final SourceRegistryHook? registerSources;
  final Duration spawnTimeout;

  DspIsolate? _dsp;
  late final Future<void> _ready;
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];
  final StreamController<FftRow> _rows = StreamController<FftRow>.broadcast();
  bool _disposed = false;

  List<SdrDeviceInfo> _devices = const <SdrDeviceInfo>[];
  SdrDeviceInfo? _device;
  SdrDeviceInfo? _openedDevice; // device whose source is selected in the DSP isolate
  bool _running = false;
  String? _lastError;

  double _centerFrequency = 100000000;
  double _vfoOffset = 0;
  DemodMode _mode = DemodMode.wfm;
  double _bandwidth = DemodMode.wfm.params.defaultBandwidth;
  double _sampleRate = 2400000;
  double _gain = 0;
  bool _agc = false;
  double _volume = 1.0;
  bool _squelchEnabled = false;
  double _squelchLevel = -50;
  bool _centerLocked = false;

  int _outstanding = 0;
  bool _gotState = false;

  /// Latest stats / state from the DSP isolate (diagnostics, tests).
  Map<Object?, Object?> lastStats = const <Object?, Object?>{};
  Map<Object?, Object?> lastState = const <Object?, Object?>{};

  /// Completes when the DSP isolate is up and the device list is loaded.
  Future<void> get ready => _ready;

  Future<void> _init() async {
    try {
      _dsp = await DspIsolate.spawn(options: options, registerSources: registerSources).timeout(spawnTimeout);
      _subs.add(_dsp!.events.listen(_onEvent));
      await refreshDevices();
    } catch (e) {
      _lastError = 'DSP start failed: $e';
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // DSP events
  // ---------------------------------------------------------------------------

  void _onEvent(Map<Object?, Object?> m) {
    switch (m[DspMsg.evt]) {
      case DspEvt.fft:
        if (!_rows.hasListener) return;
        final data = (m['data'] as TransferableTypedData).materialize().asFloat32List();
        _rows.add(FftRow(db: data, lowFreq: (m['low'] as num).toDouble(), highFreq: (m['high'] as num).toDouble()));
      case DspEvt.state:
        lastState = m;
        if (_outstanding == 0) _applyState(m);
      case DspEvt.stats:
        lastStats = m;
      case DspEvt.error:
        _lastError = m['message'] as String?;
        if (m['fatal'] == true) _running = false;
        _notify();
    }
  }

  void _applyState(Map<Object?, Object?> m) {
    _running = m['running'] == true;
    _sampleRate = (m['sampleRate'] as num).toDouble();
    _centerLocked = m['centerLocked'] == true;
    // The persisted LO is adopted once (first state); afterwards the UI owns it unless the
    // source locks it (file recordings).
    if (_centerLocked || !_gotState) _centerFrequency = (m['centerFreq'] as num).toDouble();
    _gotState = true;
    final vol = m['volume'];
    if (vol is num) _volume = vol.toDouble();
    _vfoOffset = (m['vfoOffset'] as num).toDouble();
    _mode = DemodMode.fromId((m['mode'] as num).toInt());
    _bandwidth = (m['bandwidth'] as num).toDouble();
    _squelchEnabled = m['squelchEnabled'] == true;
    _squelchLevel = (m['squelchLevel'] as num).toDouble();
    _notify();
  }

  /// Sends a command with ack; state echoes are ignored while commands are in flight, and a
  /// fresh state is requested when the last one completes.
  Future<void> _cmd(Map<String, Object?> msg) async {
    await _ready;
    final dsp = _dsp;
    if (dsp == null || dsp.isClosed) throw StateError('DSP isolate not running');
    _outstanding++;
    try {
      await dsp.request(msg);
    } finally {
      _outstanding--;
      if (_outstanding == 0 && !dsp.isClosed) dsp.send(<String, Object?>{DspMsg.cmd: DspCmd.getState});
    }
  }

  void _fire(Map<String, Object?> msg) {
    _cmd(msg).catchError((Object e) {
      _lastError = '$e';
      _notify();
    });
  }

  /// Direct access for advanced controls (source settings, demod options, FFT size…).
  Future<void> command(Map<String, Object?> msg) => _cmd(msg);

  // ---------------------------------------------------------------------------
  // Devices
  // ---------------------------------------------------------------------------

  @override
  List<SdrDeviceInfo> get devices => _devices;
  @override
  SdrDeviceInfo? get selectedDevice => _device;

  DeviceProvider? _providerOf(SdrDeviceInfo d) => providers.where((p) => p.owns(d)).firstOrNull;

  @override
  Future<void> selectDevice(SdrDeviceInfo device) async {
    if (_running || device == _device) return;
    _device = device;
    if (!device.sampleRates.contains(_sampleRate) && device.sampleRates.isNotEmpty) {
      _sampleRate = device.sampleRates[device.sampleRates.length ~/ 2];
    }
    _gain = _gain.clamp(device.gain.min, device.gain.max).toDouble();
    if (!device.hasAgc) _agc = false;
    _notify();
    try {
      await _openDevice(device);
    } catch (e) {
      _lastError = 'Cannot open ${device.name}: $e';
      _notify();
    }
  }

  Future<void> _openDevice(SdrDeviceInfo device) async {
    if (_openedDevice == device) return;
    final prev = _openedDevice;
    if (prev != null) {
      _openedDevice = null;
      await _providerOf(prev)?.close(prev);
    }
    final p = _providerOf(device);
    if (p == null) throw StateError('No provider for ${device.id}');
    final sel = await p.open(device);
    await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.selectSource, 'id': sel.sourceId, 'params': sel.params});
    _openedDevice = device;
    if (device.sampleRates.length > 1) {
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.setSampleRate, 'hz': _sampleRate});
    }
    if (device.gain.max > device.gain.min) {
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.setGain, 'value': _gain});
      if (device.hasAgc) await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.setAgc, 'enabled': _agc});
    }
  }

  @override
  Future<void> refreshDevices() async {
    final all = <SdrDeviceInfo>[];
    for (final p in providers) {
      try {
        all.addAll(await p.listDevices());
      } catch (e) {
        _lastError = 'Device enumeration failed: $e';
      }
    }
    _devices = List<SdrDeviceInfo>.unmodifiable(all);
    if (_device != null && !_devices.contains(_device)) {
      // Device gone (detach).
      if (_running) await stop();
      _device = null;
      _openedDevice = null;
    }
    _device ??= _devices.firstOrNull;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Play / stop
  // ---------------------------------------------------------------------------

  @override
  bool get running => _running;
  @override
  String? get lastError => _lastError;

  @override
  Future<void> start() async {
    if (_running || _disposed) return;
    await _ready;
    final d = _device;
    if (d == null) {
      _lastError = 'No device';
      _notify();
      return;
    }
    _lastError = null;
    try {
      await _openDevice(d);
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.tune, 'center': _centerFrequency, 'offset': _vfoOffset});
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.start});
      _running = true;
    } catch (e) {
      _lastError = '$e';
      _running = false;
    }
    _notify();
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _notify();
    try {
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.stop});
    } catch (e) {
      _lastError = '$e';
      _notify();
    }
  }

  // ---------------------------------------------------------------------------
  // Frequency / VFO
  // ---------------------------------------------------------------------------

  @override
  double get centerFrequency => _centerFrequency;
  @override
  double get vfoOffset => _vfoOffset;

  @override
  void setTuning({required double centerFrequency, required double vfoOffset}) {
    final msg = <String, Object?>{DspMsg.cmd: DspCmd.tune, 'offset': vfoOffset};
    if (!_centerLocked && centerFrequency != _centerFrequency) {
      _centerFrequency = centerFrequency;
      msg['center'] = centerFrequency;
    }
    _vfoOffset = vfoOffset;
    _fire(msg);
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Demodulator
  // ---------------------------------------------------------------------------

  @override
  DemodMode get mode => _mode;

  @override
  void setMode(DemodMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    _bandwidth = mode.params.defaultBandwidth; // corrected by the DSP state (saved per mode)
    _fire(<String, Object?>{DspMsg.cmd: DspCmd.setMode, 'mode': mode.id});
    _notify();
  }

  @override
  double get bandwidth => _bandwidth;

  @override
  void setBandwidth(double hz) {
    final bw = _mode.params.clampBandwidth(hz);
    if (bw == _bandwidth) return;
    _bandwidth = bw;
    _fire(<String, Object?>{DspMsg.cmd: DspCmd.setBandwidth, 'hz': bw});
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Source
  // ---------------------------------------------------------------------------

  @override
  double get sampleRate => _sampleRate;

  @override
  void setSampleRate(double hz) {
    if (hz == _sampleRate) return;
    _sampleRate = hz;
    if (_openedDevice != null) _fire(<String, Object?>{DspMsg.cmd: DspCmd.setSampleRate, 'hz': hz});
    _notify();
  }

  @override
  double get gain => _gain;

  @override
  void setGain(double value) {
    _gain = value;
    if (_openedDevice != null) _fire(<String, Object?>{DspMsg.cmd: DspCmd.setGain, 'value': value});
    _notify();
  }

  @override
  bool get agc => _agc;

  @override
  void setAgc(bool enabled) {
    _agc = enabled;
    if (_openedDevice != null) _fire(<String, Object?>{DspMsg.cmd: DspCmd.setAgc, 'enabled': enabled});
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Audio
  // ---------------------------------------------------------------------------

  @override
  double get volume => _volume;

  @override
  void setVolume(double value) {
    _volume = value.clamp(0.0, 1.0).toDouble();
    _fire(<String, Object?>{DspMsg.cmd: DspCmd.setVolume, 'value': _volume});
    _notify();
  }

  @override
  bool get squelchEnabled => _squelchEnabled;

  @override
  void setSquelchEnabled(bool enabled) {
    _squelchEnabled = enabled;
    _fire(<String, Object?>{DspMsg.cmd: DspCmd.setSquelch, 'enabled': enabled, 'level': _squelchLevel});
    _notify();
  }

  @override
  double get squelchLevel => _squelchLevel;

  @override
  void setSquelchLevel(double db) {
    _squelchLevel = db.clamp(-100.0, 0.0).toDouble();
    _fire(<String, Object?>{DspMsg.cmd: DspCmd.setSquelch, 'level': _squelchLevel});
    _notify();
  }

  // ---------------------------------------------------------------------------
  // FFT
  // ---------------------------------------------------------------------------

  @override
  Stream<FftRow> get fftRows => _rows.stream;

  @override
  void setFftWidth(int pixels) {
    if (pixels <= 0) return;
    _ready.then((_) => _dsp?.send(<String, Object?>{DspMsg.cmd: DspCmd.setFft, 'width': pixels}));
  }

  @override
  void setFftView({required double viewOffset, required double viewBandwidth}) {
    _ready.then((_) => _dsp?.send(
        <String, Object?>{DspMsg.cmd: DspCmd.setFft, 'viewOffset': viewOffset, 'viewBandwidth': viewBandwidth}));
  }

  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    final d = _openedDevice;
    if (d != null) _providerOf(d)?.close(d);
    _dsp?.close();
    _rows.close();
    super.dispose();
  }
}

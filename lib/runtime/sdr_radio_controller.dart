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

  /// A device that should be selected automatically after the next [listDevices] (USB: the
  /// dongle that launched the app via USB_DEVICE_ATTACHED, or one just plugged in). Optional.
  Future<SdrDeviceInfo?> preferredDevice() async => null;
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

  /// The user moved the generic gain/AGC controls since the device was selected. Until then the
  /// source's own (persisted per-device) gain is kept and reported back through the state.
  bool _gainTouched = false;
  double _volume = 1.0;
  bool _squelchEnabled = false;
  double _squelchLevel = -50;
  bool _centerLocked = false;

  int _outstanding = 0;
  bool _gotState = false;

  List<SourceSetting> _sourceSettings = const <SourceSetting>[];
  Map<String, Object?> _demodOptions = const <String, Object?>{};

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
        _notify();
      case DspEvt.error:
        _lastError = m['message'] as String?;
        if (m['fatal'] == true) {
          // The source stopped itself (device lost): release it so the next start reopens it.
          _running = false;
          final d = _openedDevice;
          _openedDevice = null;
          if (d != null) _providerOf(d)?.close(d);
        }
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
    final gain = m['gain'];
    if (gain is num) _gain = gain.toDouble();
    final agc = m['agc'];
    if (agc is bool) _agc = agc;
    final ss = m['sourceSettings'];
    if (ss is List) {
      _sourceSettings = List<SourceSetting>.unmodifiable(
          ss.whereType<Map<Object?, Object?>>().map(settingFromMap).whereType<SourceSetting>());
    }
    final dopt = m['demodOptions'];
    if (dopt is Map) _demodOptions = Map<String, Object?>.unmodifiable(dopt.cast<String, Object?>());
    _notify();
  }

  /// Inverse of DspEngine.settingToMap.
  static SourceSetting? settingFromMap(Map<Object?, Object?> m) {
    final id = m['id'] as String? ?? '';
    final label = m['label'] as String? ?? id;
    double d(Object? v) => (v as num?)?.toDouble() ?? 0;
    return switch (m['type']) {
      'choice' => ChoiceSetting(id, label, (m['options'] as List? ?? const <Object?>[]).map((e) => '$e').toList(),
          (m['selected'] as num?)?.toInt() ?? 0),
      'slider' => SliderSetting(id, label, min: d(m['min']), max: d(m['max']), step: d(m['step']), value: d(m['value'])),
      'bool' => BoolSetting(id, label, m['value'] == true),
      _ => null,
    };
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
      // Nearest supported rate (keeps the DSP load similar across devices).
      _sampleRate = device.sampleRates
          .reduce((a, b) => (a - _sampleRate).abs() <= (b - _sampleRate).abs() ? a : b);
    }
    _gain = _gain.clamp(device.gain.min, device.gain.max).toDouble();
    if (!device.hasAgc) _agc = false;
    _gainTouched = false;
    _notify();
    try {
      await _openDevice(device);
    } catch (e) {
      _lastError = 'Cannot open ${device.name}: $e';
      _notify();
    }
  }

  /// Selects and opens [device] (permission was granted by the USB_DEVICE_ATTACHED launch), so
  /// its settings are available before the first start.
  Future<void> _selectPreferred(SdrDeviceInfo device) async {
    if (device != _device) return selectDevice(device);
    try {
      await _openDevice(device);
    } catch (e) {
      _lastError = 'Cannot open ${device.name}: $e';
    }
    _notify();
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
    try {
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.selectSource, 'id': sel.sourceId, 'params': sel.params});
    } catch (_) {
      await p.close(device); // don't leak the USB connection when the source can't be created
      rethrow;
    }
    _openedDevice = device;
    if (device.sampleRates.length > 1) {
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.setSampleRate, 'hz': _sampleRate});
    }
    if (device.gain.max > device.gain.min && _gainTouched) {
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
      final gone = _openedDevice;
      _device = null;
      _openedDevice = null;
      if (gone != null) await _providerOf(gone)?.close(gone);
    }
    _device ??= _devices.firstOrNull;
    _notify();
    // Auto-select a device the provider asks for (USB_DEVICE_ATTACHED launch / hot-plug).
    if (!_running) {
      for (final p in providers) {
        SdrDeviceInfo? pref;
        try {
          pref = await p.preferredDevice();
        } catch (_) {}
        if (pref != null && _devices.contains(pref)) {
          // Not awaited: refreshDevices also runs inside _init, before [ready] completes.
          unawaited(_selectPreferred(_devices.firstWhere((d) => d == pref)));
          break;
        }
      }
    }
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
    _gainTouched = true;
    if (_openedDevice != null) _fire(<String, Object?>{DspMsg.cmd: DspCmd.setGain, 'value': value});
    _notify();
  }

  @override
  bool get agc => _agc;

  @override
  void setAgc(bool enabled) {
    _agc = enabled;
    _gainTouched = true;
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

  // ---------------------------------------------------------------------------
  // Source settings / demod options / stats
  // ---------------------------------------------------------------------------

  @override
  List<SourceSetting> get sourceSettings => _sourceSettings;

  @override
  void setSourceSetting(String id, Object value) {
    if (_openedDevice == null) return;
    _fire(<String, Object?>{DspMsg.cmd: DspCmd.sourceSetting, 'id': id, 'value': value});
  }

  @override
  Map<String, Object?> get demodOptions => _demodOptions;

  @override
  void setDemodOption(String key, Object value) {
    _demodOptions = Map<String, Object?>.unmodifiable(<String, Object?>{..._demodOptions, key: value});
    _fire(<String, Object?>{DspMsg.cmd: DspCmd.demodOption, 'key': key, 'value': value});
    _notify();
  }

  @override
  Map<String, Object?> get stats => <String, Object?>{
        for (final e in lastStats.entries)
          if (e.key != DspMsg.evt) '${e.key}': e.value,
        'sampleRate': _sampleRate,
      };

  @override
  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    _notify();
  }

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

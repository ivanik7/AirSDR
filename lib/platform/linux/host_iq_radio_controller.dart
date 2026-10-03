// SPDX-License-Identifier: GPL-3.0-or-later
//
// HostIqRadioController — RadioController for the Linux desktop dev/test
// target (L1). Drives libsdrcore.so (ABI 2 + the host USB extension,
// native/include/sdrcore.h / sdrcore_host.h) to stream real IQ from an
// attached USB SDR (RTL-SDR, HackRF) into the native ring. There is no
// native FFT/DSP/demod/audio yet (task N2): IQ samples never cross into
// Dart, [fftRows] never emits, and [stats] reports the native counters
// only. The Dart receive engine (lib/runtime) is not used here.
//
// Device identity: the host USB layer exposes bus/address, which change on
// replug. [SdrDeviceInfo.id] is built from (vid, pid, serial-or-path) so a
// device with a serial keeps the same UI identity across a replug; one
// without a serial gets a fresh id (same as a brand-new device).
//
// Native commands (open/configure/start/stop/close/stats) are plain
// synchronous FFI calls on the UI isolate (per sdrcore.h's "caller
// serializes" contract). All of them, plus the hotplug/stats polls and the
// debounced retune/gain apply, run through one Future chain ([_serial]) so
// two asynchronous triggers (a poll tick and a debounce timer, say) can
// never interleave their native calls. State changes finish before
// [notifyListeners] is called — never from inside a listener callback.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../native/sdr_core.dart';
import '../../runtime/device_sources.dart';
import '../../sdrpp/modules/sources/usb_source_factory.dart';
import '../../ui/radio_controller.dart';

/// Name of the persisted settings file inside `configDir`.
const String _configFileName = 'linux_host_radio.json';

class HostIqRadioController extends RadioController {
  HostIqRadioController({
    required SdrCore core,
    this.configDir,
    this.pollInterval = const Duration(seconds: 1),
    this.statsInterval = const Duration(milliseconds: 500),
    this.retuneDebounce = const Duration(milliseconds: 120),
    this.autoStart = true,
    // ignore: prefer_initializing_formals
  }) : _core = core {
    _loadConfig();
    // Cold-start enumeration without waiting a full pollInterval.
    unawaited(_poll());
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(_poll()));
  }

  /// Opens the bundled/host library and returns null (never throws) if it
  /// can't be loaded or this build has no host USB layer.
  static HostIqRadioController? tryCreate({
    String? configDir,
    bool autoStart = true,
  }) {
    SdrCore core;
    try {
      core = SdrCore.open();
    } catch (_) {
      return null;
    }
    if (!core.hasHostUsb) return null;
    return HostIqRadioController(
      core: core,
      configDir: configDir,
      autoStart: autoStart,
    );
  }

  final SdrCore _core;
  final String? configDir;
  final Duration pollInterval;
  final Duration statsInterval;
  final Duration retuneDebounce;
  final bool autoStart;

  Timer? _pollTimer;
  Timer? _statsTimer;
  Timer? _applyTimer;
  Future<void> _chain = Future<void>.value();
  bool _disposed = false;

  List<SdrDeviceInfo> _devices = const <SdrDeviceInfo>[];
  final Map<String, SdrHostUsbDevice> _deviceMap = <String, SdrHostUsbDevice>{};
  String? _selectedId;
  String? _openedId;
  SdrCoreInstance? _instance;

  /// A device id that just failed to open automatically; not retried again
  /// until a new attach, an explicit [start]/[retryDevice], or [selectDevice].
  String? _autoFailedId;

  bool _running = false;
  DeviceLinkState _link = DeviceLinkState.waiting;
  String? _lastError;
  bool _userStopped = false;

  double _centerFrequency = 100000000;
  double _vfoOffset = 0;
  DemodMode _mode = DemodMode.wfm;
  double _bandwidth = DemodMode.wfm.params.defaultBandwidth;
  double _sampleRate = 2400000;
  double _gain = 20;
  double _volume = 0.5;
  bool _muted = true; // every cold start is muted, like the Android controller
  bool _squelchEnabled = false;
  double _squelchLevel = -50;

  DateTime? _lastStatsTime;
  int _lastStatsInputSamples = 0;

  Map<String, Object?> _statsCache = const <String, Object?>{
    'engine': 'native IQ (Linux host)',
    'device': null,
    'state': 'idle',
    'inputSamples': 0,
    'processedSamples': 0,
    'ringDrops': 0,
    'inputRate': 0,
    'lastNativeError': 0,
    'dsp': 'not available until N2 (native DSP)',
    'audio': 'not available until N2 (native audio)',
    'sampleRate': 0,
  };

  final StreamController<FftRow> _rows = StreamController<FftRow>.broadcast();

  // ---------------------------------------------------------------------
  // Serialization of native commands
  // ---------------------------------------------------------------------

  /// Runs [action] after every previously queued native/state action has
  /// finished, never concurrently with another one.
  Future<void> _serial(void Function() action) {
    final result = _chain.then((_) {
      if (_disposed) return;
      action();
    });
    _chain = result.catchError((Object _) {});
    return result;
  }

  // ---------------------------------------------------------------------
  // Device identity helpers
  // ---------------------------------------------------------------------

  static String _idOf(SdrHostUsbDevice d) {
    final vid = d.vendorId.toRadixString(16).padLeft(4, '0');
    final pid = d.productId.toRadixString(16).padLeft(4, '0');
    final serial = d.serial;
    final key = (serial != null && serial.isNotEmpty) ? serial : d.path;
    return 'hostusb:$vid:$pid:$key';
  }

  static SdrDeviceInfo _infoOf(SdrHostUsbDevice d) {
    final kind = usbSdrKind(d.vendorId, d.productId);
    final (fMin, fMax) = usbSdrFrequencyRange(kind);
    return SdrDeviceInfo(
      id: _idOf(d),
      name: usbSdrDisplayName(
        vid: d.vendorId,
        pid: d.productId,
        manufacturer: d.manufacturer,
        product: d.product,
        serial: d.serial,
      ),
      sampleRates: usbSdrSampleRates(kind),
      gain: usbSdrGainRange(kind),
      // ABI 2 has no AGC control at all.
      hasAgc: false,
      minFrequency: fMin,
      maxFrequency: fMax,
    );
  }

  static int _sourceIdFor(SdrHostUsbDevice d) =>
      usbSdrKind(d.vendorId, d.productId) == UsbSdrKind.hackrf
      ? SdrSourceId.hackrf
      : SdrSourceId.rtlsdr;

  // ---------------------------------------------------------------------
  // Hotplug polling
  // ---------------------------------------------------------------------

  Future<void> _poll() => _serial(() {
    List<SdrHostUsbDevice> raw;
    try {
      raw = _core.hostUsbDevices();
    } catch (e) {
      _lastError = 'USB enumeration failed: $e';
      notifyListeners();
      return;
    }
    final supported = <SdrHostUsbDevice>[
      for (final d in raw)
        if (isSupportedUsbSdr(d.vendorId, d.productId)) d,
    ];
    final newMap = <String, SdrHostUsbDevice>{
      for (final d in supported) _idOf(d): d,
    };
    final oldIds = _deviceMap.keys.toSet();
    final newIds = newMap.keys.toSet();
    final attached = newIds.difference(oldIds);
    final detached = oldIds.difference(newIds);

    _deviceMap
      ..clear()
      ..addAll(newMap);
    final newDevices = <SdrDeviceInfo>[for (final d in supported) _infoOf(d)];
    final devicesChanged = !_sameIds(_devices, newDevices);
    _devices = newDevices;

    if (_openedId != null && detached.contains(_openedId)) {
      _handleDeviceLost();
    }

    if (attached.isNotEmpty) {
      // A new attach always deserves a fresh try, even after a user Stop or
      // a previous automatic failure (spec: "a NEW attach" lifts both).
      _userStopped = false;
      _autoFailedId = null;
    }

    if (devicesChanged) notifyListeners();

    _maybeAutoStart();
  });

  static bool _sameIds(List<SdrDeviceInfo> a, List<SdrDeviceInfo> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void _maybeAutoStart() {
    if (!autoStart || _userStopped || _instance != null || _disposed) return;
    if (_devices.isEmpty) {
      // disconnected/permissionDenied/failed are sticky until a device comes
      // back or the user acts; only a never-connected session idles into
      // "waiting".
      if (_link != DeviceLinkState.permissionDenied &&
          _link != DeviceLinkState.failed &&
          _link != DeviceLinkState.disconnected) {
        _link = DeviceLinkState.waiting;
      }
      return;
    }
    final target = (_selectedId != null && _deviceMap.containsKey(_selectedId))
        ? _selectedId!
        : _devices.first.id;
    if (target == _autoFailedId) return; // don't spam a known-bad device
    _startOnDevice(target);
  }

  // ---------------------------------------------------------------------
  // Devices
  // ---------------------------------------------------------------------

  @override
  List<SdrDeviceInfo> get devices => _devices;

  @override
  SdrDeviceInfo? get selectedDevice {
    final id = _selectedId;
    if (id == null) return null;
    return _devices.where((d) => d.id == id).firstOrNull;
  }

  @override
  Future<void> selectDevice(SdrDeviceInfo device) => _serial(() {
    if (_running || _disposed || !_devices.contains(device)) return;
    _selectedId = device.id;
    _autoFailedId = null;
    if (!device.sampleRates.contains(_sampleRate) &&
        device.sampleRates.isNotEmpty) {
      _sampleRate = device.sampleRates.reduce(
        (a, b) => (a - _sampleRate).abs() <= (b - _sampleRate).abs() ? a : b,
      );
    }
    _gain = _gain.clamp(device.gain.min, device.gain.max).toDouble();
    _saveConfigSafe();
    notifyListeners();
  });

  @override
  Future<void> refreshDevices() => _poll();

  @override
  Future<void> retryDevice() => _serial(() {
    if (_running || _disposed) return;
    _userStopped = false;
    _autoFailedId = null;
    if (_devices.isEmpty) {
      _link = DeviceLinkState.waiting;
      notifyListeners();
      return;
    }
    final target = (_selectedId != null && _deviceMap.containsKey(_selectedId))
        ? _selectedId!
        : _devices.first.id;
    _startOnDevice(target);
  });

  // ---------------------------------------------------------------------
  // Play / stop
  // ---------------------------------------------------------------------

  @override
  bool get running => _running;
  @override
  String? get lastError => _lastError;

  @override
  Future<void> start() => _serial(() {
    if (_running || _disposed) return;
    _userStopped = false;
    _autoFailedId = null;
    if (_devices.isEmpty) {
      _lastError = 'No device';
      _link = DeviceLinkState.waiting;
      notifyListeners();
      return;
    }
    final target = (_selectedId != null && _deviceMap.containsKey(_selectedId))
        ? _selectedId!
        : _devices.first.id;
    _startOnDevice(target);
  });

  @override
  Future<void> stop() => _serial(() {
    _userStopped = true;
    _autoFailedId = null;
    if (_instance != null) _closeInstanceSync();
    _running = false;
    _link = DeviceLinkState.stoppedByUser;
    notifyListeners();
  });

  void _startOnDevice(String id) {
    final dev = _deviceMap[id];
    if (dev == null) {
      _lastError = 'Device no longer present';
      _link = DeviceLinkState.disconnected;
      notifyListeners();
      return;
    }
    if (_instance != null) _closeInstanceSync();
    final info = _infoOf(dev);
    _selectedId = id;
    _link = DeviceLinkState.connecting;
    notifyListeners();

    SdrCoreInstance inst;
    try {
      inst = _core.create();
    } catch (e) {
      _lastError = 'Cannot open ${info.name}: $e';
      _link = DeviceLinkState.failed;
      _autoFailedId = id;
      notifyListeners();
      return;
    }

    final tuned = (_centerFrequency + _vfoOffset).clamp(
      info.minFrequency,
      info.maxFrequency,
    );
    final rate = info.sampleRates.contains(_sampleRate)
        ? _sampleRate
        : (info.sampleRates.isNotEmpty ? info.sampleRates.first : _sampleRate);
    final gain = info.gain.max > info.gain.min
        ? _gain.clamp(info.gain.min, info.gain.max)
        : _gain;

    try {
      inst.openHostUsb(dev.bus, dev.address, _sourceIdFor(dev));
      inst.configure(tuned.round(), rate.round(), (gain * 10).round());
      inst.start();
    } on SdrCoreError catch (e) {
      _mapOpenError(e.code, info);
      _autoFailedId = id;
      inst.dispose();
      notifyListeners();
      return;
    } catch (e) {
      _lastError = 'Cannot open ${info.name}: native error $e';
      _link = DeviceLinkState.failed;
      _autoFailedId = id;
      inst.dispose();
      notifyListeners();
      return;
    }

    _instance = inst;
    _openedId = id;
    _running = true;
    _lastError = null;
    _link = DeviceLinkState.receiving;
    _autoFailedId = null;
    _sampleRate = rate.toDouble();
    _gain = gain.toDouble();
    _centerFrequency = tuned.toDouble();
    _vfoOffset = 0;
    _resetStatsBookkeeping();
    _startStatsTimer();
    _saveConfigSafe();
    notifyListeners();
  }

  void _mapOpenError(int code, SdrDeviceInfo info) {
    switch (code) {
      case SdrResult.hostAccessDenied:
        _link = DeviceLinkState.permissionDenied;
        _lastError =
            'No access to ${info.name}: check /dev/bus/usb permissions '
            '(add your user to the plugdev group, or install the '
            '60-librtlsdr0.rules udev rule)';
      case SdrResult.hostNotFound:
      case SdrResult.deviceGone:
        _link = DeviceLinkState.disconnected;
        _lastError = '${info.name} not found (unplugged?)';
      default:
        _link = DeviceLinkState.failed;
        _lastError = 'Cannot open ${info.name}: native error $code';
    }
  }

  void _closeInstanceSync() {
    final inst = _instance;
    _instance = null;
    _openedId = null;
    _stopStatsTimer();
    if (inst != null) {
      try {
        inst.stop();
      } catch (_) {}
      try {
        inst.close();
      } catch (_) {}
      inst.dispose();
    }
    _statsCache = <String, Object?>{
      ..._statsCache,
      'state': 'idle',
      'device': null,
    };
  }

  void _handleDeviceLost() {
    if (_instance == null) return;
    _closeInstanceSync();
    _running = false;
    if (!_userStopped) _link = DeviceLinkState.disconnected;
    notifyListeners();
  }

  @override
  DeviceLinkState get linkState => _running ? DeviceLinkState.receiving : _link;

  // ---------------------------------------------------------------------
  // Stats polling / error detection
  // ---------------------------------------------------------------------

  void _startStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(statsInterval, (_) => _serial(_pollStatsTick));
  }

  void _stopStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  void _resetStatsBookkeeping() {
    _lastStatsTime = null;
    _lastStatsInputSamples = 0;
  }

  void _pollStatsTick() {
    final inst = _instance;
    if (inst == null) return;
    SdrCoreStats s;
    try {
      s = inst.stats;
    } catch (e) {
      _lastError = 'stats failed: $e';
      notifyListeners();
      return;
    }
    _updateStatsCache(s);
    if (s.state == SdrState.error) {
      _lastError = 'Device error: native error ${s.lastError}';
      _handleDeviceLost();
    } else {
      notifyListeners();
    }
  }

  void _updateStatsCache(SdrCoreStats s) {
    final now = DateTime.now();
    int rate = (_statsCache['inputRate'] as int?) ?? 0;
    final last = _lastStatsTime;
    if (last != null) {
      final dtMs = now.difference(last).inMilliseconds;
      if (dtMs > 0) {
        rate = ((s.inputSamples - _lastStatsInputSamples) * 1000 / dtMs)
            .round();
      }
    }
    _lastStatsTime = now;
    _lastStatsInputSamples = s.inputSamples;
    final dev = _openedId == null ? null : _deviceMap[_openedId]?.path;
    _statsCache = <String, Object?>{
      'engine': 'native IQ (Linux host)',
      'device': dev,
      'state': _stateName(s.state),
      'inputSamples': s.inputSamples,
      'processedSamples': s.processedSamples,
      'ringDrops': s.droppedSamples,
      'inputRate': rate,
      'lastNativeError': s.lastError,
      'dsp': 'not available until N2 (native DSP)',
      'audio': 'not available until N2 (native audio)',
      'sampleRate': s.sampleRate,
    };
  }

  static String _stateName(int state) => switch (state) {
    SdrState.idle => 'idle',
    SdrState.open => 'open',
    SdrState.running => 'running',
    SdrState.error => 'error',
    _ => 'unknown',
  };

  @override
  Map<String, Object?> get stats => _statsCache;

  @override
  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Frequency / VFO
  // ---------------------------------------------------------------------

  @override
  double get centerFrequency => _centerFrequency;
  @override
  double get vfoOffset => _vfoOffset;

  @override
  void setTuning({required double centerFrequency, required double vfoOffset}) {
    if (centerFrequency == _centerFrequency && vfoOffset == _vfoOffset) return;
    _centerFrequency = centerFrequency;
    _vfoOffset = vfoOffset;
    notifyListeners();
    _saveConfigSafe();
    if (_running) _scheduleApply();
  }

  void _scheduleApply() {
    _applyTimer?.cancel();
    _applyTimer = Timer(retuneDebounce, () {
      _applyTimer = null;
      _serial(_applyPending);
    });
  }

  /// Applies the current tuning/gain to the running device: stop ->
  /// configure -> start (ABI 2 has no live retune). Also recenters the VFO
  /// (AGENTS.md invariant: at rest centerFrequency == tunedFrequency and
  /// vfoOffset == 0).
  void _applyPending() {
    if (_disposed || !_running || _instance == null) return;
    final info = selectedDevice;
    var tuned = _centerFrequency + _vfoOffset;
    var gain = _gain;
    if (info != null) {
      tuned = tuned.clamp(info.minFrequency, info.maxFrequency);
      gain = gain.clamp(info.gain.min, info.gain.max);
    }
    final inst = _instance!;
    try {
      inst.stop();
      _centerFrequency = tuned.toDouble();
      _vfoOffset = 0;
      _gain = gain.toDouble();
      inst.configure(
        _centerFrequency.round(),
        _sampleRate.round(),
        (_gain * 10).round(),
      );
      inst.start();
      _lastError = null;
      _resetStatsBookkeeping();
    } on SdrCoreError catch (e) {
      _lastError = 'Retune failed: native error ${e.code}';
      _link = DeviceLinkState.failed;
      _running = false;
      _closeInstanceSync();
    } catch (e) {
      _lastError = 'Retune failed: $e';
    }
    _saveConfigSafe();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Demodulator
  // ---------------------------------------------------------------------

  @override
  DemodMode get mode => _mode;

  @override
  void setMode(DemodMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    _bandwidth = mode.params.defaultBandwidth;
    _saveConfigSafe();
    notifyListeners();
  }

  @override
  double get bandwidth => _bandwidth;

  @override
  void setBandwidth(double hz) {
    final bw = _mode.params.clampBandwidth(hz);
    if (bw == _bandwidth) return;
    _bandwidth = bw;
    _saveConfigSafe();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Source
  // ---------------------------------------------------------------------

  @override
  double get sampleRate => _sampleRate;

  @override
  void setSampleRate(double hz) {
    if (_running) return; // no live rate change; ignored while running
    final info = selectedDevice;
    if (info != null && !info.sampleRates.contains(hz)) return;
    if (hz == _sampleRate) return;
    _sampleRate = hz;
    _saveConfigSafe();
    notifyListeners();
  }

  @override
  double get gain => _gain;

  @override
  void setGain(double value) {
    final info = selectedDevice;
    final g = info != null
        ? value.clamp(info.gain.min, info.gain.max).toDouble()
        : value;
    if (g == _gain) return;
    _gain = g;
    notifyListeners();
    _saveConfigSafe();
    if (_running) _scheduleApply();
  }

  @override
  bool get agc => false;

  @override
  void setAgc(bool enabled) {
    // ABI 2 exposes no AGC control; always false, nothing to apply.
  }

  // ---------------------------------------------------------------------
  // Audio (no native audio until N2: stored only, like squelch below)
  // ---------------------------------------------------------------------

  @override
  double get volume => _volume;

  @override
  void setVolume(double value) {
    final v = value.clamp(0.0, 1.0).toDouble();
    if (v == _volume) return;
    _volume = v;
    notifyListeners();
  }

  @override
  bool get muted => _muted;

  @override
  void setMuted(bool muted) {
    if (muted == _muted) return;
    _muted = muted;
    notifyListeners();
  }

  @override
  bool get squelchEnabled => _squelchEnabled;

  @override
  void setSquelchEnabled(bool enabled) {
    if (enabled == _squelchEnabled) return;
    _squelchEnabled = enabled;
    notifyListeners();
  }

  @override
  double get squelchLevel => _squelchLevel;

  @override
  void setSquelchLevel(double db) {
    final v = db.clamp(-100.0, 0.0).toDouble();
    if (v == _squelchLevel) return;
    _squelchLevel = v;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // FFT — no native FFT until N2: the stream never emits.
  // ---------------------------------------------------------------------

  @override
  Stream<FftRow> get fftRows => _rows.stream;

  @override
  void setFftWidth(int pixels) {}

  @override
  void setFftView({
    required double viewOffset,
    required double viewBandwidth,
  }) {}

  // ---------------------------------------------------------------------
  // Diagnostics
  // ---------------------------------------------------------------------

  /// Snapshot used by the headless hardware test harness.
  Map<String, Object?> diagnosticsSnapshot() => <String, Object?>{
    ...stats,
    'centerFrequency': _centerFrequency,
    'vfoOffset': _vfoOffset,
    'gain': _gain,
    'sampleRate': _sampleRate,
    'mode': _mode.label,
    'running': _running,
    'linkState': linkState.name,
  };

  // ---------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------

  void _loadDefaults() {
    _centerFrequency = 100000000;
    _vfoOffset = 0;
    _mode = DemodMode.wfm;
    _bandwidth = DemodMode.wfm.params.defaultBandwidth;
    _sampleRate = 2400000;
    _gain = 20;
  }

  void _loadConfig() {
    _loadDefaults();
    final dir = configDir;
    if (dir == null) return;
    try {
      final file = File('$dir/$_configFileName');
      if (!file.existsSync()) return;
      final data = jsonDecode(file.readAsStringSync());
      if (data is! Map) return;
      final freq = (data['frequency'] as num?)?.toDouble();
      if (freq != null) _centerFrequency = freq;
      final rate = (data['sampleRate'] as num?)?.toDouble();
      if (rate != null) _sampleRate = rate;
      final gain = (data['gain'] as num?)?.toDouble();
      if (gain != null) _gain = gain;
      final modeMap = data['mode'];
      if (modeMap is Map && modeMap['id'] is num) {
        _mode = DemodMode.fromId((modeMap['id'] as num).toInt());
      }
      final bw = (data['bandwidth'] as num?)?.toDouble();
      _bandwidth = bw != null
          ? _mode.params.clampBandwidth(bw)
          : _mode.params.defaultBandwidth;
    } catch (_) {
      // Corrupt file: keep defaults, never throw.
      _loadDefaults();
    }
  }

  void _saveConfigSafe() {
    final dir = configDir;
    if (dir == null) return;
    try {
      final d = Directory(dir);
      d.createSync(recursive: true);
      final file = File('$dir/$_configFileName');
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'frequency': _centerFrequency + _vfoOffset,
          'sampleRate': _sampleRate,
          'gain': _gain,
          'mode': <String, Object?>{'id': _mode.id, 'label': _mode.label},
          'bandwidth': _bandwidth,
        }),
      );
    } catch (_) {
      // Never throw from a save.
    }
  }

  // ---------------------------------------------------------------------

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _applyTimer?.cancel();
    _closeInstanceSync();
    _rows.close();
    super.dispose();
  }
}

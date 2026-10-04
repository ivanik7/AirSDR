// SPDX-License-Identifier: GPL-3.0-or-later
// One v3 handle, one VFO and one audio stream. The UI polls only bounded
// snapshots and latest-only, screen-width FFT rows; samples never reach Dart.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import '../runtime/device_sources.dart';
import '../sdrpp/modules/sources/usb_source_factory.dart';
import '../ui/radio_controller.dart';
import '../usb/usb_device_provider.dart';
import 'native_radio_api.dart';
import 'native_radio_settings.dart';
import 'sdr_core.dart';

final class NativeDevice {
  const NativeDevice(this.info, this.source, {this.bus, this.address, this.fd});
  final SdrDeviceInfo info;
  final int source;
  final int? bus, address, fd;
}

/// Provides the exclusive borrowed USB fd (Android), host address (Linux),
/// or synthetic source. open/close must not be shared with the Dart engine.
abstract interface class NativeDeviceSource {
  Stream<void> get changes;
  Future<List<NativeDevice>> list();
  Future<NativeDevice> open(NativeDevice device);
  Future<void> close(NativeDevice device);
}

class HostNativeDeviceSource implements NativeDeviceSource {
  HostNativeDeviceSource(this.api);
  final NativeRadioApi api;
  @override
  Stream<void> get changes => const Stream<void>.empty();
  @override
  Future<List<NativeDevice>> list() async => [
    for (final d in api.hostDevices())
      if (isSupportedUsbSdr(d.vendorId, d.productId)) _convert(d),
  ];
  NativeDevice _convert(SdrHostUsbDevice d) {
    final kind = usbSdrKind(d.vendorId, d.productId);
    final (lo, hi) = usbSdrFrequencyRange(kind);
    return NativeDevice(
      SdrDeviceInfo(
        id: 'hostusb:${d.vendorId}:${d.productId}:${d.serial ?? d.path}',
        name: usbSdrDisplayName(
          vid: d.vendorId,
          pid: d.productId,
          manufacturer: d.manufacturer,
          product: d.product,
          serial: d.serial,
        ),
        sampleRates: usbSdrSampleRates(kind),
        gain: usbSdrGainRange(kind),
        hasAgc: false,
        minFrequency: lo,
        maxFrequency: hi,
      ),
      kind == UsbSdrKind.hackrf ? SdrSourceId.hackrf : SdrSourceId.rtlsdr,
      bus: d.bus,
      address: d.address,
    );
  }

  @override
  Future<NativeDevice> open(NativeDevice device) async => device;
  @override
  Future<void> close(NativeDevice device) async {}
}

class AndroidNativeDeviceSource implements NativeDeviceSource {
  AndroidNativeDeviceSource(this.provider);
  final UsbDeviceProvider provider;
  final Map<String, NativeDevice> _known = {};
  @override
  Stream<void> get changes => provider.changes;
  @override
  Future<List<NativeDevice>> list() async {
    final devices = await provider.listDevices();
    _known.clear();
    for (final info in devices) {
      // Device kind is determined after permission by the provider's VID/PID.
      _known[info.id] = NativeDevice(info, 0);
    }
    return _known.values.toList();
  }

  @override
  Future<NativeDevice> open(NativeDevice device) async {
    final result = await provider.open(device.info);
    final params = result.params;
    final kind = usbSdrKind(
      (params['vid'] as num).toInt(),
      (params['pid'] as num).toInt(),
    );
    return NativeDevice(
      device.info,
      kind == UsbSdrKind.hackrf ? SdrSourceId.hackrf : SdrSourceId.rtlsdr,
      fd: (params['fd'] as num).toInt(),
    );
  }

  @override
  Future<void> close(NativeDevice device) => provider.close(device.info);
}

class NativeRadioController extends RadioController {
  NativeRadioController({
    required this.api,
    required this.source,
    this.autoStart = true,
    this.pollInterval = const Duration(milliseconds: 200),
    this.fftInterval = const Duration(milliseconds: 34),
    this.discoveryInterval = const Duration(seconds: 1),
    this.audioSink = 'null',
    this.beforeStart,
    this.afterStop,
    this.configDir,
  }) {
    if (Platform.isAndroid && (beforeStart == null || afterStop == null)) {
      throw StateError(
        'Android native reception requires service ownership hooks',
      );
    }
    final dir = configDir;
    if (dir != null) {
      // Synchronous load, before the first refreshDevices()/autostart, so
      // the first native start already uses the persisted configuration.
      final settings = loadNativeRadioSettings(dir);
      _center = settings.tunedFrequencyHz;
      _offset = 0;
      _rate = settings.sampleRateHz;
      _gain = settings.gainDb;
      _mode = settings.mode;
      _bandwidthByMode = Map<int, double>.from(settings.bandwidthByMode);
      _bandwidth = _mode.params.clampBandwidth(
        _bandwidthByMode[_mode.id] ?? _mode.params.defaultBandwidth,
      );
      _squelch = SquelchType.fromKey(settings.squelchKey);
      _squelchLevel = settings.squelchLevelDb;
      _autoOffset = settings.autoOffsetDb;
      // _muted is never restored: every session starts muted.
    }
    _sub = source.changes.listen((_) => unawaited(refreshDevices()));
    unawaited(refreshDevices());
    _discovery = Timer.periodic(
      discoveryInterval,
      (_) => unawaited(refreshDevices()),
    );
  }

  final NativeRadioApi api;
  final NativeDeviceSource source;
  final bool autoStart;
  final Duration pollInterval, fftInterval, discoveryInterval;
  final String audioSink;

  /// Settings persistence directory. Null = in-memory only, no file IO
  /// (used by tests and whenever the caller has no app support directory).
  final String? configDir;

  /// Android: await foreground promotion and audio focus before v3_start.
  final Future<void> Function()? beforeStart;

  /// Android: release foreground owner after stop/close of the native handle.
  final Future<void> Function()? afterStop;
  StreamSubscription<void>? _sub;
  Timer? _discovery, _snapshotTimer, _fftTimer;
  Future<void> _chain = Future<void>.value();
  final StreamController<FftRow> _rows = StreamController<FftRow>.broadcast();
  bool _disposed = false, _running = false, _userStopped = false;
  String? _failedId;
  DeviceLinkState _link = DeviceLinkState.waiting;
  String? _lastError;
  List<NativeDevice> _known = [];
  NativeDevice? _selected, _opened;
  Pointer<SdrHandle>? _handle;
  int _generation = 0, _controlSequence = 0, _lastRow = 0;
  int _lastErrorSequence = 0;
  int _lastInput = 0;
  DateTime? _lastSnapshotAt;
  AutoSquelchStatus? _squelchStatus;
  NativeControls? _appliedControls;
  NativeDisplay? _appliedDisplay;
  Map<String, Object?> _stats = const {};

  double _center = 100000000, _offset = 0, _rate = 2400000, _gain = 20;
  double _bandwidth = DemodMode.wfm.params.defaultBandwidth;
  // Last bandwidth used in each mode (DemodMode.id -> Hz), restored by
  // setMode instead of always resetting to the mode default.
  Map<int, double> _bandwidthByMode = <int, double>{};
  double _volume = 1.0, _squelchLevel = -50, _autoOffset = 0;
  int _fftWidth = 512;
  double _viewOffset = 0, _viewBandwidth = 2400000;
  DemodMode _mode = DemodMode.wfm;
  SquelchType _squelch = SquelchType.off;
  bool _muted = true, _agc = false;
  Timer? _saveTimer;
  static const Duration _saveDebounce = Duration(milliseconds: 500);

  Future<void> _queue(Future<void> Function() action) {
    final result = _chain.then((_) async {
      if (!_disposed) await action();
    });
    _chain = result.catchError((Object _) {});
    return result;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Debounces a settings-file write ([_saveDebounce] after the last
  /// persisted-field change); never fires while [configDir] is null.
  void _scheduleSave() {
    if (configDir == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _flushSave);
  }

  /// Writes the settings file synchronously (temp + rename) and cancels any
  /// pending debounce. Safe to call with no pending change or no [configDir].
  void _flushSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final dir = configDir;
    if (dir == null) return;
    // The current mode's bandwidth always wins over whatever is cached in
    // _bandwidthByMode, so a control rejection (which reverts _mode/_bandwidth
    // but not necessarily the map) can never persist a stale value.
    final bandwidthByMode = Map<int, double>.from(_bandwidthByMode)
      ..[_mode.id] = _bandwidth;
    saveNativeRadioSettingsSync(
      dir,
      NativeRadioSettings(
        tunedFrequencyHz: _center + _offset,
        modeId: _mode.id,
        bandwidthByMode: bandwidthByMode,
        sampleRateHz: _rate,
        gainDb: _gain,
        squelchKey: _squelch.key,
        squelchLevelDb: _squelchLevel,
        autoOffsetDb: _autoOffset,
      ),
    );
  }

  void _failure(Object error, {bool disconnected = false}) {
    _lastError = '$error';
    _link = disconnected
        ? DeviceLinkState.disconnected
        : DeviceLinkState.failed;
    _running = false;
    _squelchStatus = null;
    _notify();
  }

  @override
  List<SdrDeviceInfo> get devices => [for (final d in _known) d.info];
  @override
  SdrDeviceInfo? get selectedDevice => _selected?.info;
  @override
  Future<void> refreshDevices() => _queue(() async {
    List<NativeDevice> devices;
    try {
      devices = await source.list();
    } catch (e) {
      _failure('Device enumeration failed: $e');
      return;
    }
    final old = _known.map((e) => e.info.id).toSet();
    final next = devices.map((e) => e.info.id).toSet();
    final added = next.difference(old).isNotEmpty;
    _known = devices;
    if (_opened != null && !next.contains(_opened!.info.id)) {
      await _release();
      _failure('Device disconnected', disconnected: true);
    }
    if (_selected != null && !next.contains(_selected!.info.id)) {
      _selected = null;
    }
    _selected ??= _known.firstOrNull;
    if (added) {
      _userStopped = false;
      _failedId = null;
    }
    if (_selected == null && _link == DeviceLinkState.waiting) _notify();
    _notify();
    if (autoStart &&
        !_userStopped &&
        !_running &&
        _handle == null &&
        _selected != null &&
        _selected!.info.id != _failedId) {
      await _startLocked();
    }
  });
  @override
  Future<void> selectDevice(SdrDeviceInfo device) => _queue(() async {
    if (_running) return;
    final match = _known.where((d) => d.info.id == device.id).firstOrNull;
    if (match == null) return;
    await _release();
    _selected = match;
    if (!match.info.sampleRates.contains(_rate)) {
      _rate = match.info.sampleRates.firstOrNull ?? _rate;
    }
    _gain = _gain.clamp(match.info.gain.min, match.info.gain.max).toDouble();
    _agc = false;
    _failedId = null;
    _notify();
  });
  @override
  Future<void> retryDevice() => start();
  @override
  bool get running => _running;
  @override
  String? get lastError => _lastError;
  @override
  DeviceLinkState get linkState => _running ? DeviceLinkState.receiving : _link;
  @override
  Future<void> start() => _queue(() async {
    _userStopped = false;
    _failedId = null;
    if (_selected == null) {
      _link = DeviceLinkState.waiting;
      _lastError = 'No device';
      _notify();
      return;
    }
    if (!_running) await _startLocked();
  });
  Future<void> _startLocked() async {
    final selected = _selected;
    if (selected == null) return;
    _link = DeviceLinkState.connecting;
    _notify();
    try {
      // Cold start centers the single VFO, preserving the tuned frequency.
      _center += _offset;
      _offset = 0;
      final opened = await source.open(selected);
      _opened = opened;
      if (_disposed || _userStopped) throw StateError('Native start cancelled');
      final h = api.create();
      _handle = h;
      if (opened.fd != null) {
        api.openUsb(h, opened.fd!, opened.source);
      } else if (opened.bus != null && opened.address != null) {
        api.openHostUsb(h, opened.bus!, opened.address!, opened.source);
      } else {
        api.openSynthetic(h, _rate.round());
      }
      _appliedControls = _controls();
      api.controls(h, _appliedControls!);
      _appliedDisplay = _display();
      api.display(h, _appliedDisplay!);
      api.audioSink(h, audioSink);
      await beforeStart?.call();
      if (_disposed || _userStopped) throw StateError('Native start cancelled');
      api.start(h);
      final s = api.snapshot(h);
      _generation = s.generation;
      _controlSequence = s.controlSequence;
      _lastErrorSequence = s.errorSequence;
      _lastRow = 0;
      _running = true;
      _link = DeviceLinkState.receiving;
      _lastError = null;
      _failedId = null;
      _squelchStatus = null;
      _startPollers();
      _notify();
    } catch (e) {
      _failedId = selected.info.id;
      await _release();
      _failure('Native start failed: $e');
    }
  }

  @override
  Future<void> stop() {
    _userStopped = true;
    _link = DeviceLinkState.stoppedByUser;
    _flushSave();
    _notify();
    return _queue(() async {
      await _release();
      _link = DeviceLinkState.stoppedByUser;
      _notify();
    });
  }

  Future<void> _release() async {
    _snapshotTimer?.cancel();
    _fftTimer?.cancel();
    _snapshotTimer = null;
    _fftTimer = null;
    final h = _handle;
    _handle = null;
    _running = false;
    _generation = 0;
    _controlSequence = 0;
    _lastRow = 0;
    _squelchStatus = null;
    _appliedControls = null;
    _appliedDisplay = null;
    if (h != null) {
      try {
        api.stop(h);
      } catch (_) {}
      try {
        api.close(h);
      } catch (_) {}
      api.destroy(h);
    }
    final opened = _opened;
    _opened = null;
    if (opened != null) await source.close(opened);
    if (h != null) await afterStop?.call();
  }

  void _startPollers() {
    _snapshotTimer?.cancel();
    _fftTimer?.cancel();
    _snapshotTimer = Timer.periodic(pollInterval, (_) => _pollSnapshot());
    _fftTimer = Timer.periodic(fftInterval, (_) => _pollFft());
  }

  void _pollSnapshot() {
    // Never queue every missed tick; this synchronous read cannot build backlog.
    final h = _handle;
    if (!_running || h == null) return;
    try {
      final s = api.snapshot(h);
      if (s.errorSequence != _lastErrorSequence && s.lastError != 0) {
        _lastErrorSequence = s.errorSequence;
        _lastError = 'Native error ${s.lastError}';
      }
      if (s.state == SdrState.error) {
        final lost = s.lastError == SdrResult.deviceGone;
        _running = false;
        _failedId = _selected?.info.id;
        _snapshotTimer?.cancel();
        _fftTimer?.cancel();
        unawaited(
          _queue(() async {
            await _release();
            _failure('Native error ${s.lastError}', disconnected: lost);
          }),
        );
        return;
      }
      if (s.state != SdrState.running) return;
      if (s.generation != _generation ||
          s.controlSequence != _controlSequence) {
        // Only a successful serialized control command may advance our
        // accepted epoch. An unexpected native restart must not make old
        // squelch decisions or future FFT rows appear current.
        _squelchStatus = null;
      }
      if (s.generation == _generation &&
          s.controlSequence == _controlSequence &&
          _squelch == SquelchType.auto &&
          s.squelchReady &&
          s.centerHz == _center.round() &&
          s.offsetHz == _offset.round() &&
          s.mode == _mode.id) {
        _squelchStatus = AutoSquelchStatus(
          open: s.squelchOpen,
          metricDb: s.squelchMetricDb,
          thresholdDb: s.squelchThresholdDb,
        );
      }
      final now = DateTime.now();
      final elapsed = _lastSnapshotAt == null
          ? 0
          : now.difference(_lastSnapshotAt!).inMilliseconds;
      final rate = elapsed > 0
          ? ((s.inputSamples - _lastInput) * 1000 / elapsed).round()
          : 0;
      _lastSnapshotAt = now;
      _lastInput = s.inputSamples;
      _stats = {
        'engine': 'native DSP',
        'state': 'running',
        'sampleRate': s.sampleRate,
        'inputRate': rate,
        'inputSamples': s.inputSamples,
        'processedSamples': s.processedSamples,
        'ringDrops': s.droppedSamples,
        'audioFrames': s.audioFrames,
        'audioDroppedFrames': s.audioDroppedFrames,
        'audioNonsilentFrames': s.audioNonsilentFrames,
        'fftOverwrites': s.fftOverwrites,
        'lastNativeError': s.lastError,
      };
      _notify();
    } catch (e) {
      unawaited(
        _queue(() async {
          await _release();
          _failure(e);
        }),
      );
    }
  }

  void _pollFft() {
    if (!_running || !_rows.hasListener || _handle == null) return;
    try {
      final row = api.fft(_handle!, _lastRow);
      if (row == null) return;
      _lastRow = row.sequence;
      if (row.generation != _generation ||
          row.controlSequence != _controlSequence ||
          row.bins.length > nativeMaxFftWidth ||
          row.bins.length > _fftWidth ||
          row.lowHz >= row.highHz) {
        return;
      }
      _rows.add(
        FftRow(
          db: row.bins,
          lowFreq: row.lowHz.toDouble(),
          highFreq: row.highHz.toDouble(),
        ),
      );
    } catch (e) {
      unawaited(
        _queue(() async {
          await _release();
          _failure(e);
        }),
      );
    }
  }

  NativeControls _controls() => NativeControls(
    centerHz: _center.round(),
    offsetHz: _offset.round(),
    sampleRate: _rate.round(),
    mode: _mode.id,
    bandwidthHz: _bandwidth.round(),
    gainTenthsDb: (_gain * 10).round(),
    agc: _agc,
    squelch: _squelch.index,
    squelchLevelDb: _squelchLevel,
    autoOffsetDb: _autoOffset,
    volume: _volume,
    muted: _muted,
  );
  NativeDisplay _display() => NativeDisplay(
    _viewOffset.round(),
    _viewBandwidth.round().clamp(1, _rate.round()),
    _fftWidth,
  );
  void _applyControls() {
    final h = _handle;
    if (h == null) return;
    try {
      final desired = _controls();
      api.controls(h, desired);
      _appliedControls = desired;
      final s = api.snapshot(h);
      _generation = s.generation;
      _controlSequence = s.controlSequence;
      _squelchStatus = null;
      _lastRow = 0;
    } catch (e) {
      _lastError = 'Native control failed: $e';
      // Restore every field, including squelch/mute, after a rejected request.
      final previous = _appliedControls;
      if (previous != null) {
        _center = previous.centerHz.toDouble();
        _offset = previous.offsetHz.toDouble();
        _rate = previous.sampleRate.toDouble();
        _mode = DemodMode.fromId(previous.mode);
        _bandwidth = previous.bandwidthHz.toDouble();
        _gain = previous.gainTenthsDb / 10;
        _agc = previous.agc;
        _squelch = SquelchType.values[previous.squelch];
        _squelchLevel = previous.squelchLevelDb;
        _autoOffset = previous.autoOffsetDb;
        _volume = previous.volume;
        _muted = previous.muted;
      }
      _notify();
    }
  }

  void _applyDisplay() {
    final h = _handle;
    if (h == null) return;
    try {
      final desired = _display();
      api.display(h, desired);
      _appliedDisplay = desired;
      _controlSequence = api.snapshot(h).controlSequence;
      _lastRow = 0;
    } catch (e) {
      _lastError = 'Native display failed: $e';
      final previous = _appliedDisplay;
      if (previous != null) {
        _viewOffset = previous.offsetHz.toDouble();
        _viewBandwidth = previous.bandwidthHz.toDouble();
        _fftWidth = previous.width;
      }
      scheduleMicrotask(
        _notify,
      ); // layout callback must not notify synchronously
    }
  }

  @override
  double get centerFrequency => _center;
  @override
  double get vfoOffset => _offset;
  @override
  void setTuning({required double centerFrequency, required double vfoOffset}) {
    if (!centerFrequency.isFinite ||
        !vfoOffset.isFinite ||
        centerFrequency == _center && vfoOffset == _offset) {
      return;
    }
    _center = centerFrequency;
    _offset = vfoOffset;
    _squelchStatus = null;
    _applyControls();
    _scheduleSave();
    _notify();
  }

  @override
  DemodMode get mode => _mode;
  @override
  void setMode(DemodMode mode) {
    if (mode == _mode) return;
    // Remember the outgoing mode's current bandwidth before switching.
    _bandwidthByMode[_mode.id] = _bandwidth;
    _mode = mode;
    _bandwidth = mode.params.clampBandwidth(
      _bandwidthByMode[mode.id] ?? mode.params.defaultBandwidth,
    );
    if (!autoSquelchAvailable && _squelch == SquelchType.auto) {
      _squelch = SquelchType.off;
    }
    _squelchStatus = null;
    _applyControls();
    _scheduleSave();
    _notify();
  }

  @override
  double get bandwidth => _bandwidth;
  @override
  void setBandwidth(double hz) {
    final value = _mode.params.clampBandwidth(hz);
    if (value == _bandwidth) return;
    _bandwidth = value;
    _bandwidthByMode[_mode.id] = value;
    _applyControls();
    _scheduleSave();
    _notify();
  }

  @override
  double get sampleRate => _rate;
  @override
  void setSampleRate(double hz) {
    if (!hz.isFinite ||
        hz == _rate ||
        (_selected != null && !_selected!.info.sampleRates.contains(hz))) {
      return;
    }
    _rate = hz;
    _viewBandwidth = _viewBandwidth.clamp(1, hz).toDouble();
    _applyControls();
    _applyDisplay();
    _scheduleSave();
    _notify();
  }

  @override
  double get gain => _gain;
  @override
  void setGain(double value) {
    final info = _selected?.info;
    final g = info == null
        ? value
        : value.clamp(info.gain.min, info.gain.max).toDouble();
    if (!g.isFinite || g == _gain) return;
    _gain = g;
    _applyControls();
    _scheduleSave();
    _notify();
  }

  @override
  bool get agc => _agc;
  @override
  void setAgc(bool enabled) {
    if (enabled == _agc || (enabled && _selected?.info.hasAgc != true)) return;
    _agc = enabled;
    _applyControls();
    _notify();
  }

  @override
  double get volume => _volume;
  @override
  void setVolume(double value) {
    final v = value.clamp(0.0, 1.0).toDouble();
    if (v == _volume) return;
    _volume = v;
    _applyControls();
    _notify();
  }

  @override
  bool get muted => _muted;
  @override
  void setMuted(bool muted) {
    if (muted == _muted) return;
    _muted = muted;
    _applyControls();
    _notify();
  }

  @override
  bool get squelchEnabled => _squelch != SquelchType.off;
  @override
  void setSquelchEnabled(bool enabled) =>
      setSquelchType(enabled ? SquelchType.manual : SquelchType.off);
  @override
  SquelchType get squelchType => _squelch;
  @override
  void setSquelchType(SquelchType type) {
    if (type == SquelchType.auto && !autoSquelchAvailable) return;
    if (type == _squelch) return;
    _squelch = type;
    _squelchStatus = null;
    _applyControls();
    _scheduleSave();
    _notify();
  }

  @override
  bool get autoSquelchAvailable => _mode.params.autoSquelch != null;
  @override
  double get autoSquelchOffset => _autoOffset;
  @override
  void setAutoSquelchOffset(double db) {
    final value = db.clamp(-10.0, 20.0).toDouble();
    if (value == _autoOffset) return;
    _autoOffset = value;
    _squelchStatus = null;
    _applyControls();
    _scheduleSave();
    _notify();
  }

  @override
  AutoSquelchStatus? get autoSquelchStatus => _running ? _squelchStatus : null;
  @override
  double get squelchLevel => _squelchLevel;
  @override
  void setSquelchLevel(double db) {
    final value = db.clamp(-100.0, 0.0).toDouble();
    if (value == _squelchLevel) return;
    _squelchLevel = value;
    _applyControls();
    _scheduleSave();
    _notify();
  }

  @override
  Stream<FftRow> get fftRows => _rows.stream;
  @override
  void setFftWidth(int pixels) {
    final width = pixels.clamp(1, nativeMaxFftWidth);
    if (width == _fftWidth) return;
    _fftWidth = width;
    _applyDisplay(); // no layout-time notifyListeners
  }

  @override
  void setFftView({required double viewOffset, required double viewBandwidth}) {
    if (!viewOffset.isFinite || !viewBandwidth.isFinite || viewBandwidth <= 0) {
      return;
    }
    if (viewOffset == _viewOffset && viewBandwidth == _viewBandwidth) return;
    _viewOffset = viewOffset;
    _viewBandwidth = viewBandwidth;
    _applyDisplay(); // no layout-time notifyListeners
  }

  @override
  Map<String, Object?> get stats => _stats;
  @override
  void clearError() {
    _lastError = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _discovery?.cancel();
    _snapshotTimer?.cancel();
    _fftTimer?.cancel();
    _flushSave();
    unawaited(_sub?.cancel());
    // Synchronous native teardown must precede handle destruction. The async
    // Android provider closure is chained after that; service owner owns final fd.
    final h = _handle;
    _handle = null;
    if (h != null) {
      try {
        api.stop(h);
      } catch (_) {}
      try {
        api.close(h);
      } catch (_) {}
      api.destroy(h);
    }
    final opened = _opened;
    if (opened != null || h != null) {
      unawaited(() async {
        if (opened != null) await source.close(opened);
        if (h != null) await afterStop?.call();
      }());
    }
    _rows.close();
    super.dispose();
  }
}

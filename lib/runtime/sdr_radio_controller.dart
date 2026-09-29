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
//  * Auto-connect / hot re-plug (providers with [DeviceProvider.autoConnect], i.e. USB SDRs):
//      - cold start: the first supported device found is opened (Android permission dialog)
//        and reception starts without Start;
//      - a newly attached device (or the one that launched the app) does the same;
//      - device lost (fatal source error / detach): the DSP source is released (the audio
//        device with it), the state becomes [DeviceLinkState.disconnected]; a re-attached
//        device resumes with the same tuning/mode/gain/volume/squelch/mute;
//      - permission refused: [DeviceLinkState.permissionDenied], no new request until
//        [retryDevice], Start or a re-plug;
//      - user Stop: nothing restarts until Start or a new attach.
//    The synthetic/file sources are never auto-selected when a USB provider exists.
//    Device operations (enumeration, open, auto start, release) run one at a time
//    ([_queue]); Stop is immediate and cancels a pending auto start ([_stopGen]).
//  * Mute: every controller (cold start) begins muted; the DSP engine never restores
//    `muted: false` and holds no audio device while muted.
//
// lib/main.dart is NOT switched here (the integrator does it).
import 'dart:async';
import 'dart:isolate';

import '../ui/radio_controller.dart';
import '../sdrpp/modules/sources/synth_source.dart';
import '../usb/usb_transport.dart' show UsbError, UsbException;
import 'dsp_engine.dart';
import 'dsp_isolate.dart';
import 'dsp_protocol.dart';
import 'source_registry.dart';

/// How to create a device's source inside the DSP isolate.
class SourceSelection {
  const SourceSelection(
    this.sourceId, [
    this.params = const <String, Object?>{},
  ]);

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
  /// Consumed by the call: it is a "new connection" event, not a state.
  Future<SdrDeviceInfo?> preferredDevice() async => null;

  /// Real hardware that the controller connects to and starts by itself (USB SDRs). Devices
  /// of providers without it (synthetic generator, files) are only used when chosen manually.
  bool get autoConnect => false;
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
  Future<SourceSelection> open(SdrDeviceInfo d) async =>
      SourceSelection('synth', params);
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
        name:
            (f['name'] as String?) ??
            'File: ${(f['path'] as String).split('/').last}',
        sampleRates: <double>[((f['sampleRate'] as num?) ?? 0).toDouble()],
        gain: const GainRange(min: 0, max: 0),
        hasAgc: false,
      ),
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
  final Completer<void> _dspUp =
      Completer<void>(); // spawn attempted (success or not)
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  final StreamController<FftRow> _rows = StreamController<FftRow>.broadcast();
  bool _disposed = false;

  List<SdrDeviceInfo> _devices = const <SdrDeviceInfo>[];
  SdrDeviceInfo? _device;
  SdrDeviceInfo?
  _openedDevice; // device whose source is selected in the DSP isolate
  bool _running = false;
  String? _lastError;

  DeviceLinkState _link = DeviceLinkState.idle;
  bool _userStopped = false;

  /// Cold start: connect to the first auto-connect device found by the first enumeration.
  /// Re-armed only by [retryDevice] (never by plain refreshes: no permission request loop).
  bool _autoArmed = true;

  /// Bumped by [stop]: an auto start in progress (e.g. waiting for the permission dialog)
  /// must not start reception after the user pressed Stop.
  int _stopGen = 0;
  Future<void> _chain = Future<void>.value();
  Future<void> _stopFuture = Future<void>.value();

  /// Completes after the DSP source, audio and USB connection have been released.
  Future<void> get whenStopped => _stopFuture;
  bool _muted = true;

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
  SquelchType _squelchType = SquelchType.off;
  double _autoSquelchOffset = 0;
  bool _autoSquelchAllowed = false;
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
      try {
        _dsp = await DspIsolate.spawn(
          options: options,
          registerSources: registerSources,
          readyTimeout: spawnTimeout,
        ).timeout(spawnTimeout);
        if (_disposed) {
          // Disposed while the isolate was starting: nobody else will close it.
          unawaited(_dsp!.close());
          return;
        }
        _subs.add(_dsp!.events.listen(_onEvent));
      } finally {
        _dspUp.complete();
      }
      // The isolate's first broadcast state can precede this subscription. Fetch one
      // acknowledged snapshot before enumerating/auto-starting USB, or defaults in this
      // facade would overwrite persisted frequency and other radio settings.
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.getState});
      if (lastState.isNotEmpty) _applyState(lastState);
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
        final data = (m['data'] as TransferableTypedData)
            .materialize()
            .asFloat32List();
        _rows.add(
          FftRow(
            db: data,
            lowFreq: (m['low'] as num).toDouble(),
            highFreq: (m['high'] as num).toDouble(),
          ),
        );
      case DspEvt.state:
        lastState = m;
        if (_outstanding == 0) _applyState(m);
      case DspEvt.stats:
        lastStats = m;
        _notify();
      case DspEvt.error:
        _lastError = m['message'] as String?;
        if (m['fatal'] == true) {
          // The source stopped itself (device lost / ENODEV): release it so nothing touches
          // the dead fd again and the next connection reopens the device.
          _running = false;
          if (!_userStopped) _link = DeviceLinkState.disconnected;
          _stopFuture = _queue(_lostLocked);
        }
        _notify();
    }
  }

  void _applyState(Map<Object?, Object?> m) {
    _running = m['running'] == true;
    final muted = m['muted'];
    if (muted is bool) _muted = muted;
    // Before a source is selected, the DSP frontend reports its placeholder 8 MHz rate.
    // Do not turn that into a device setting (USB would choose its maximum 3.2 MHz).
    if (m['sourceId'] != null) {
      _sampleRate = (m['sampleRate'] as num).toDouble();
    }
    _centerLocked = m['centerLocked'] == true;
    // The persisted LO is adopted once (first state); afterwards the UI owns it unless the
    // source locks it (file recordings).
    if (_centerLocked || !_gotState) {
      _centerFrequency = (m['centerFreq'] as num).toDouble();
    }
    _gotState = true;
    final vol = m['volume'];
    if (vol is num) _volume = vol.toDouble();
    _vfoOffset = (m['vfoOffset'] as num).toDouble();
    _mode = DemodMode.fromId((m['mode'] as num).toInt());
    _bandwidth = (m['bandwidth'] as num).toDouble();
    _squelchEnabled = m['squelchEnabled'] == true;
    _squelchLevel = (m['squelchLevel'] as num).toDouble();
    final sqm = m['squelchMode'];
    _squelchType = sqm is String
        ? SquelchType.fromKey(sqm)
        : (_squelchEnabled ? SquelchType.manual : SquelchType.off);
    final sqo = m['squelchAutoOffset'];
    if (sqo is num) _autoSquelchOffset = sqo.toDouble();
    _autoSquelchAllowed = m['squelchAutoAllowed'] == true;
    final gain = m['gain'];
    if (gain is num) _gain = gain.toDouble();
    final agc = m['agc'];
    if (agc is bool) _agc = agc;
    final ss = m['sourceSettings'];
    if (ss is List) {
      _sourceSettings = List<SourceSetting>.unmodifiable(
        ss
            .whereType<Map<Object?, Object?>>()
            .map(settingFromMap)
            .whereType<SourceSetting>(),
      );
    }
    final dopt = m['demodOptions'];
    if (dopt is Map) {
      _demodOptions = Map<String, Object?>.unmodifiable(
        dopt.cast<String, Object?>(),
      );
    }
    _notify();
  }

  /// Inverse of DspEngine.settingToMap.
  static SourceSetting? settingFromMap(Map<Object?, Object?> m) {
    final id = m['id'] as String? ?? '';
    final label = m['label'] as String? ?? id;
    double d(Object? v) => (v as num?)?.toDouble() ?? 0;
    return switch (m['type']) {
      'choice' => ChoiceSetting(
        id,
        label,
        (m['options'] as List? ?? const <Object?>[]).map((e) => '$e').toList(),
        (m['selected'] as num?)?.toInt() ?? 0,
      ),
      'slider' => SliderSetting(
        id,
        label,
        min: d(m['min']),
        max: d(m['max']),
        step: d(m['step']),
        value: d(m['value']),
      ),
      'bool' => BoolSetting(id, label, m['value'] == true),
      _ => null,
    };
  }

  /// Sends a command with ack; state echoes are ignored while commands are in flight, and a
  /// fresh state is requested when the last one completes.
  Future<void> _cmd(Map<String, Object?> msg) async {
    await _dspUp.future;
    final dsp = _dsp;
    if (dsp == null || dsp.isClosed) {
      throw StateError('DSP isolate not running');
    }
    _outstanding++;
    try {
      await dsp.request(msg);
    } finally {
      _outstanding--;
      if (_outstanding == 0 && !dsp.isClosed) {
        dsp.send(<String, Object?>{DspMsg.cmd: DspCmd.getState});
      }
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

  DeviceProvider? _providerOf(SdrDeviceInfo d) =>
      providers.where((p) => p.owns(d)).firstOrNull;

  @override
  Future<void> selectDevice(SdrDeviceInfo device) async {
    // A stale menu may still offer a device that was unplugged meanwhile.
    if (_running || device == _device || !_devices.contains(device)) return;
    _adoptDevice(device, keepUserGain: false);
    _link = DeviceLinkState.connecting;
    _notify();
    await _queue(() async {
      if (_device != device || _running) return;
      if (await _tryOpen(device)) _link = DeviceLinkState.idle;
      _notify();
    });
  }

  /// Makes [device] the selected one and adapts the generic controls to it.
  /// [keepUserGain]: a re-plugged device gets the user's gain/AGC re-applied (hot re-plug
  /// keeps settings); a manual selection adopts the device's own persisted gain instead.
  void _adoptDevice(SdrDeviceInfo device, {required bool keepUserGain}) {
    _device = device;
    if (!device.sampleRates.contains(_sampleRate) &&
        device.sampleRates.isNotEmpty) {
      // Nearest supported rate (keeps the DSP load similar across devices).
      _sampleRate = device.sampleRates.reduce(
        (a, b) => (a - _sampleRate).abs() <= (b - _sampleRate).abs() ? a : b,
      );
    }
    _gain = _gain.clamp(device.gain.min, device.gain.max).toDouble();
    if (!device.hasAgc) _agc = false;
    if (!keepUserGain) _gainTouched = false;
  }

  /// Opens [device] (USB: permission dialog + fd). On failure sets [_link]/[_lastError] and
  /// returns false; a refused permission is not asked again automatically.
  Future<bool> _tryOpen(SdrDeviceInfo device) async {
    try {
      await _openDevice(device);
      return true;
    } on UsbException catch (e) {
      if (e.code == UsbError.access) {
        _link = DeviceLinkState.permissionDenied;
        _lastError = 'Нет доступа к ${device.name}: разрешение USB отклонено';
      } else {
        _link = DeviceLinkState.failed;
        _lastError = 'Cannot open ${device.name}: $e';
      }
    } catch (e) {
      _link = DeviceLinkState.failed;
      _lastError = 'Cannot open ${device.name}: $e';
    }
    if (_openedDevice == device) await _releaseLocked();
    _notify();
    return false;
  }

  Future<void> _openDevice(SdrDeviceInfo device) async {
    if (_openedDevice == device) return;
    final prev = _openedDevice;
    if (prev != null) {
      // The DSP module still owns prev's fd even when stopped. Dispose it before Kotlin
      // closes the connection (and possibly reuses its numeric fd for this new device).
      await _releaseLocked();
    }
    final p = _providerOf(device);
    if (p == null) throw StateError('No provider for ${device.id}');
    final sel = await p.open(device);
    try {
      await _cmd(<String, Object?>{
        DspMsg.cmd: DspCmd.selectSource,
        'id': sel.sourceId,
        'params': sel.params,
      });
    } catch (_) {
      await p.close(
        device,
      ); // don't leak the USB connection when the source can't be created
      rethrow;
    }
    _openedDevice = device;
    if (device.sampleRates.length > 1) {
      await _cmd(<String, Object?>{
        DspMsg.cmd: DspCmd.setSampleRate,
        'hz': _sampleRate,
      });
    }
    if (device.gain.max > device.gain.min && _gainTouched) {
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.setGain, 'value': _gain});
      if (device.hasAgc) {
        await _cmd(<String, Object?>{
          DspMsg.cmd: DspCmd.setAgc,
          'enabled': _agc,
        });
      }
    }
  }

  @override
  Future<void> refreshDevices() => _queue(_refreshLocked);

  /// Runs device operations one at a time. Never await [_queue] from inside a queued function.
  Future<T> _queue<T>(Future<T> Function() f) {
    final r = _chain.then((_) => f());
    _chain = r.then((_) {}, onError: (Object _) {});
    return r;
  }

  bool _isAuto(SdrDeviceInfo d) => _providerOf(d)?.autoConnect ?? false;
  bool get _hasAutoProvider => providers.any((p) => p.autoConnect);

  /// Device shown as selected when none is: the first USB SDR; the synthetic generator /
  /// files only when there is no USB provider at all (host builds, tests).
  SdrDeviceInfo? _defaultDevice() =>
      _devices.where(_isAuto).firstOrNull ??
      (_hasAutoProvider ? null : _devices.firstOrNull);

  Future<void> _refreshLocked() async {
    if (_disposed) return;
    final all = <SdrDeviceInfo>[];
    for (final p in providers) {
      try {
        all.addAll(await p.listDevices());
      } catch (e) {
        _lastError = 'Device enumeration failed: $e';
      }
    }
    // Invariant for every notification: selectedDevice is null or one of [devices] (the
    // device dropdowns assert on it). The new list and the deselection are published
    // together, before any await: DSP state/stats events notify listeners meanwhile.
    final gone = _device;
    _devices = List<SdrDeviceInfo>.unmodifiable(all);
    if (gone != null && !_devices.contains(gone)) {
      // Device gone (detach): stop the DSP, release the source (and with it the audio
      // device), close the USB connection. Settings stay in the controller / DSP isolate.
      final wasActive =
          _running ||
          _link == DeviceLinkState.receiving ||
          _link == DeviceLinkState.connecting ||
          _link == DeviceLinkState.disconnected;
      _device = null;
      _running = false;
      final released = Completer<void>();
      _stopFuture = released.future;
      if (!_userStopped) {
        _link = wasActive
            ? DeviceLinkState.disconnected
            : DeviceLinkState.waiting;
      }
      _notify();
      try {
        await _releaseLocked();
      } finally {
        released.complete();
      }
    }
    _device ??= _defaultDevice();
    if (_device == null && _link == DeviceLinkState.idle) {
      _link = DeviceLinkState.waiting;
    }
    _notify();

    // A new connection (USB_DEVICE_ATTACHED launch / hot-plug) always connects; the plain
    // cold-start enumeration only once. Not awaited here: opening may wait for the user's
    // answer to the permission dialog, and refreshDevices also runs inside [ready].
    SdrDeviceInfo? target;
    var newConnection = false;
    for (final p in providers) {
      SdrDeviceInfo? pref;
      try {
        pref = await p.preferredDevice();
      } catch (_) {}
      if (pref != null && _devices.contains(pref)) {
        target = _devices.firstWhere((d) => d == pref);
        newConnection = true;
        break;
      }
    }
    if (target == null && _autoArmed) {
      target = _devices.where(_isAuto).firstOrNull;
    }
    if (target != null) {
      _autoArmed = false; // the cold-start connection happened (or a newer one replaced it)
      final t = target, n = newConnection;
      unawaited(_queue(() => _autoConnectLocked(t, newConnection: n)));
    }
  }

  /// Opens [device] and starts reception without the user pressing Start.
  Future<void> _autoConnectLocked(
    SdrDeviceInfo device, {
    required bool newConnection,
  }) async {
    if (_disposed || !_devices.contains(device)) return;
    if (_userStopped && !newConnection) return;
    final cur = _device;
    if (_running) {
      if (cur == device) return;
      // Assumption: at most one USB SDR. Keep receiving from the one already running; a
      // manually started synthetic/file source gives way to the newly connected hardware.
      if (cur != null && _isAuto(cur)) return;
      await _stopEngineLocked();
    }
    if (newConnection) _userStopped = false;
    final gen = _stopGen;
    _adoptDevice(device, keepUserGain: true);
    _link = DeviceLinkState.connecting;
    _lastError = null;
    _notify();
    if (!await _tryOpen(device)) return;
    if (gen != _stopGen || _userStopped || _device != device) {
      await _releaseLocked();
      if (_link == DeviceLinkState.connecting) {
        _link = DeviceLinkState.stoppedByUser;
      }
      _notify();
      return;
    }
    await _startLocked(device, gen);
  }

  /// Device lost while receiving (fatal DSP source error).
  Future<void> _lostLocked() async {
    await _releaseLocked();
    if (!_userStopped) _link = DeviceLinkState.disconnected;
    _notify();
    // The detach broadcast usually follows (or preceded) the ENODEV: re-list so the vanished
    // device leaves the list. Restart happens on the next attach, never in a loop here.
    await _refreshLocked();
  }

  /// Stops the engine, disposes the DSP source (it must not touch the fd any more) and closes
  /// the provider connection. The DSP engine releases the audio output with the source.
  Future<void> _releaseLocked() async {
    _running = false;
    try {
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.releaseSource});
    } catch (_) {}
    final d = _openedDevice;
    _openedDevice = null;
    if (d != null) {
      try {
        await _providerOf(d)?.close(d);
      } catch (_) {}
    }
  }

  Future<void> _stopEngineLocked() async {
    _running = false;
    try {
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.stop});
    } catch (e) {
      _lastError = '$e';
    }
  }

  @override
  Future<void> retryDevice() => _queue(() async {
    if (_userStopped || _running || _disposed) return;
    final d = (_device != null && _isAuto(_device!))
        ? _device
        : _devices.where(_isAuto).firstOrNull;
    if (d == null) {
      _link = DeviceLinkState.waiting;
      _notify();
      return;
    }
    await _autoConnectLocked(d, newConnection: false);
  });

  @override
  DeviceLinkState get linkState => _running ? DeviceLinkState.receiving : _link;

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
    final gen = _stopGen;
    _userStopped = false;
    await _ready;
    await _queue(() async {
      if (_running || _disposed || _userStopped || gen != _stopGen) return;
      final d = _device ?? _defaultDevice();
      if (d == null) {
        _lastError = 'No device';
        _link = DeviceLinkState.waiting;
        _notify();
        return;
      }
      if (d != _device) _adoptDevice(d, keepUserGain: true);
      _lastError = null;
      _link = DeviceLinkState.connecting;
      _notify();
      if (!await _tryOpen(d)) return;
      if (gen != _stopGen || _userStopped) {
        await _releaseLocked();
        return;
      }
      await _startLocked(d, gen);
    });
  }

  Future<void> _startLocked(SdrDeviceInfo d, int gen) async {
    try {
      // A saved configuration from the old multi-offset UI may have a nonzero VFO.
      // Preserve the tuned frequency while returning to the single centered channel.
      if (_vfoOffset != 0) {
        _centerFrequency += _vfoOffset;
        _vfoOffset = 0;
      }
      await _cmd(<String, Object?>{
        DspMsg.cmd: DspCmd.tune,
        'center': _centerFrequency,
        'offset': _vfoOffset,
      });
      await _cmd(<String, Object?>{DspMsg.cmd: DspCmd.start});
      // A Stop pressed meanwhile is queued after this start in the DSP isolate.
      if (gen == _stopGen) {
        _running = true;
        _link = DeviceLinkState.receiving;
        _lastError = null;
      } else {
        // Stop arrived while the DSP was initializing the tuner. The UI never set
        // _running, so stop() had nothing to stop; finish the cancelled start here.
        await _stopEngineLocked();
      }
    } catch (e) {
      _lastError = '$e';
      _running = false;
      _link = DeviceLinkState.failed;
    }
    _notify();
  }

  @override
  Future<void> stop() {
    // User Stop: also cancels a pending automatic start (permission dialog / opening).
    _userStopped = true;
    _stopGen++;
    _link = DeviceLinkState.stoppedByUser;
    _running = false;
    _stopFuture = _queue(() async {
      // releaseSource stops the DSP/audio first, then closes the USB fd.
      await _releaseLocked();
      _notify();
    });
    _notify();
    return _stopFuture;
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
    _bandwidth = mode
        .params
        .defaultBandwidth; // corrected by the DSP state (saved per mode)
    _autoSquelchAllowed = mode.params.autoSquelch != null; // idem (squelch mode per mode)
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
    if (_openedDevice != null) {
      _fire(<String, Object?>{DspMsg.cmd: DspCmd.setSampleRate, 'hz': hz});
    }
    _notify();
  }

  @override
  double get gain => _gain;

  @override
  void setGain(double value) {
    _gain = value;
    _gainTouched = true;
    if (_openedDevice != null) {
      _fire(<String, Object?>{DspMsg.cmd: DspCmd.setGain, 'value': value});
    }
    _notify();
  }

  @override
  bool get agc => _agc;

  @override
  void setAgc(bool enabled) {
    _agc = enabled;
    _gainTouched = true;
    if (_openedDevice != null) {
      _fire(<String, Object?>{DspMsg.cmd: DspCmd.setAgc, 'enabled': enabled});
    }
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
  bool get muted => _muted;

  @override
  void setMuted(bool muted) {
    _muted = muted;
    _fire(<String, Object?>{DspMsg.cmd: DspCmd.setMuted, 'muted': muted});
    _notify();
  }

  @override
  bool get squelchEnabled => _squelchEnabled;

  @override
  void setSquelchEnabled(bool enabled) {
    _squelchEnabled = enabled;
    _squelchType = enabled ? SquelchType.manual : SquelchType.off;
    _fire(<String, Object?>{
      DspMsg.cmd: DspCmd.setSquelch,
      'enabled': enabled,
      'level': _squelchLevel,
    });
    _notify();
  }

  @override
  SquelchType get squelchType => _squelchType;

  @override
  void setSquelchType(SquelchType type) {
    if (type == SquelchType.auto && !_autoSquelchAllowed) return;
    _squelchType = type;
    _squelchEnabled = type == SquelchType.manual;
    _fire(<String, Object?>{
      DspMsg.cmd: DspCmd.setSquelch,
      'mode': type.key,
      'level': _squelchLevel,
      'autoOffset': _autoSquelchOffset,
    });
    _notify();
  }

  @override
  bool get autoSquelchAvailable => _autoSquelchAllowed;

  @override
  double get autoSquelchOffset => _autoSquelchOffset;

  @override
  void setAutoSquelchOffset(double db) {
    _autoSquelchOffset = db
        .clamp(RadioController.minAutoSquelchOffset, RadioController.maxAutoSquelchOffset)
        .toDouble();
    _fire(<String, Object?>{
      DspMsg.cmd: DspCmd.setSquelch,
      'autoOffset': _autoSquelchOffset,
    });
    _notify();
  }

  @override
  AutoSquelchStatus? get autoSquelchStatus {
    if (!_running || _squelchType != SquelchType.auto) return null;
    final s = lastStats['squelch'];
    if (s is! Map) return null;
    return AutoSquelchStatus(
      open: s['open'] == true,
      metricDb: (s['metric'] as num?)?.toDouble(),
      thresholdDb: (s['threshold'] as num?)?.toDouble(),
    );
  }

  @override
  double get squelchLevel => _squelchLevel;

  @override
  void setSquelchLevel(double db) {
    _squelchLevel = db.clamp(-100.0, 0.0).toDouble();
    _fire(<String, Object?>{
      DspMsg.cmd: DspCmd.setSquelch,
      'level': _squelchLevel,
    });
    _notify();
  }

  // ---------------------------------------------------------------------------
  // FFT
  // ---------------------------------------------------------------------------

  /// Keep demodulation/audio running but skip the FFT branch when no Activity is visible.
  void setFftVisible(bool visible) {
    _ready.then(
      (_) => _dsp?.send(<String, Object?>{
        DspMsg.cmd: DspCmd.setFft,
        'enabled': visible,
      }),
    );
  }

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
    _fire(<String, Object?>{
      DspMsg.cmd: DspCmd.sourceSetting,
      'id': id,
      'value': value,
    });
  }

  @override
  Map<String, Object?> get demodOptions => _demodOptions;

  @override
  void setDemodOption(String key, Object value) {
    _demodOptions = Map<String, Object?>.unmodifiable(<String, Object?>{
      ..._demodOptions,
      key: value,
    });
    _fire(<String, Object?>{
      DspMsg.cmd: DspCmd.demodOption,
      'key': key,
      'value': value,
    });
    _notify();
  }

  @override
  Map<String, Object?> get stats => <String, Object?>{
    for (final e in lastStats.entries)
      if (e.key != DspMsg.evt && e.key != 'squelch') '${e.key}': e.value,
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
    _ready.then(
      (_) => _dsp?.send(<String, Object?>{
        DspMsg.cmd: DspCmd.setFft,
        'width': pixels,
      }),
    );
  }

  @override
  void setFftView({required double viewOffset, required double viewBandwidth}) {
    _ready.then(
      (_) => _dsp?.send(<String, Object?>{
        DspMsg.cmd: DspCmd.setFft,
        'viewOffset': viewOffset,
        'viewBandwidth': viewBandwidth,
      }),
    );
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

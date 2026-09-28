// Shared plumbing for the USB source modules (rtl_sdr_source, hackrf_source).
//
// Replaces the pieces of the SDR++ runtime the C++ source modules use that
// are not part of the SourceHandler contract:
//   * flog::info/warn/error                  -> [SourceLog]
//   * ConfigManager (acquire/release/conf)   -> [SourceModuleConfig] (a plain
//     JSON-like map with change notification, NOT sigpath's ConfigManager:
//     the owner persists it via [UsbSourceModule.onConfigChanged] and hands
//     it back with [UsbSourceModule.restoreConfig] / the constructor)
//   * backend::getDeviceFD(vid, pid, ...)    -> [UsbSourceParams] (the fd is
//     obtained on the UI isolate by the Android plugin, lib/usb/android_usb.dart,
//     and sent to the DSP isolate as a plain map)
//   * rtlsdr_open_sys_dev / hackrf_open_by_fd libusb_wrap_sys_device()
//                                            -> [UsbDeviceOpener]
//
// Error reporting (no SDR++ equivalent: SDR++ only logs): [UsbSourceModule.onError]
// is called when opening fails at start() or when the device disappears while
// streaming (hot-unplug); in the latter case the module stops itself cleanly.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import '../../../usb/usb_transport.dart';
import '../../../usb/usbfs_transport.dart';
import '../../signal_path/source_handler.dart';

/// flog replacement for the source modules.
enum SourceLogLevel { debug, info, warn, error }

abstract final class SourceLog {
  /// Override to route into the app log (or silence in tests).
  static void Function(SourceLogLevel level, String message) sink = _default;

  static void _default(SourceLogLevel level, String message) {
    // ignore: avoid_print
    print('[${level.name.toUpperCase()}] $message');
  }

  static void info(String m) => sink(SourceLogLevel.info, m);
  static void warn(String m) => sink(SourceLogLevel.warn, m);
  static void error(String m) => sink(SourceLogLevel.error, m);
}

/// Device parameters handed from the UI isolate (Android UsbSdrPlugin.open +
/// listDevices) to the DSP isolate: `{fd, vid, pid, deviceName, serial,
/// manufacturer, product}`. Only plain values, so the map is sendable.
class UsbSourceParams {
  /// usbfs file descriptor owned by Kotlin's UsbDeviceConnection (never close).
  final int fd;
  final int vid;
  final int pid;

  /// /dev/bus/usb/BBB/DDD
  final String deviceName;
  final String? serial;
  final String? manufacturer;
  final String? product;

  const UsbSourceParams({
    required this.fd,
    required this.vid,
    required this.pid,
    this.deviceName = '',
    this.serial,
    this.manufacturer,
    this.product,
  });

  factory UsbSourceParams.fromMap(Map<Object?, Object?> m) => UsbSourceParams(
    fd: (m['fd'] as num?)?.toInt() ?? -1,
    vid: (m['vid'] as num).toInt(),
    pid: (m['pid'] as num).toInt(),
    deviceName: (m['deviceName'] as String?) ?? '',
    serial: _nonEmpty(m['serial']),
    manufacturer: _nonEmpty(m['manufacturer']),
    product: _nonEmpty(m['product']),
  );

  Map<String, Object?> toMap() => {
    'fd': fd,
    'vid': vid,
    'pid': pid,
    'deviceName': deviceName,
    'serial': serial,
    'manufacturer': manufacturer,
    'product': product,
  };

  static String? _nonEmpty(Object? v) =>
      (v is String && v.isNotEmpty) ? v : null;

  String get vidPid =>
      '${vid.toRadixString(16).padLeft(4, '0')}:${pid.toRadixString(16).padLeft(4, '0')}';
}

/// Opens a fresh [UsbDeviceHandle] for the device (called every time the C++
/// module calls rtlsdr_open_sys_dev / hackrf_open_by_fd). The default wraps
/// the Android fd with the usbfs transport; tests inject mocks.
typedef UsbDeviceOpener = UsbDeviceHandle Function(UsbSourceParams params);

UsbDeviceHandle defaultUsbDeviceOpener(UsbSourceParams params) =>
    UsbfsDeviceHandle.wrap(params.fd);

/// Minimal stand-in for SDR++ ConfigManager as used by the source modules:
/// `acquire()` / `release(modified)` / `conf`. On `release(true)` the owner is
/// notified with a deep copy of the whole module config.
class SourceModuleConfig {
  Map<String, Object?> conf;
  void Function(Map<String, Object?> conf)? onChanged;

  SourceModuleConfig(
    Map<String, Object?> defaults, [
    Map<String, Object?>? loaded,
  ]) : conf = deepCopyJson(defaults) {
    if (loaded != null) load(loaded);
  }

  /// ConfigManager::load(def): keys missing from [loaded] keep the defaults.
  void load(Map<String, Object?> loaded) {
    for (final e in loaded.entries) {
      conf[e.key] = deepCopyJson(e.value);
    }
  }

  void acquire() {}

  void release([bool modified = false]) {
    if (modified) onChanged?.call(deepCopyJson(conf));
  }

  /// `conf["devices"]` (created if missing).
  Map<String, Object?> get devices {
    final d = conf['devices'];
    if (d is Map<String, Object?>) return d;
    final m = <String, Object?>{};
    if (d is Map) {
      d.forEach((k, v) => m['$k'] = v);
    }
    conf['devices'] = m;
    return m;
  }

  /// `conf["devices"][key]` (created if missing).
  Map<String, Object?> device(String key) {
    final d = devices[key];
    if (d is Map<String, Object?>) return d;
    final m = <String, Object?>{};
    if (d is Map) {
      d.forEach((k, v) => m['$k'] = v);
    }
    devices[key] = m;
    return m;
  }
}

/// Deep copy of a JSON-like value (maps get String keys).
T deepCopyJson<T>(T v) {
  Object? copy(Object? x) {
    if (x is Map) {
      return <String, Object?>{
        for (final e in x.entries) '${e.key}': copy(e.value),
      };
    }
    if (x is List) return [for (final e in x) copy(e)];
    return x;
  }

  return copy(v) as T;
}

/// JSON number/bool coercions mirroring nlohmann::json implicit conversions.
int jsonInt(Object? v, int def) => switch (v) {
  num n => n.toInt(),
  bool b => b ? 1 : 0,
  _ => def,
};

double jsonDouble(Object? v, double def) => switch (v) {
  num n => n.toDouble(),
  _ => def,
};

bool jsonBool(Object? v, bool def) => switch (v) {
  bool b => b,
  num n => n != 0,
  _ => def,
};

/// Error callback: [message] is human readable; [error] the cause (driver
/// return code, [UsbException] ...). [fatal] = the source stopped itself.
typedef SourceErrorCallback = void Function(
  String message,
  Object? error, {
  bool fatal,
});

/// Common API of the USB source modules on top of [SourceHandler].
abstract class UsbSourceModule implements SourceHandler {
  /// Name under which SDR++ registers the source ("RTL-SDR", "HackRF").
  String get sourceName;

  /// Module instance name.
  String get name;

  bool get running;

  /// Device list entries (Android: exactly one, the device we got an fd for).
  List<String> get deviceNames;

  /// Current input sample rate in Hz.
  double get sampleRate;

  SourceErrorCallback? onError;

  /// Called with the full module config whenever SDR++ would
  /// `config.release(true)`; persist it and pass it back on the next start.
  void Function(Map<String, Object?> config)? onConfigChanged;

  /// Snapshot of the module config (`{"device": ..., "devices": {...}}`).
  Map<String, Object?> saveConfig();

  /// Replace the module config and re-select the configured device
  /// (ignored while running, like the disabled SDR++ device combo).
  void restoreConfig(Map<String, Object?> config);

  /// SDR++ "Refresh" button.
  void refresh();

  /// Module destructor (`~XSourceModule`): stops streaming.
  Future<void> dispose();
}

/// Delegating [UsbDeviceHandle] that reports device loss to the source module
/// (no SDR++ equivalent: libhackrf only sets `streaming = false` when its
/// transfers fail, and SDR++ never notices a hot-unplug). [onLost] fires once,
/// asynchronously (never re-entrantly inside a driver call), when
///   * any call throws [UsbException] with [UsbError.noDevice], or
///   * a bulk-IN stream reports noDevice, or ends without being cancelled.
/// Everything is forwarded unchanged, errors included, so driver behaviour is
/// identical to using the inner handle.
class WatchedUsbDeviceHandle implements UsbDeviceHandle {
  final UsbDeviceHandle inner;
  final void Function(Object error) onLost;
  bool _reported = false;

  WatchedUsbDeviceHandle(this.inner, this.onLost);

  bool get lost => _reported;

  void _lost(Object error) {
    if (_reported) return;
    _reported = true;
    scheduleMicrotask(() => onLost(error));
  }

  T _watch<T>(T Function() f) {
    try {
      return f();
    } on UsbException catch (e) {
      if (e.code == UsbError.noDevice) _lost(e);
      rethrow;
    }
  }

  @override
  UsbDeviceDescriptor get deviceDescriptor => inner.deviceDescriptor;

  @override
  int controlTransfer(
    int requestType,
    int request,
    int value,
    int index,
    Uint8List data,
    int length, {
    int timeoutMs = 1000,
  }) => _watch(
    () => inner.controlTransfer(
      requestType,
      request,
      value,
      index,
      data,
      length,
      timeoutMs: timeoutMs,
    ),
  );

  @override
  int bulkTransfer(
    int endpoint,
    Uint8List data,
    int length, {
    int timeoutMs = 1000,
  }) => _watch(
    () => inner.bulkTransfer(endpoint, data, length, timeoutMs: timeoutMs),
  );

  @override
  void setConfiguration(int configuration) =>
      _watch(() => inner.setConfiguration(configuration));

  @override
  void claimInterface(int interfaceNumber) =>
      _watch(() => inner.claimInterface(interfaceNumber));

  @override
  void releaseInterface(int interfaceNumber) =>
      _watch(() => inner.releaseInterface(interfaceNumber));

  @override
  void clearHalt(int endpoint) => _watch(() => inner.clearHalt(endpoint));

  @override
  void resetDevice() => _watch(inner.resetDevice);

  @override
  String? getStringDescriptorAscii(int index) =>
      _watch(() => inner.getStringDescriptorAscii(index));

  @override
  Future<BulkInStream> openBulkIn(
    int endpoint, {
    required int numBuffers,
    required int bufferLength,
  }) async {
    final BulkInStream s;
    try {
      s = await inner.openBulkIn(
        endpoint,
        numBuffers: numBuffers,
        bufferLength: bufferLength,
      );
    } on UsbException catch (e) {
      if (e.code == UsbError.noDevice) _lost(e);
      rethrow;
    }
    return _WatchedBulkInStream(this, s);
  }

  @override
  void close() => inner.close();
}

class _WatchedBulkInStream implements BulkInStream {
  final WatchedUsbDeviceHandle owner;
  final BulkInStream inner;
  bool _cancelled = false;
  late final Stream<UsbBlock> _blocks = inner.blocks.transform(
    StreamTransformer<UsbBlock, UsbBlock>.fromHandlers(
      handleError: (error, stackTrace, sink) {
        if (error is UsbException && error.code == UsbError.noDevice) {
          owner._lost(error);
        }
        sink.addError(error, stackTrace);
      },
      handleDone: (sink) {
        if (!_cancelled) {
          owner._lost(UsbException(UsbError.noDevice, 'bulk stream ended'));
        }
        sink.close();
      },
    ),
  );

  _WatchedBulkInStream(this.owner, this.inner);

  @override
  Stream<UsbBlock> get blocks => _blocks;

  @override
  void release(UsbBlock block) => inner.release(block);

  @override
  int get droppedBuffers => inner.droppedBuffers;

  @override
  Future<void> cancel() {
    _cancelled = true;
    return inner.cancel();
  }
}

/// Settings ids shared by the modules (SourceSetting.id).
abstract final class SourceSettingId {
  static const device = 'device';
  static const sampleRate = 'sampleRate';
  static const refresh = 'refresh';
}

/// Convenience: `ChoiceSetting` for a device list.
ChoiceSetting deviceChoice(List<String> names, int selected) =>
    ChoiceSetting(SourceSettingId.device, 'Device', names, selected);

// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Opaque handle from native/include/sdrcore.h.
final class SdrHandle extends Opaque {}

/// Ordered loader candidates for the native library packaged with the runner.
/// [operatingSystem] uses dart:io's Platform.operatingSystem values.
List<String> sdrCoreLibraryCandidates(
  String operatingSystem,
  String executable,
) {
  final separator = operatingSystem == 'windows' ? '\\' : '/';
  final slash = executable.lastIndexOf(separator);
  final dir = slash < 0 ? '.' : executable.substring(0, slash);
  switch (operatingSystem) {
    case 'linux':
      return ['$dir/lib/libsdrcore.so', 'libsdrcore.so'];
    case 'macos':
      final contents = dir.endsWith('/MacOS')
          ? dir.substring(0, dir.length - '/MacOS'.length)
          : dir;
      return ['$contents/Frameworks/libsdrcore.dylib', 'libsdrcore.dylib'];
    case 'windows':
      return ['$dir${separator}sdrcore.dll', 'sdrcore.dll'];
    default:
      return ['libsdrcore.so'];
  }
}

/// Loads the packaged core; an explicit path takes precedence on every OS.
DynamicLibrary openSdrCoreLibrary([String? libraryPath]) {
  if (libraryPath != null && libraryPath.isNotEmpty) {
    return DynamicLibrary.open(libraryPath);
  }
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    final env = Platform.environment['SDRCORE_HOST_LIBRARY'];
    if (env != null && env.isNotEmpty) return DynamicLibrary.open(env);
    final candidates = sdrCoreLibraryCandidates(
      Platform.operatingSystem,
      Platform.resolvedExecutable,
    );
    if (File(candidates.first).existsSync()) {
      return DynamicLibrary.open(candidates.first);
    }
    return DynamicLibrary.open(candidates.last);
  }
  return DynamicLibrary.open('libsdrcore.so');
}

/// A failed native command; [code] is the SdrResult / SdrHostResult value.
final class SdrCoreError extends StateError {
  SdrCoreError(this.code)
    : super(switch (code) {
        SdrResult.hostAccessDenied =>
          'USB access denied ($code); check device permissions',
        SdrResult.hostNotFound => 'USB device not found ($code); reconnect it',
        SdrResult.hostDriverUnsupported =>
          'USB driver unsupported ($code); on Windows bind WinUSB with Zadig',
        SdrResult.hostBusy =>
          'USB device busy ($code); close other SDR applications',
        _ => 'Native core error $code',
      });
  final int code;
}

/// Native result codes (sdrcore.h enum SdrResult + sdrcore_host.h).
abstract final class SdrResult {
  static const ok = 0;
  static const invalidArgument = -1;
  static const invalidState = -2;
  static const unsupported = -3;
  static const ioError = -4;
  static const deviceGone = -5;
  static const internalError = -6;
  static const hostAccessDenied = -16;
  static const hostNotFound = -17;
  static const hostDriverUnsupported = -18;
  static const hostBusy = -19;
}

/// Native engine states (sdrcore.h enum SdrState).
abstract final class SdrState {
  static const idle = 0;
  static const open = 1;
  static const running = 2;
  static const error = 3;
}

/// Native source ids (sdrcore.h enum SdrSource).
abstract final class SdrSourceId {
  static const rtlsdr = 3;
  static const hackrf = 4;
}

/// One USB device listed by the desktop host layer (sdrcore_host.h).
final class SdrHostUsbDevice {
  const SdrHostUsbDevice({
    required this.vendorId,
    required this.productId,
    required this.bus,
    required this.address,
    required this.path,
    this.manufacturer,
    this.product,
    this.serial,
  });
  final int vendorId;
  final int productId;
  final int bus;
  final int address;

  /// Linux: /dev/bus/usb/BBB/DDD; macOS/Windows: usb:BBB/DDD.
  final String path;
  final String? manufacturer;
  final String? product;
  final String? serial;

  @override
  String toString() =>
      'SdrHostUsbDevice($path ${vendorId.toRadixString(16)}:'
      '${productId.toRadixString(16)} $manufacturer $product $serial)';
}

/// Optional desktop host USB layer; not present in Android builds.
abstract interface class SdrCoreHostBindings {
  bool get hasHostUsb;
  List<SdrHostUsbDevice> hostUsbList();
  int hostOpenUsb(Pointer<SdrHandle> handle, int bus, int address, int source);
}

/// The three original C ABI functions. Injection permits lifecycle tests.
abstract interface class SdrCoreBindings {
  int version();
  Pointer<SdrHandle> create();
  void destroy(Pointer<SdrHandle> handle);
}

/// ABI 2 optional commands. Never use these to stream IQ to Dart.
abstract interface class SdrCoreV2Bindings implements SdrCoreBindings {
  int openFile(Pointer<SdrHandle> handle, int fd, int sampleRate);
  int openSynthetic(Pointer<SdrHandle> handle, int sampleRate);
  int openUsb(Pointer<SdrHandle> handle, int fd, int source);
  int configure(
    Pointer<SdrHandle> handle,
    int frequencyHz,
    int sampleRate,
    int gainTenthsDb,
  );
  int start(Pointer<SdrHandle> handle);
  int stop(Pointer<SdrHandle> handle);
  int close(Pointer<SdrHandle> handle);
  SdrCoreStats stats(Pointer<SdrHandle> handle);
}

final class SdrCoreStats {
  const SdrCoreStats(
    this.state,
    this.source,
    this.inputSamples,
    this.processedSamples,
    this.droppedSamples,
    this.lastError,
    this.sampleRate,
    this.frequencyHz,
    this.gainTenthsDb,
    this.checksum,
  );
  final int state;
  final int source;
  final int inputSamples;
  final int processedSamples;
  final int droppedSamples;
  final int lastError;
  final int sampleRate;
  final int frequencyHz;
  final int gainTenthsDb;
  final int checksum;
}

final class _NativeStats extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int revision;
  @Uint32()
  external int state;
  @Uint32()
  external int source;
  @Int32()
  external int lastError;
  @Uint32()
  external int sampleRate;
  @Uint64()
  external int frequencyHz;
  @Int32()
  external int gainTenthsDb;
  @Uint32()
  external int reserved;
  @Uint64()
  external int inputSamples;
  @Uint64()
  external int processedSamples;
  @Uint64()
  external int droppedSamples;
  @Uint64()
  external int checksum;
}

// Mirror of SdrHostUsbDevice in native/include/sdrcore_host.h (232 bytes).
final class _NativeHostUsbDevice extends Struct {
  @Uint32()
  external int size;
  @Uint16()
  external int vendorId;
  @Uint16()
  external int productId;
  @Uint8()
  external int bus;
  @Uint8()
  external int address;
  @Array(2)
  external Array<Uint8> reserved;
  @Array(32)
  external Array<Uint8> path;
  @Array(64)
  external Array<Uint8> manufacturer;
  @Array(64)
  external Array<Uint8> product;
  @Array(64)
  external Array<Uint8> serial;

  static String _str(Array<Uint8> a, int cap) {
    final bytes = <int>[];
    for (var i = 0; i < cap && a[i] != 0; i++) {
      bytes.add(a[i]);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String? _opt(Array<Uint8> a, int cap) {
    final s = _str(a, cap);
    return s.isEmpty ? null : s;
  }

  SdrHostUsbDevice toDevice() => SdrHostUsbDevice(
    vendorId: vendorId,
    productId: productId,
    bus: bus,
    address: address,
    path: _str(path, 32),
    manufacturer: _opt(manufacturer, 64),
    product: _opt(product, 64),
    serial: _opt(serial, 64),
  );
}

/// Explicitly loads the native core. It does not replace the Dart receiver.
final class SdrCore {
  SdrCore._(this._bindings) {
    final version = _bindings.version();
    if (version < abiVersion || version > maxAbiVersion) {
      throw UnsupportedError(
        'Unsupported sdrcore ABI $version '
        '(expected $abiVersion..$maxAbiVersion)',
      );
    }
  }

  /// ABI revision of native/include/sdrcore.h used by this wrapper (also the
  /// SdrStats revision), not an application version.
  static const abiVersion = 2;

  /// Newest library ABI accepted. ABI 3 (sdrcore_v3.h) only adds sdr_v3_*
  /// symbols; every ABI 2 signature and the SdrStats layout are unchanged.
  static const maxAbiVersion = 3;

  /// On Android loads the packaged arm64 library. On desktops resolves an
  /// explicit path, `$SDRCORE_HOST_LIBRARY`, the runner bundle, then the
  /// platform loader path, in that order.
  factory SdrCore.open({String? libraryPath}) {
    if (!Platform.isAndroid &&
        !Platform.isLinux &&
        !Platform.isMacOS &&
        !Platform.isWindows) {
      throw UnsupportedError(
        'libsdrcore is only built for Android, Linux, macOS and Windows',
      );
    }
    return SdrCore._(_DynamicSdrCoreBindings(openSdrCoreLibrary(libraryPath)));
  }

  /// Allows lifecycle checks with bindings that do not allocate native memory.
  factory SdrCore.withBindings(SdrCoreBindings bindings) => SdrCore._(bindings);

  final SdrCoreBindings _bindings;

  /// Calls native sdr_version (ABI revision, not receiver state).
  int get version => _bindings.version();

  /// True when this library has the desktop host USB layer.
  bool get hasHostUsb {
    final Object b = _bindings;
    return b is SdrCoreHostBindings && b.hasHostUsb;
  }

  /// Lists host USB devices (all non-hub devices; filter by VID:PID).
  List<SdrHostUsbDevice> hostUsbDevices() {
    final Object b = _bindings;
    if (b is! SdrCoreHostBindings || !b.hasHostUsb) {
      throw UnsupportedError('Host USB layer not available in this library');
    }
    return b.hostUsbList();
  }

  /// Allocates one idle native handle; caller must dispose the result.
  SdrCoreInstance create() {
    final handle = _bindings.create();
    if (handle == nullptr) {
      throw StateError('sdr_create returned NULL');
    }
    return SdrCoreInstance._(handle, _bindings);
  }
}

/// Exclusively owns one handle. Explicit dispose is required; no GC-only cleanup.
final class SdrCoreInstance {
  SdrCoreInstance._(this._handle, this._bindings);

  Pointer<SdrHandle> _handle;
  final SdrCoreBindings _bindings;

  bool get isDisposed => _handle == nullptr;

  SdrCoreV2Bindings get _v2 {
    if (_bindings is! SdrCoreV2Bindings) {
      throw UnsupportedError('ABI 2 operations unavailable in these bindings');
    }
    return _bindings;
  }

  Pointer<SdrHandle> get _live {
    if (isDisposed) throw StateError('Native handle disposed');
    return _handle;
  }

  void _check(int result) {
    if (result != 0) throw SdrCoreError(result);
  }

  /// Diagnostic CU8 file source. Native duplicates [fd]; caller owns original.
  void openFile(int fd, int sampleRate) =>
      _check(_v2.openFile(_live, fd, sampleRate));

  /// Diagnostic native source only; no USB acquisition and no audio.
  void openSynthetic(int sampleRate) =>
      _check(_v2.openSynthetic(_live, sampleRate));

  /// Native USB source. Keep the Android UsbDeviceConnection alive until close
  /// or dispose; native duplicates [fd] and never owns the original.
  void openUsb(int fd, int source) => _check(_v2.openUsb(_live, fd, source));

  /// Desktop host only: opens via Linux usbfs or direct libusb on macOS/Windows.
  void openHostUsb(int bus, int address, int source) {
    final Object b = _bindings;
    if (b is! SdrCoreHostBindings || !b.hasHostUsb) {
      throw UnsupportedError('Host USB layer not available in this library');
    }
    _check(b.hostOpenUsb(_live, bus, address, source));
  }

  /// Configure in OPEN only. RF Hz, complex IQ pairs/s, tenths of a dB.
  void configure(int frequencyHz, int sampleRate, int gainTenthsDb) =>
      _check(_v2.configure(_live, frequencyHz, sampleRate, gainTenthsDb));
  void start() => _check(_v2.start(_live));
  void stop() => _check(_v2.stop(_live));
  void close() => _check(_v2.close(_live));
  SdrCoreStats get stats => _v2.stats(_live);

  void dispose() {
    final handle = _handle;
    if (handle == nullptr) return;
    _handle = nullptr;
    _bindings.destroy(handle);
  }
}

// Exact C signatures: uint32_t(void), SdrHandle*(void), void(SdrHandle*).
final class _DynamicSdrCoreBindings
    implements SdrCoreV2Bindings, SdrCoreHostBindings {
  _DynamicSdrCoreBindings(this._library);

  final DynamicLibrary _library;

  @override
  late final bool hasHostUsb =
      _library.providesSymbol('sdr_host_usb_list') &&
      _library.providesSymbol('sdr_host_open_usb') &&
      (!(Platform.isMacOS || Platform.isWindows) ||
          _library.providesSymbol('sdr_host_open_usb_direct'));
  late final int Function(Pointer<_NativeHostUsbDevice>, int, Pointer<Uint32>)
  _hostList = _library
      .lookupFunction<
        Int32 Function(Pointer<_NativeHostUsbDevice>, Uint32, Pointer<Uint32>),
        int Function(Pointer<_NativeHostUsbDevice>, int, Pointer<Uint32>)
      >('sdr_host_usb_list');
  late final int Function(Pointer<SdrHandle>, int, int, int) _hostOpen =
      _library.lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Uint8, Uint8, Uint32),
        int Function(Pointer<SdrHandle>, int, int, int)
      >(
        Platform.isMacOS || Platform.isWindows
            ? 'sdr_host_open_usb_direct'
            : 'sdr_host_open_usb',
      );

  @override
  List<SdrHostUsbDevice> hostUsbList() {
    const capacity = 64;
    final buf = calloc<_NativeHostUsbDevice>(capacity);
    final count = calloc<Uint32>();
    try {
      for (var i = 0; i < capacity; i++) {
        buf[i].size = sizeOf<_NativeHostUsbDevice>();
      }
      final code = _hostList(buf, capacity, count);
      if (code != 0) throw SdrCoreError(code);
      final n = count.value < capacity ? count.value : capacity;
      return <SdrHostUsbDevice>[for (var i = 0; i < n; i++) buf[i].toDevice()];
    } finally {
      calloc.free(buf);
      calloc.free(count);
    }
  }

  @override
  int hostOpenUsb(
    Pointer<SdrHandle> handle,
    int bus,
    int address,
    int source,
  ) => _hostOpen(handle, bus, address, source);
  late final int Function(Pointer<SdrHandle>, int, int) _openFile = _library
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Int32, Uint32),
        int Function(Pointer<SdrHandle>, int, int)
      >('sdr_v2_open_file');
  late final int Function(Pointer<SdrHandle>, int) _openSynthetic = _library
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Uint32),
        int Function(Pointer<SdrHandle>, int)
      >('sdr_v2_open_synthetic');
  late final int Function(Pointer<SdrHandle>, int, int) _openUsb = _library
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Int32, Uint32),
        int Function(Pointer<SdrHandle>, int, int)
      >('sdr_v2_open_usb');
  late final int Function(Pointer<SdrHandle>, int, int, int) _configure =
      _library.lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Uint64, Uint32, Int32),
        int Function(Pointer<SdrHandle>, int, int, int)
      >('sdr_v2_configure');
  late final int Function(Pointer<SdrHandle>) _start = _library
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>),
        int Function(Pointer<SdrHandle>)
      >('sdr_v2_start');
  late final int Function(Pointer<SdrHandle>) _stop = _library
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>),
        int Function(Pointer<SdrHandle>)
      >('sdr_v2_stop');
  late final int Function(Pointer<SdrHandle>) _close = _library
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>),
        int Function(Pointer<SdrHandle>)
      >('sdr_v2_close');
  late final int Function(Pointer<SdrHandle>, Pointer<_NativeStats>) _stats =
      _library.lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Pointer<_NativeStats>),
        int Function(Pointer<SdrHandle>, Pointer<_NativeStats>)
      >('sdr_v2_stats');
  late final int Function() _version = _library
      .lookupFunction<Uint32 Function(), int Function()>('sdr_version');
  late final Pointer<SdrHandle> Function() _create = _library
      .lookupFunction<
        Pointer<SdrHandle> Function(),
        Pointer<SdrHandle> Function()
      >('sdr_create');
  late final void Function(Pointer<SdrHandle>) _destroy = _library
      .lookupFunction<
        Void Function(Pointer<SdrHandle>),
        void Function(Pointer<SdrHandle>)
      >('sdr_destroy');

  @override
  int version() => _version();

  @override
  Pointer<SdrHandle> create() {
    // Resolve destroy first so a missing symbol cannot strand an allocated handle.
    _destroy;
    return _create();
  }

  @override
  void destroy(Pointer<SdrHandle> handle) => _destroy(handle);

  @override
  int openSynthetic(Pointer<SdrHandle> handle, int rate) =>
      _openSynthetic(handle, rate);

  @override
  int openFile(Pointer<SdrHandle> handle, int fd, int rate) =>
      _openFile(handle, fd, rate);

  @override
  int openUsb(Pointer<SdrHandle> handle, int fd, int source) =>
      _openUsb(handle, fd, source);

  @override
  int configure(
    Pointer<SdrHandle> handle,
    int frequencyHz,
    int rate,
    int gain,
  ) => _configure(handle, frequencyHz, rate, gain);

  @override
  int start(Pointer<SdrHandle> handle) => _start(handle);

  @override
  int stop(Pointer<SdrHandle> handle) => _stop(handle);

  @override
  int close(Pointer<SdrHandle> handle) => _close(handle);

  @override
  SdrCoreStats stats(Pointer<SdrHandle> handle) {
    final ptr = calloc<_NativeStats>();
    try {
      ptr.ref.size = sizeOf<_NativeStats>();
      ptr.ref.revision = SdrCore.abiVersion;
      final code = _stats(handle, ptr);
      if (code != 0) throw SdrCoreError(code);
      final s = ptr.ref;
      return SdrCoreStats(
        s.state,
        s.source,
        s.inputSamples,
        s.processedSamples,
        s.droppedSamples,
        s.lastError,
        s.sampleRate,
        s.frequencyHz,
        s.gainTenthsDb,
        s.checksum,
      );
    } finally {
      calloc.free(ptr);
    }
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Opaque handle from native/include/sdrcore.h.
final class SdrHandle extends Opaque {}

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

/// Explicitly loads the native core. It does not replace the Dart receiver.
final class SdrCore {
  SdrCore._(this._bindings) {
    final version = _bindings.version();
    if (version != abiVersion) {
      throw UnsupportedError(
        'Unsupported sdrcore ABI $version (expected $abiVersion)',
      );
    }
  }

  /// Current revision of native/include/sdrcore.h, not an application version.
  static const abiVersion = 2;

  /// On Android loads the packaged arm64 library. On Linux, supply [libraryPath]
  /// or put libsdrcore.so on the loader path. Other platforms are not built.
  factory SdrCore.open({String? libraryPath}) {
    if (!Platform.isAndroid && !Platform.isLinux) {
      throw UnsupportedError(
        'libsdrcore.so is only built for Android arm64 and Linux',
      );
    }
    final library = DynamicLibrary.open(libraryPath ?? 'libsdrcore.so');
    return SdrCore._(_DynamicSdrCoreBindings(library));
  }

  /// Allows lifecycle checks with bindings that do not allocate native memory.
  factory SdrCore.withBindings(SdrCoreBindings bindings) => SdrCore._(bindings);

  final SdrCoreBindings _bindings;

  /// Calls native sdr_version (ABI revision, not receiver state).
  int get version => _bindings.version();

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
    if (result != 0) throw StateError('Native core error $result');
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
final class _DynamicSdrCoreBindings implements SdrCoreV2Bindings {
  _DynamicSdrCoreBindings(this._library);

  final DynamicLibrary _library;
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
      if (code != 0) throw StateError('Native core error $code');
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

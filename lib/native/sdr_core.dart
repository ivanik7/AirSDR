// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ffi';
import 'dart:io';

/// Opaque handle from native/include/sdrcore.h; N0 has no receive operations.
final class SdrHandle extends Opaque {}

/// The three functions in the N0 C ABI. Injection permits lifecycle tests without a .so.
abstract interface class SdrCoreBindings {
  int version();
  Pointer<SdrHandle> create();
  void destroy(Pointer<SdrHandle> handle);
}

/// Explicitly loads the inert N0 core. It does not replace the Dart receiver.
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
  static const abiVersion = 1;

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

  /// Allocates one inert native handle; caller must call dispose on the result.
  SdrCoreInstance create() {
    final handle = _bindings.create();
    if (handle == nullptr) {
      throw StateError('sdr_create returned NULL');
    }
    return SdrCoreInstance._(handle, _bindings.destroy);
  }
}

/// Exclusively owns one handle. Explicit dispose is required; no GC-only cleanup.
final class SdrCoreInstance {
  SdrCoreInstance._(this._handle, this._destroy);

  Pointer<SdrHandle> _handle;
  final void Function(Pointer<SdrHandle>) _destroy;

  bool get isDisposed => _handle == nullptr;

  void dispose() {
    final handle = _handle;
    if (handle == nullptr) return;
    _handle = nullptr;
    _destroy(handle);
  }
}

// Exact C signatures: uint32_t(void), SdrHandle*(void), void(SdrHandle*).
final class _DynamicSdrCoreBindings implements SdrCoreBindings {
  _DynamicSdrCoreBindings(this._library);

  final DynamicLibrary _library;
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
}

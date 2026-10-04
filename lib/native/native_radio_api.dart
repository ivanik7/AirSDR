// SPDX-License-Identifier: GPL-3.0-or-later
// ABI v3 transport. All calls are synchronous and serialized by the controller;
// neither IQ nor PCM crosses this interface.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'sdr_core.dart';

const nativeRadioAbi = 3;
const nativeMaxFftWidth = 2048;

final class NativeControls {
  const NativeControls({
    required this.centerHz,
    required this.offsetHz,
    required this.sampleRate,
    required this.mode,
    required this.bandwidthHz,
    required this.gainTenthsDb,
    required this.agc,
    required this.squelch,
    required this.squelchLevelDb,
    required this.autoOffsetDb,
    required this.volume,
    required this.muted,
  });
  final int centerHz, offsetHz, sampleRate, mode, bandwidthHz, gainTenthsDb;
  final bool agc, muted;
  final int squelch;
  final double squelchLevelDb, autoOffsetDb, volume;
}

final class NativeDisplay {
  const NativeDisplay(this.offsetHz, this.bandwidthHz, this.width);
  final int offsetHz, bandwidthHz, width;
}

final class NativeSnapshot {
  const NativeSnapshot({
    required this.state,
    required this.source,
    required this.lastError,
    required this.sampleRate,
    required this.centerHz,
    required this.offsetHz,
    required this.mode,
    required this.bandwidthHz,
    required this.gainTenthsDb,
    required this.squelchOpen,
    required this.squelchReady,
    required this.squelchMetricDb,
    required this.squelchThresholdDb,
    required this.generation,
    required this.controlSequence,
    required this.errorSequence,
    required this.inputSamples,
    required this.processedSamples,
    required this.droppedSamples,
    required this.audioFrames,
    required this.audioDroppedFrames,
    required this.audioNonsilentFrames,
    required this.fftOverwrites,
  });
  final int state, source, lastError, sampleRate, centerHz, offsetHz, mode;
  final int bandwidthHz, gainTenthsDb, generation, controlSequence;
  final int errorSequence, inputSamples, processedSamples, droppedSamples;
  final int audioFrames,
      audioDroppedFrames,
      audioNonsilentFrames,
      fftOverwrites;
  final bool squelchOpen, squelchReady;
  final double squelchMetricDb, squelchThresholdDb;
}

final class NativeFft {
  const NativeFft(
    this.sequence,
    this.generation,
    this.controlSequence,
    this.lowHz,
    this.highHz,
    this.bins,
  );
  final int sequence, generation, controlSequence, lowHz, highHz;
  final Float32List bins;
}

/// A null FFT means NO_DATA; the caller never sees a native pointer.
abstract interface class NativeRadioApi {
  Pointer<SdrHandle> create();
  void destroy(Pointer<SdrHandle> handle);
  void openSynthetic(Pointer<SdrHandle> handle, int rate);
  void openFile(Pointer<SdrHandle> handle, int fd, int rate);
  void openUsb(Pointer<SdrHandle> handle, int fd, int source);
  void openHostUsb(Pointer<SdrHandle> handle, int bus, int address, int source);
  List<SdrHostUsbDevice> hostDevices();
  void controls(Pointer<SdrHandle> handle, NativeControls controls);
  void display(Pointer<SdrHandle> handle, NativeDisplay display);
  void audioSink(Pointer<SdrHandle> handle, String spec);
  void start(Pointer<SdrHandle> handle);
  void stop(Pointer<SdrHandle> handle);
  void close(Pointer<SdrHandle> handle);
  NativeSnapshot snapshot(Pointer<SdrHandle> handle);
  NativeFft? fft(Pointer<SdrHandle> handle, int afterSequence);
}

// C layout: native/include/sdrcore_v3.h. calloc zeroes reserved fields AND
// implicit padding, as required by the ABI.
final class _Controls extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int revision;
  @Uint64()
  external int centerHz;
  @Int64()
  external int offsetHz;
  @Uint32()
  external int sampleRate;
  @Uint32()
  external int mode;
  @Uint32()
  external int bandwidthHz;
  @Int32()
  external int gainTenthsDb;
  @Uint32()
  external int agc;
  @Uint32()
  external int squelch;
  @Float()
  external double squelchLevelDb;
  @Float()
  external double autoOffsetDb;
  @Float()
  external double volume;
  @Uint32()
  external int muted;
  @Uint32()
  external int reserved;
}

final class _Display extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int revision;
  @Int64()
  external int offsetHz;
  @Uint32()
  external int bandwidthHz;
  @Uint32()
  external int width;
}

final class _Snapshot extends Struct {
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
  external int centerHz;
  @Int64()
  external int offsetHz;
  @Uint32()
  external int mode;
  @Uint32()
  external int bandwidthHz;
  @Int32()
  external int gainTenthsDb;
  @Uint32()
  external int squelchOpen;
  @Uint32()
  external int squelchReady;
  @Uint32()
  external int reserved;
  @Float()
  external double squelchMetricDb;
  @Float()
  external double squelchThresholdDb;
  @Uint64()
  external int generation;
  @Uint64()
  external int controlSequence;
  @Uint64()
  external int errorSequence;
  @Uint64()
  external int inputSamples;
  @Uint64()
  external int processedSamples;
  @Uint64()
  external int droppedSamples;
  @Uint64()
  external int audioFrames;
  @Uint64()
  external int audioDroppedFrames;
  @Uint64()
  external int audioNonsilentFrames;
  @Uint64()
  external int fftOverwrites;
}

final class _Fft extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int revision;
  @Uint64()
  external int sequence;
  @Uint64()
  external int generation;
  @Uint64()
  external int controlSequence;
  @Uint64()
  external int monotonicNs;
  @Int64()
  external int lowHz;
  @Int64()
  external int highHz;
  @Uint32()
  external int width;
  @Uint32()
  external int reserved;
}

// Same 236-byte host-only extension as sdrcore_host.h.
final class _HostDevice extends Struct {
  @Uint32()
  external int size;
  @Uint16()
  external int vid;
  @Uint16()
  external int pid;
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
}

final class FfiNativeRadioApi implements NativeRadioApi {
  /// Exact ABI sizes verified against native/include/sdrcore_v3.h.
  static List<int> get layoutSizes => [
    sizeOf<_Controls>(),
    sizeOf<_Display>(),
    sizeOf<_Snapshot>(),
    sizeOf<_Fft>(),
    sizeOf<_HostDevice>(),
  ];

  FfiNativeRadioApi(DynamicLibrary library) : _lib = library {
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
      'sdr_version',
    )();
    if (version != nativeRadioAbi) {
      throw UnsupportedError(
        'Unsupported native radio ABI $version (expected 3)',
      );
    }
    // Resolve every required v3 symbol before a handle can be allocated.
    for (final symbol in <String>[
      'sdr_v3_set_controls',
      'sdr_v3_set_display',
      'sdr_v3_set_audio_sink',
      'sdr_v3_start',
      'sdr_v3_stop',
      'sdr_v3_snapshot',
      'sdr_v3_read_fft',
    ]) {
      if (!library.providesSymbol(symbol)) {
        throw UnsupportedError('Incomplete native radio ABI: $symbol');
      }
    }
  }

  factory FfiNativeRadioApi.open({String? libraryPath}) =>
      FfiNativeRadioApi(openSdrCoreLibrary(libraryPath));

  final DynamicLibrary _lib;
  static void _check(int code) {
    if (code != 0) throw SdrCoreError(code);
  }

  late final _create = _lib
      .lookupFunction<
        Pointer<SdrHandle> Function(),
        Pointer<SdrHandle> Function()
      >('sdr_create');
  late final _destroy = _lib
      .lookupFunction<
        Void Function(Pointer<SdrHandle>),
        void Function(Pointer<SdrHandle>)
      >('sdr_destroy');
  late final _openSynthetic = _lib
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Uint32),
        int Function(Pointer<SdrHandle>, int)
      >('sdr_v2_open_synthetic');
  late final _openFile = _lib
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Int32, Uint32),
        int Function(Pointer<SdrHandle>, int, int)
      >('sdr_v2_open_file');
  late final _openUsb = _lib
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Int32, Uint32),
        int Function(Pointer<SdrHandle>, int, int)
      >('sdr_v2_open_usb');
  late final _hostOpen = _lib
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Uint8, Uint8, Uint32),
        int Function(Pointer<SdrHandle>, int, int, int)
      >('sdr_host_open_usb');
  late final _hostList = _lib
      .lookupFunction<
        Int32 Function(Pointer<_HostDevice>, Uint32, Pointer<Uint32>),
        int Function(Pointer<_HostDevice>, int, Pointer<Uint32>)
      >('sdr_host_usb_list');
  late final _controls = _lib
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Pointer<_Controls>),
        int Function(Pointer<SdrHandle>, Pointer<_Controls>)
      >('sdr_v3_set_controls');
  late final _display = _lib
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Pointer<_Display>),
        int Function(Pointer<SdrHandle>, Pointer<_Display>)
      >('sdr_v3_set_display');
  late final _sink = _lib
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Pointer<Uint8>, Uint32),
        int Function(Pointer<SdrHandle>, Pointer<Uint8>, int)
      >('sdr_v3_set_audio_sink');
  late final _start = _lib
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>),
        int Function(Pointer<SdrHandle>)
      >('sdr_v3_start');
  late final _stop = _lib
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>),
        int Function(Pointer<SdrHandle>)
      >('sdr_v3_stop');
  late final _close = _lib
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>),
        int Function(Pointer<SdrHandle>)
      >('sdr_v2_close');
  late final _snapshot = _lib
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Pointer<_Snapshot>),
        int Function(Pointer<SdrHandle>, Pointer<_Snapshot>)
      >('sdr_v3_snapshot');
  late final _fft = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<SdrHandle>,
          Uint64,
          Pointer<_Fft>,
          Pointer<Float>,
          Uint32,
        ),
        int Function(
          Pointer<SdrHandle>,
          int,
          Pointer<_Fft>,
          Pointer<Float>,
          int,
        )
      >('sdr_v3_read_fft');

  @override
  Pointer<SdrHandle> create() {
    _destroy; // Ensure cleanup is available before allocation.
    final h = _create();
    if (h == nullptr) throw StateError('sdr_create returned NULL');
    return h;
  }

  @override
  void destroy(Pointer<SdrHandle> h) => _destroy(h);
  @override
  void openSynthetic(Pointer<SdrHandle> h, int rate) =>
      _check(_openSynthetic(h, rate));
  @override
  void openFile(Pointer<SdrHandle> h, int fd, int rate) =>
      _check(_openFile(h, fd, rate));
  @override
  void openUsb(Pointer<SdrHandle> h, int fd, int source) =>
      _check(_openUsb(h, fd, source));
  @override
  void openHostUsb(Pointer<SdrHandle> h, int bus, int address, int source) =>
      _check(_hostOpen(h, bus, address, source));
  @override
  List<SdrHostUsbDevice> hostDevices() {
    final buf = calloc<_HostDevice>(64);
    final count = calloc<Uint32>();
    try {
      for (var i = 0; i < 64; i++) {
        buf[i].size = sizeOf<_HostDevice>();
      }
      _check(_hostList(buf, 64, count));
      String? text(Array<Uint8> data, int length) {
        final bytes = <int>[];
        for (var i = 0; i < length && data[i] != 0; i++) {
          bytes.add(data[i]);
        }
        if (bytes.isEmpty) return null;
        return utf8.decode(bytes, allowMalformed: true);
      }

      return [
        for (var i = 0; i < count.value.clamp(0, 64); i++)
          SdrHostUsbDevice(
            vendorId: buf[i].vid,
            productId: buf[i].pid,
            bus: buf[i].bus,
            address: buf[i].address,
            path: text(buf[i].path, 32) ?? '',
            manufacturer: text(buf[i].manufacturer, 64),
            product: text(buf[i].product, 64),
            serial: text(buf[i].serial, 64),
          ),
      ];
    } finally {
      calloc.free(buf);
      calloc.free(count);
    }
  }

  @override
  void controls(Pointer<SdrHandle> h, NativeControls value) {
    final p = calloc<_Controls>();
    try {
      final c = p.ref;
      c.size = sizeOf<_Controls>();
      c.revision = nativeRadioAbi;
      c.centerHz = value.centerHz;
      c.offsetHz = value.offsetHz;
      c.sampleRate = value.sampleRate;
      c.mode = value.mode;
      c.bandwidthHz = value.bandwidthHz;
      c.gainTenthsDb = value.gainTenthsDb;
      c.agc = value.agc ? 1 : 0;
      c.squelch = value.squelch;
      c.squelchLevelDb = value.squelchLevelDb;
      c.autoOffsetDb = value.autoOffsetDb;
      c.volume = value.volume;
      c.muted = value.muted ? 1 : 0;
      _check(_controls(h, p));
    } finally {
      calloc.free(p);
    }
  }

  @override
  void display(Pointer<SdrHandle> h, NativeDisplay value) {
    final p = calloc<_Display>();
    try {
      p.ref.size = sizeOf<_Display>();
      p.ref.revision = nativeRadioAbi;
      p.ref.offsetHz = value.offsetHz;
      p.ref.bandwidthHz = value.bandwidthHz;
      p.ref.width = value.width;
      _check(_display(h, p));
    } finally {
      calloc.free(p);
    }
  }

  @override
  void audioSink(Pointer<SdrHandle> h, String spec) {
    final bytes = utf8.encode(spec);
    if (bytes.isEmpty || bytes.length > 1024 || bytes.contains(0)) {
      throw ArgumentError.value(spec, 'spec', 'Invalid audio sink spec');
    }
    final p = calloc<Uint8>(bytes.length);
    try {
      p.asTypedList(bytes.length).setAll(0, bytes);
      _check(_sink(h, p, bytes.length));
    } finally {
      calloc.free(p);
    }
  }

  @override
  void start(Pointer<SdrHandle> h) => _check(_start(h));
  @override
  void stop(Pointer<SdrHandle> h) => _check(_stop(h));
  @override
  void close(Pointer<SdrHandle> h) => _check(_close(h));
  @override
  NativeSnapshot snapshot(Pointer<SdrHandle> h) {
    final p = calloc<_Snapshot>();
    try {
      p.ref.size = sizeOf<_Snapshot>();
      p.ref.revision = nativeRadioAbi;
      _check(_snapshot(h, p));
      final s = p.ref;
      return NativeSnapshot(
        state: s.state,
        source: s.source,
        lastError: s.lastError,
        sampleRate: s.sampleRate,
        centerHz: s.centerHz,
        offsetHz: s.offsetHz,
        mode: s.mode,
        bandwidthHz: s.bandwidthHz,
        gainTenthsDb: s.gainTenthsDb,
        squelchOpen: s.squelchOpen != 0,
        squelchReady: s.squelchReady != 0,
        squelchMetricDb: s.squelchMetricDb,
        squelchThresholdDb: s.squelchThresholdDb,
        generation: s.generation,
        controlSequence: s.controlSequence,
        errorSequence: s.errorSequence,
        inputSamples: s.inputSamples,
        processedSamples: s.processedSamples,
        droppedSamples: s.droppedSamples,
        audioFrames: s.audioFrames,
        audioDroppedFrames: s.audioDroppedFrames,
        audioNonsilentFrames: s.audioNonsilentFrames,
        fftOverwrites: s.fftOverwrites,
      );
    } finally {
      calloc.free(p);
    }
  }

  @override
  NativeFft? fft(Pointer<SdrHandle> h, int afterSequence) {
    final p = calloc<_Fft>();
    final bins = calloc<Float>(nativeMaxFftWidth);
    try {
      p.ref.size = sizeOf<_Fft>();
      p.ref.revision = nativeRadioAbi;
      final code = _fft(h, afterSequence, p, bins, nativeMaxFftWidth);
      if (code == 1) return null; // NO_DATA: no output modified.
      _check(code);
      final m = p.ref;
      if (m.width < 1 || m.width > nativeMaxFftWidth) {
        throw StateError('Invalid native FFT width ${m.width}');
      }
      return NativeFft(
        m.sequence,
        m.generation,
        m.controlSequence,
        m.lowHz,
        m.highHz,
        Float32List.fromList(bins.asTypedList(m.width)),
      );
    } finally {
      calloc.free(p);
      calloc.free(bins);
    }
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Additive, optional native recording ABI. No IQ or PCM is transferred to Dart.
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'sdr_core.dart';

const sdrRecordRevision = 1;

abstract final class SdrRecordStream {
  static const iq = 1;
  static const audio = 2;
  static const squelchAudio = 4;
  static const decoderLog = 8;
}

abstract final class SdrRecordFormat {
  static const none = 0;
  static const wav = 1;
  static const flac = 2;
  static const mp3 = 3;
  static const opus = 4;
}

abstract final class SdrRecordState {
  static const idle = 0;
  static const active = 1;
  static const failed = 2;
}

abstract final class SdrRecordError {
  static const exists = -20;
  static const noSpace = -21;
  static const folderUnavailable = -22;
  static const notSeekable = -23;
  static const nameExhausted = -24;
}

final class SdrRecordCapabilities {
  const SdrRecordCapabilities(this.streams, this.formats);
  final int streams;
  final int formats;

  bool supports(int stream, int format) =>
      streams & stream == stream &&
      (format == SdrRecordFormat.none || formats & (1 << format) != 0);
}

final class SdrRecordConfig {
  const SdrRecordConfig({
    required this.streams,
    required this.audioFormat,
    required this.startUnixMs,
    required this.utcOffsetMinutes,
    this.audioBitrateKbps = 0,
  });
  final int streams;
  final int audioFormat;
  final int audioBitrateKbps;
  final int startUnixMs;
  final int utcOffsetMinutes;
}

final class SdrRecordStatus {
  const SdrRecordStatus({
    required this.state,
    required this.stopReason,
    required this.lastError,
    required this.errorStream,
    required this.streams,
    required this.audioFormat,
    required this.audioSampleRate,
    required this.audioChannels,
    required this.squelchSegmentOpen,
    required this.sessionId,
    required this.elapsedMs,
    required this.bytesWritten,
    required this.filesCreated,
    required this.segmentsCompleted,
    required this.iqSamplesWritten,
    required this.audioFramesWritten,
    required this.iqDroppedSamples,
    required this.audioDroppedFrames,
    required this.logEventsWritten,
    required this.logDroppedEvents,
  });
  final int state, stopReason, lastError, errorStream, streams, audioFormat;
  final int audioSampleRate, audioChannels, squelchSegmentOpen;
  final int sessionId, elapsedMs, bytesWritten, filesCreated;
  final int segmentsCompleted, iqSamplesWritten, audioFramesWritten;
  final int iqDroppedSamples, audioDroppedFrames, logEventsWritten;
  final int logDroppedEvents;
}

abstract interface class NativeRecordApi {
  SdrRecordCapabilities capabilities();
  int start(
    Pointer<SdrHandle> handle,
    SdrRecordConfig config,
    String folderLocator,
    List<String> logIds,
  );
  int stop(Pointer<SdrHandle> handle);
  SdrRecordStatus status(Pointer<SdrHandle> handle);
}

// Layout is fixed by native/include/sdrcore_record_v1.h. Keep the size probes
// in tests: struct layout changes require a new recording extension revision.
final class _RecordConfig extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int revision;
  @Uint32()
  external int streams;
  @Uint32()
  external int audioFormat;
  @Uint32()
  external int audioBitrateKbps;
  @Int32()
  external int utcOffsetMinutes;
  @Int64()
  external int startUnixMs;
  @Array(4)
  external Array<Uint32> reserved;
}

final class _RecordStatus extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int revision;
  @Uint32()
  external int state;
  @Uint32()
  external int stopReason;
  @Int32()
  external int lastError;
  @Uint32()
  external int errorStream;
  @Uint32()
  external int streams;
  @Uint32()
  external int audioFormat;
  @Uint32()
  external int audioSampleRate;
  @Uint32()
  external int audioChannels;
  @Uint32()
  external int squelchSegmentOpen;
  @Uint32()
  external int reserved;
  @Uint64()
  external int sessionId;
  @Uint64()
  external int elapsedMs;
  @Uint64()
  external int bytesWritten;
  @Uint64()
  external int filesCreated;
  @Uint64()
  external int segmentsCompleted;
  @Uint64()
  external int iqSamplesWritten;
  @Uint64()
  external int audioFramesWritten;
  @Uint64()
  external int iqDroppedSamples;
  @Uint64()
  external int audioDroppedFrames;
  @Uint64()
  external int logEventsWritten;
  @Uint64()
  external int logDroppedEvents;
}

final class FfiNativeRecordApi implements NativeRecordApi {
  FfiNativeRecordApi._(this._library);
  final DynamicLibrary _library;

  static List<int> get layoutSizes => [
    sizeOf<_RecordConfig>(),
    sizeOf<_RecordStatus>(),
  ];

  // Do not expose recording against an old/incomplete native library. In
  // particular, the folder provider and lifecycle notification are required
  // even on desktop so a future Android bridge cannot silently lose writes.
  static NativeRecordApi? tryOpen(DynamicLibrary library) {
    const names = [
      'sdr_record_version',
      'sdr_record_capabilities',
      'sdr_record_set_provider',
      'sdr_record_set_notify',
      'sdr_record_start',
      'sdr_record_stop',
      'sdr_record_status',
    ];
    if (names.any((name) => !library.providesSymbol(name))) return null;
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
      'sdr_record_version',
    );
    return version() == sdrRecordRevision
        ? FfiNativeRecordApi._(library)
        : null;
  }

  late final int Function(Pointer<Uint32>, Pointer<Uint32>) _capabilities =
      _library.lookupFunction<
        Int32 Function(Pointer<Uint32>, Pointer<Uint32>),
        int Function(Pointer<Uint32>, Pointer<Uint32>)
      >('sdr_record_capabilities');
  late final int Function(
    Pointer<SdrHandle>,
    Pointer<_RecordConfig>,
    Pointer<Uint8>,
    int,
    Pointer<Uint8>,
    int,
  )
  _start = _library
      .lookupFunction<
        Int32 Function(
          Pointer<SdrHandle>,
          Pointer<_RecordConfig>,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint8>,
          Uint32,
        ),
        int Function(
          Pointer<SdrHandle>,
          Pointer<_RecordConfig>,
          Pointer<Uint8>,
          int,
          Pointer<Uint8>,
          int,
        )
      >('sdr_record_start');
  late final int Function(Pointer<SdrHandle>) _stop = _library
      .lookupFunction<
        Int32 Function(Pointer<SdrHandle>),
        int Function(Pointer<SdrHandle>)
      >('sdr_record_stop');
  late final int Function(Pointer<SdrHandle>, Pointer<_RecordStatus>) _status =
      _library.lookupFunction<
        Int32 Function(Pointer<SdrHandle>, Pointer<_RecordStatus>),
        int Function(Pointer<SdrHandle>, Pointer<_RecordStatus>)
      >('sdr_record_status');

  @override
  SdrRecordCapabilities capabilities() {
    final streams = calloc<Uint32>();
    final formats = calloc<Uint32>();
    try {
      final result = _capabilities(streams, formats);
      if (result != SdrResult.ok) throw SdrCoreError(result);
      return SdrRecordCapabilities(streams.value, formats.value);
    } finally {
      calloc.free(streams);
      calloc.free(formats);
    }
  }

  @override
  int start(
    Pointer<SdrHandle> handle,
    SdrRecordConfig config,
    String folderLocator,
    List<String> logIds,
  ) {
    final folderBytes = utf8.encode(folderLocator);
    final idsBytes = utf8.encode(logIds.join(','));
    if (folderBytes.isEmpty ||
        folderBytes.length > 4096 ||
        idsBytes.length > 512 ||
        logIds.length > 16 ||
        folderBytes.contains(0) ||
        idsBytes.contains(0)) {
      return SdrResult.invalidArgument;
    }
    final native = calloc<_RecordConfig>();
    final folder = calloc<Uint8>(folderBytes.length);
    final ids = idsBytes.isEmpty ? nullptr : calloc<Uint8>(idsBytes.length);
    try {
      native.ref.size = sizeOf<_RecordConfig>();
      native.ref.revision = sdrRecordRevision;
      native.ref.streams = config.streams;
      native.ref.audioFormat = config.audioFormat;
      native.ref.audioBitrateKbps = config.audioBitrateKbps;
      native.ref.utcOffsetMinutes = config.utcOffsetMinutes;
      native.ref.startUnixMs = config.startUnixMs;
      folder.asTypedList(folderBytes.length).setAll(0, folderBytes);
      if (idsBytes.isNotEmpty) {
        ids.asTypedList(idsBytes.length).setAll(0, idsBytes);
      }
      return _start(
        handle,
        native,
        folder,
        folderBytes.length,
        ids,
        idsBytes.length,
      );
    } finally {
      calloc.free(native);
      calloc.free(folder);
      if (ids != nullptr) calloc.free(ids);
    }
  }

  @override
  int stop(Pointer<SdrHandle> handle) => _stop(handle);

  @override
  SdrRecordStatus status(Pointer<SdrHandle> handle) {
    final native = calloc<_RecordStatus>();
    try {
      native.ref.size = sizeOf<_RecordStatus>();
      native.ref.revision = sdrRecordRevision;
      final result = _status(handle, native);
      if (result != SdrResult.ok) throw SdrCoreError(result);
      final s = native.ref;
      return SdrRecordStatus(
        state: s.state,
        stopReason: s.stopReason,
        lastError: s.lastError,
        errorStream: s.errorStream,
        streams: s.streams,
        audioFormat: s.audioFormat,
        audioSampleRate: s.audioSampleRate,
        audioChannels: s.audioChannels,
        squelchSegmentOpen: s.squelchSegmentOpen,
        sessionId: s.sessionId,
        elapsedMs: s.elapsedMs,
        bytesWritten: s.bytesWritten,
        filesCreated: s.filesCreated,
        segmentsCompleted: s.segmentsCompleted,
        iqSamplesWritten: s.iqSamplesWritten,
        audioFramesWritten: s.audioFramesWritten,
        iqDroppedSamples: s.iqDroppedSamples,
        audioDroppedFrames: s.audioDroppedFrames,
        logEventsWritten: s.logEventsWritten,
        logDroppedEvents: s.logDroppedEvents,
      );
    } finally {
      calloc.free(native);
    }
  }
}

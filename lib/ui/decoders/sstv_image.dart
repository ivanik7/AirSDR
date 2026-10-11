// SPDX-License-Identifier: GPL-3.0-or-later
//
// Assembles SSTV pictures from the native v1 image events (frozen contract:
// STATUS-sstv-audit.md, "Frozen v1 image event contract"). Pixels arrive as
// bounded base64 BGR rows already decoded natively by csdr-plus; Dart only
// validates, stores and displays them. No audio or IQ ever reaches Dart.
import 'dart:convert';
import 'dart:typed_data';

import 'decoder_contract.dart';

/// VIS id -> (name, width, height) exactly as the native adapter reports
/// them (native/src/decoder/sstv.cpp `kVisTable`). These are the 24 modes the
/// audit confirmed upstream instantiates; AVT-90 (VIS 68) is disabled
/// upstream and therefore absent.
const Map<int, (String, int, int)> kSstvModes = {
  0: ('Robot 12', 160, 120),
  4: ('Robot 24', 160, 120),
  8: ('Robot 36', 320, 240),
  12: ('Robot 72', 320, 240),
  32: ('Martin 4', 320, 128),
  36: ('Martin 3', 320, 128),
  40: ('Martin 2', 320, 256),
  44: ('Martin 1', 320, 256),
  48: ('Scottie 4', 320, 128),
  51: ('Wraase SC2-30', 320, 128),
  52: ('Scottie 3', 320, 128),
  55: ('Wraase SC2-180', 320, 256),
  56: ('Scottie 2', 320, 256),
  59: ('Wraase SC2-60', 320, 256),
  60: ('Scottie 1', 320, 256),
  63: ('Wraase SC2-120', 320, 256),
  76: ('Scottie DX', 320, 256),
  93: ('PD-50', 320, 256),
  94: ('PD-290', 800, 616),
  95: ('PD-120', 640, 496),
  96: ('PD-180', 640, 496),
  97: ('PD-240', 640, 496),
  98: ('PD-160', 512, 400),
  99: ('PD-90', 320, 256),
};

/// Completed/partial pictures kept for this app session (newest first).
/// Worst case 8 x PD-290 RGBA (1.97 MB) plus the one frame in progress.
const int kSstvGalleryCap = 8;

const _underlyings = {'usb', 'lsb', 'nfm'};
const _nativeReasons = {'end', 'sync_lost', 'retune', 'mode', 'stop'};

enum SstvFrameStatus { receiving, complete, partial }

/// One picture: metadata from the `start` event and the rows received so
/// far. Rows not (yet) received stay transparent; padded rows are the
/// upstream black fill and are counted separately, never hidden.
class SstvFrame {
  SstvFrame._({
    required this.frameId,
    required this.vis,
    required this.mode,
    required this.width,
    required this.height,
    required this.timestampUtc,
    required this.frequencyHz,
    required this.underlying,
  }) : rgba = Uint8List(width * height * 4);

  final String frameId;
  final int vis;
  final String mode;
  final int width, height;

  /// Capture (VIS/header) time stamped natively, not UI receipt time.
  final DateTime timestampUtc;
  final int frequencyHz;
  final String underlying;

  /// Row-major RGBA, alpha 0 for rows that were never received.
  final Uint8List rgba;
  int receivedLines = 0;
  int paddedLines = 0;
  SstvFrameStatus status = SstvFrameStatus.receiving;

  /// Native reason (`end`, `sync_lost`, `retune`, `mode`, `stop`) or a UI
  /// one (`lost` for a gap/malformed/overflowed event stream, `restart`,
  /// `deselect`); null while receiving.
  String? reason;

  /// Bumped on every received row so views know to redraw.
  int revision = 0;

  /// OpenWebRX+ `Storage.makeFileName("SSTV-{0}", frequency)`:
  /// `SSTV-<UTC yyMMdd-HHmmss>-<kHz>`, plus `-partial` when incomplete.
  String get fileStem {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = timestampUtc;
    final stamp =
        '${two(t.year % 100)}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    final khz = frequencyHz > 0 ? '-${frequencyHz ~/ 1000}' : '';
    final suffix = status == SstvFrameStatus.partial ? '-partial' : '';
    return 'SSTV-$stamp$khz$suffix';
  }

  void _putRow(int line, Uint8List bgr) {
    final base = line * width * 4;
    for (var x = 0, i = 0; x < width; x++, i += 3) {
      final o = base + x * 4;
      rgba[o] = bgr[i + 2];
      rgba[o + 1] = bgr[i + 1];
      rgba[o + 2] = bgr[i];
      rgba[o + 3] = 255;
    }
  }
}

/// Validates and assembles v1 events of the selected SSTV decoder. One
/// frame is assembled at a time; finished frames move into a bounded
/// gallery. Anything inconsistent closes the frame as partial (`lost`)
/// instead of drawing a plausible-looking corrupted picture.
class SstvReceiver {
  SstvFrame? _current;
  final List<SstvFrame> _gallery = [];

  /// Human-readable note about the last frame that produced no picture.
  String? lastIssue;

  SstvFrame? get current => _current;
  List<SstvFrame> get gallery => List.unmodifiable(_gallery);

  /// Applies one decoded JSON payload. [tunedFrequencyHz] is the receiver's
  /// current tuned frequency: a `start` stamped with another one is a stale
  /// event from before a retune. [eventsLost] means the native FIFO dropped
  /// events since the previous poll. Returns whether anything visible changed.
  bool handle(
    DecoderResult kind,
    Map<String, Object?> data, {
    required int tunedFrequencyHz,
    required bool eventsLost,
  }) {
    if (data['source'] != 'sstv' || data['version'] != 1) return false;
    var changed = false;
    if (eventsLost && _current != null) {
      _close(SstvFrameStatus.partial, 'lost');
      changed = true;
    }
    if (kind == DecoderResult.imageProgress) {
      final phase = data['phase'];
      if (phase == 'start') return _start(data, tunedFrequencyHz) || changed;
      if (phase == 'line') return _line(data) || changed;
      return changed;
    }
    if (kind == DecoderResult.imageComplete) return _complete(data) || changed;
    return changed;
  }

  /// Ends the frame in progress (retune, mode change, stop, deselect...),
  /// keeping already received rows as a clearly partial picture.
  bool abort(String reason) {
    if (_current == null) return false;
    _close(SstvFrameStatus.partial, reason);
    return true;
  }

  void clearGallery() {
    _gallery.clear();
    lastIssue = null;
  }

  /// Frees everything, including the frame in progress.
  void clear() {
    _current = null;
    clearGallery();
  }

  bool _start(Map<String, Object?> d, int tunedFrequencyHz) {
    final frameId = d['frame_id'];
    final vis = d['vis'];
    final width = d['width'];
    final height = d['height'];
    final frequency = d['frequency_hz'];
    final underlying = d['underlying'];
    final stamp = d['timestamp_utc'];
    if (frameId is! String ||
        frameId.isEmpty ||
        int.tryParse(frameId) == null) {
      return false;
    }
    if (vis is! int || width is! int || height is! int) return false;
    final spec = kSstvModes[vis];
    if (spec == null ||
        spec.$1 != d['sstv_mode'] ||
        spec.$2 != width ||
        spec.$3 != height) {
      return false;
    }
    if (frequency is! int || frequency != tunedFrequencyHz) return false;
    if (underlying is! String || !_underlyings.contains(underlying)) {
      return false;
    }
    final time = stamp is String ? DateTime.tryParse(stamp) : null;
    if (time == null || !time.isUtc) return false;
    if (_current != null) {
      if (_current!.frameId == frameId) return false;
      _close(SstvFrameStatus.partial, 'lost');
    }
    _current = SstvFrame._(
      frameId: frameId,
      vis: vis,
      mode: spec.$1,
      width: width,
      height: height,
      timestampUtc: time,
      frequencyHz: frequency,
      underlying: underlying,
    );
    return true;
  }

  bool _line(Map<String, Object?> d) {
    final frame = _current;
    if (frame == null || d['frame_id'] != frame.frameId) return false;
    final line = d['line'];
    final padded = d['padded'];
    final pixels = d['pixels_bgr_base64'];
    Uint8List? bgr;
    if (pixels is String && pixels.length <= ((frame.width * 3 + 2) ~/ 3) * 4) {
      try {
        bgr = base64Decode(pixels);
      } on FormatException {
        bgr = null;
      }
    }
    if (line is! int ||
        line != frame.receivedLines ||
        line >= frame.height ||
        padded is! bool ||
        d['frequency_hz'] != frame.frequencyHz ||
        bgr == null ||
        bgr.length != frame.width * 3) {
      _close(SstvFrameStatus.partial, 'lost');
      return true;
    }
    frame._putRow(line, bgr);
    frame.receivedLines++;
    if (padded) frame.paddedLines++;
    frame.revision++;
    return true;
  }

  bool _complete(Map<String, Object?> d) {
    final frame = _current;
    if (frame == null || d['frame_id'] != frame.frameId) return false;
    final received = d['received_lines'];
    final padded = d['padded_lines'];
    final status = d['status'];
    final reason = d['reason'];
    final consistent =
        received == frame.receivedLines &&
        padded == frame.paddedLines &&
        reason is String &&
        _nativeReasons.contains(reason);
    if (!consistent) {
      _close(SstvFrameStatus.partial, 'lost');
    } else if (status == 'complete' &&
        reason == 'end' &&
        frame.receivedLines == frame.height) {
      _close(SstvFrameStatus.complete, reason);
    } else {
      _close(SstvFrameStatus.partial, reason);
    }
    return true;
  }

  void _close(SstvFrameStatus status, String reason) {
    final frame = _current!;
    _current = null;
    frame.status = status;
    frame.reason = reason;
    frame.revision++;
    if (frame.receivedLines == 0) {
      lastIssue =
          '${frame.mode}: строки не получены (${sstvReasonLabel(reason)})';
      return;
    }
    lastIssue = null;
    _gallery.insert(0, frame);
    if (_gallery.length > kSstvGalleryCap) _gallery.removeLast();
  }
}

/// Short Russian label for a frame end reason (UI language of the app).
String sstvReasonLabel(String? reason) => switch (reason) {
  'end' => 'конец кадра',
  'sync_lost' => 'потеря синхронизации',
  'retune' => 'перестройка частоты',
  'mode' => 'смена демодулятора',
  'stop' => 'приём остановлен',
  'restart' => 'перезапуск приёма',
  'deselect' => 'декодер выключен',
  'lost' => 'потеря событий',
  _ => reason ?? '',
};

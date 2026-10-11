// SPDX-License-Identifier: GPL-3.0-or-later
//
// SSTV v1 image-event assembly (STATUS-sstv-audit.md "Frozen v1 image event
// contract"), PNG encoding and the Linux file save.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/decoders/sstv_image.dart';
import 'package:sdr_flutter/ui/decoders/sstv_save.dart';

const _freq = 14230000;

Map<String, Object?> _meta({
  String frameId = '7',
  int vis = 8,
  String mode = 'Robot 36',
  int width = 320,
  int height = 240,
  int frequency = _freq,
}) => {
  'source': 'sstv',
  'version': 1,
  'frame_id': frameId,
  'vis': vis,
  'sstv_mode': mode,
  'width': width,
  'height': height,
  'timestamp_utc': '2026-10-11T14:30:05.123Z',
  'frequency_hz': frequency,
  'underlying': 'usb',
};

Map<String, Object?> _start({String frameId = '7', int frequency = _freq}) => {
  ..._meta(frameId: frameId, frequency: frequency),
  'phase': 'start',
  'line': null,
  'pixels_bgr_base64': null,
  'padded': null,
};

Map<String, Object?> _line(
  int line, {
  String frameId = '7',
  bool padded = false,
  int width = 320,
  int value = 0,
}) => {
  ..._meta(frameId: frameId),
  'phase': 'line',
  'line': line,
  'pixels_bgr_base64': base64Encode(
    Uint8List(width * 3)..fillRange(0, width * 3, value),
  ),
  'padded': padded,
};

Map<String, Object?> _complete({
  String frameId = '7',
  required int received,
  int padded = 0,
  String status = 'complete',
  String reason = 'end',
}) => {
  ..._meta(frameId: frameId),
  'received_lines': received,
  'padded_lines': padded,
  'status': status,
  'reason': reason,
};

bool _feed(SstvReceiver r, Map<String, Object?> data, {bool lost = false}) =>
    r.handle(
      data['phase'] == null
          ? DecoderResult.imageComplete
          : DecoderResult.imageProgress,
      data,
      tunedFrequencyHz: _freq,
      eventsLost: lost,
    );

void main() {
  group('SstvReceiver', () {
    test('assembles a complete frame from start, ordered lines and '
        'image_complete, then moves it to the gallery', () {
      final r = SstvReceiver();
      expect(_feed(r, _start()), isTrue);
      final frame = r.current!;
      expect(frame.mode, 'Robot 36');
      expect(frame.width, 320);
      expect(frame.height, 240);
      expect(frame.status, SstvFrameStatus.receiving);
      expect(frame.timestampUtc, DateTime.utc(2026, 10, 11, 14, 30, 5, 123));
      for (var i = 0; i < 240; i++) {
        expect(_feed(r, _line(i, value: i, padded: i == 3)), isTrue);
      }
      expect(frame.receivedLines, 240);
      expect(frame.paddedLines, 1);
      expect(frame.rgba[100 * 320 * 4], 100);
      expect(frame.rgba[100 * 320 * 4 + 3], 255);
      expect(frame.rgba[239 * 320 * 4 + 3], 255);
      expect(_feed(r, _complete(received: 240, padded: 1)), isTrue);
      expect(r.current, isNull);
      expect(r.gallery.single, same(frame));
      expect(frame.status, SstvFrameStatus.complete);
      expect(frame.reason, 'end');
    });

    test('rejects non-sstv, wrong version, unknown VIS, wrong dimensions, '
        'bad timestamp and stale frequency on start', () {
      final r = SstvReceiver();
      for (final bad in <Map<String, Object?>>[
        {..._start(), 'source': 'rds'},
        {..._start(), 'version': 2},
        {..._start(), 'vis': 68, 'sstv_mode': 'AVT 90'},
        {..._start(), 'width': 640},
        {..._start(), 'sstv_mode': 'Martin 1'},
        {..._start(), 'timestamp_utc': 'yesterday'},
        {..._start(), 'frame_id': ''},
        {..._start(), 'underlying': 'wfm'},
        _start(frequency: _freq + 5000),
      ]) {
        expect(_feed(r, bad), isFalse, reason: '$bad');
        expect(r.current, isNull);
      }
    });

    test('a line gap closes the frame as partial/lost with only the rows '
        'received before the gap, and later lines are ignored', () {
      final r = SstvReceiver();
      _feed(r, _start());
      _feed(r, _line(0));
      _feed(r, _line(1));
      expect(_feed(r, _line(3)), isTrue);
      expect(r.current, isNull);
      final frame = r.gallery.single;
      expect(frame.status, SstvFrameStatus.partial);
      expect(frame.reason, 'lost');
      expect(frame.receivedLines, 2);
      expect(_feed(r, _line(4)), isFalse);
      expect(_feed(r, _complete(received: 5)), isFalse);
      expect(r.gallery, hasLength(1));
    });

    test('a malformed row (wrong byte count) or queue loss marks the frame '
        'lost instead of drawing it', () {
      final r = SstvReceiver();
      _feed(r, _start());
      _feed(r, _line(0));
      _feed(r, _line(1, width: 100));
      expect(r.gallery.single.reason, 'lost');
      expect(r.gallery.single.receivedLines, 1);

      _feed(r, _start(frameId: '8'));
      _feed(r, _line(0, frameId: '8'));
      _feed(r, _line(1, frameId: '8'), lost: true);
      expect(r.gallery.first.reason, 'lost');
      expect(r.gallery.first.receivedLines, 1);
    });

    test('image_complete with mismatching counts or a missing last row is '
        'never complete', () {
      final r = SstvReceiver();
      _feed(r, _start());
      for (var i = 0; i < 10; i++) {
        _feed(r, _line(i));
      }
      _feed(r, _complete(received: 11));
      expect(r.gallery.single.status, SstvFrameStatus.partial);
      expect(r.gallery.single.reason, 'lost');

      _feed(r, _start(frameId: '9'));
      _feed(r, _line(0, frameId: '9'));
      _feed(
        r,
        _complete(
          frameId: '9',
          received: 1,
          status: 'partial',
          reason: 'sync_lost',
        ),
      );
      expect(r.gallery.first.status, SstvFrameStatus.partial);
      expect(r.gallery.first.reason, 'sync_lost');
    });

    test('a frame with zero rows is not kept, only reported', () {
      final r = SstvReceiver();
      _feed(r, _start());
      _feed(r, _complete(received: 0, status: 'partial', reason: 'sync_lost'));
      expect(r.gallery, isEmpty);
      expect(r.lastIssue, contains('Robot 36'));
    });

    test('abort keeps received rows as partial with the reason and frees '
        'the current assembly', () {
      final r = SstvReceiver();
      _feed(r, _start());
      _feed(r, _line(0));
      expect(r.abort('retune'), isTrue);
      expect(r.current, isNull);
      expect(r.gallery.single.reason, 'retune');
      expect(r.abort('retune'), isFalse);
      // A late line of the aborted frame never reopens it.
      expect(_feed(r, _line(1)), isFalse);
    });

    test('a new start while a frame is open closes the old one as lost', () {
      final r = SstvReceiver();
      _feed(r, _start());
      _feed(r, _line(0));
      _feed(r, _start(frameId: '8'));
      expect(r.current!.frameId, '8');
      expect(r.gallery.single.frameId, '7');
      expect(r.gallery.single.reason, 'lost');
    });

    test('gallery is bounded to $kSstvGalleryCap frames, newest first, and '
        'clear frees it', () {
      final r = SstvReceiver();
      for (var f = 1; f <= kSstvGalleryCap + 3; f++) {
        _feed(r, _start(frameId: '$f'));
        _feed(r, _line(0, frameId: '$f'));
        r.abort('stop');
      }
      expect(r.gallery, hasLength(kSstvGalleryCap));
      expect(r.gallery.first.frameId, '${kSstvGalleryCap + 3}');
      r.clearGallery();
      expect(r.gallery, isEmpty);
    });

    test('file name follows OpenWebRX+ Storage.makeFileName', () {
      final r = SstvReceiver();
      _feed(r, _start());
      _feed(r, _line(0));
      final frame = r.current!;
      expect(frame.fileStem, 'SSTV-261011-143005-14230');
      r.abort('stop');
      expect(frame.fileStem, 'SSTV-261011-143005-14230-partial');
    });
  });

  group('PNG', () {
    test('encodes BGR rows as an RGB PNG of the received height', () {
      final r = SstvReceiver();
      _feed(r, _start());
      final row = Uint8List(960);
      for (var x = 0; x < 320; x++) {
        row[x * 3] = 1; // B
        row[x * 3 + 1] = 2; // G
        row[x * 3 + 2] = 3; // R
      }
      r.handle(
        DecoderResult.imageProgress,
        {..._line(0), 'pixels_bgr_base64': base64Encode(row)},
        tunedFrequencyHz: _freq,
        eventsLost: false,
      );
      _feed(r, _line(1, value: 9));
      r.abort('stop');
      final png = encodeSstvPng(r.gallery.single);
      expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final header = ByteData.sublistView(png, 16, 24);
      expect(header.getUint32(0), 320);
      expect(header.getUint32(4), 2, reason: 'only received rows');
      expect(png[24], 8);
      expect(png[25], 2, reason: 'truecolour RGB');
      // IDAT starts after signature(8) + IHDR(25).
      final idatLength = ByteData.sublistView(png, 33, 37).getUint32(0);
      expect(String.fromCharCodes(png.sublist(37, 41)), 'IDAT');
      final raw = ZLibDecoder().convert(png.sublist(41, 41 + idatLength));
      expect(raw, hasLength(2 * (1 + 960)));
      expect(raw.sublist(0, 4), [0, 3, 2, 1]);
      expect(raw[962], 9);
      expect(
        String.fromCharCodes(png.sublist(png.length - 8, png.length - 4)),
        'IEND',
      );
    });
  });

  group('Linux save', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sstv_save'));
    tearDown(() => dir.deleteSync(recursive: true));

    test(
      'writes a real PNG file and never overwrites an existing one',
      () async {
        final r = SstvReceiver();
        _feed(r, _start());
        for (var i = 0; i < 240; i++) {
          _feed(r, _line(i));
        }
        _feed(r, _complete(received: 240));
        final saver = PlatformSstvImageSaver(
          platform: SstvSavePlatform.linux,
          linuxDirectory: () => Directory('${dir.path}/AirSDR'),
        );
        final frame = r.gallery.single;
        final first = await saver.save(frame);
        final second = await saver.save(frame);
        expect(first, '${dir.path}/AirSDR/SSTV-261011-143005-14230.png');
        expect(second, '${dir.path}/AirSDR/SSTV-261011-143005-14230-2.png');
        final bytes = File(first).readAsBytesSync();
        expect(bytes, encodeSstvPng(frame));
      },
    );

    test('Linux pictures dir honours XDG user-dirs and falls back to '
        '~/Pictures', () {
      final home = Directory('${dir.path}/home')..createSync();
      expect(
        linuxPicturesDirectory(environment: {'HOME': home.path}).path,
        '${home.path}/Pictures/AirSDR',
      );
      Directory('${home.path}/.config').createSync();
      File('${home.path}/.config/user-dirs.dirs')
          .writeAsStringSync('# comment\nXDG_PICTURES_DIR="\$HOME/Bilder"\n');
      expect(
        linuxPicturesDirectory(environment: {'HOME': home.path}).path,
        '${home.path}/Bilder/AirSDR',
      );
    });
  });
}

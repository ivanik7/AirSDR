// SPDX-License-Identifier: GPL-3.0-or-later
//
// PNG encoding and saving of decoded SSTV pictures: Android shared storage
// through MediaStore (lib/platform/media_store.dart), a plain file under the
// XDG Pictures directory on Linux.
import 'dart:io';
import 'dart:typed_data';

import '../../platform/media_store.dart';
import 'sstv_image.dart';

/// Encodes the received rows of [frame] (top to bottom, padded rows
/// included) as an 8-bit RGB PNG. Rows never received are not part of the
/// file, so a partial picture is never padded out to look complete.
Uint8List encodeSstvPng(SstvFrame frame) {
  final width = frame.width;
  final height = frame.receivedLines;
  if (height == 0) throw StateError('no rows received');
  final raw = Uint8List(height * (1 + width * 3));
  var o = 0;
  for (var y = 0; y < height; y++) {
    raw[o++] = 0; // filter: none
    final base = y * width * 4;
    for (var x = 0; x < width; x++) {
      final i = base + x * 4;
      raw[o++] = frame.rgba[i];
      raw[o++] = frame.rgba[i + 1];
      raw[o++] = frame.rgba[i + 2];
    }
  }
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2) // colour type: truecolour
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  final out = BytesBuilder(copy: false)
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  _chunk(out, 'IHDR', ihdr.buffer.asUint8List());
  _chunk(out, 'IDAT', Uint8List.fromList(ZLibEncoder().convert(raw)));
  _chunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}

void _chunk(BytesBuilder out, String type, Uint8List data) {
  final typeBytes = Uint8List.fromList(type.codeUnits);
  final len = ByteData(4)..setUint32(0, data.length);
  out
    ..add(len.buffer.asUint8List())
    ..add(typeBytes)
    ..add(data);
  var crc = _crcUpdate(0xFFFFFFFF, typeBytes);
  crc = _crcUpdate(crc, data) ^ 0xFFFFFFFF;
  out.add((ByteData(4)..setUint32(0, crc)).buffer.asUint8List());
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crcUpdate(int crc, Uint8List bytes) {
  var c = crc;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c;
}

/// Saves one picture and returns where it went (shown to the user).
abstract interface class SstvImageSaver {
  bool get supported;
  Future<String> save(SstvFrame frame);
}

enum SstvSavePlatform { android, linux, unsupported }

SstvSavePlatform _currentPlatform() => Platform.isAndroid
    ? SstvSavePlatform.android
    : Platform.isLinux
    ? SstvSavePlatform.linux
    : SstvSavePlatform.unsupported;

/// `$XDG_PICTURES_DIR/AirSDR` from `~/.config/user-dirs.dirs`, falling back
/// to `~/Pictures/AirSDR` (xdg-user-dirs semantics, no extra package).
Directory linuxPicturesDirectory({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? '.';
  var pictures = '$home/Pictures';
  final config = env['XDG_CONFIG_HOME'] ?? '$home/.config';
  final file = File('$config/user-dirs.dirs');
  try {
    if (file.existsSync()) {
      for (final raw in file.readAsLinesSync()) {
        final line = raw.trim();
        if (!line.startsWith('XDG_PICTURES_DIR=')) continue;
        var value = line.substring('XDG_PICTURES_DIR='.length);
        if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
          value = value.substring(1, value.length - 1);
        }
        value = value.replaceFirst(r'$HOME', home);
        if (value.startsWith('/') && value != home) pictures = value;
      }
    }
  } on FileSystemException {
    // Unreadable config: keep the documented fallback.
  }
  return Directory('$pictures/AirSDR');
}

class PlatformSstvImageSaver implements SstvImageSaver {
  PlatformSstvImageSaver({
    SstvSavePlatform? platform,
    Directory Function()? linuxDirectory,
    AndroidMediaStore? mediaStore,
  }) : _platform = platform ?? _currentPlatform(),
       _linuxDirectory = linuxDirectory ?? linuxPicturesDirectory,
       _mediaStore = mediaStore ?? AndroidMediaStore();

  final SstvSavePlatform _platform;
  final Directory Function() _linuxDirectory;
  final AndroidMediaStore _mediaStore;

  @override
  bool get supported => _platform != SstvSavePlatform.unsupported;

  @override
  Future<String> save(SstvFrame frame) async {
    final png = encodeSstvPng(frame);
    final stem = frame.fileStem;
    switch (_platform) {
      case SstvSavePlatform.android:
        return _mediaStore.saveImage(bytes: png, displayName: '$stem.png');
      case SstvSavePlatform.linux:
        final dir = _linuxDirectory();
        await dir.create(recursive: true);
        for (var n = 1; ; n++) {
          final file = File('${dir.path}/$stem${n == 1 ? '' : '-$n'}.png');
          try {
            // Exclusive create: never overwrite an earlier picture.
            await file.create(exclusive: true);
          } on PathExistsException {
            continue;
          }
          await file.writeAsBytes(png, flush: true);
          return file.path;
        }
      case SstvSavePlatform.unsupported:
        throw UnsupportedError(
          'Saving is not supported on this platform',
        );
    }
  }
}

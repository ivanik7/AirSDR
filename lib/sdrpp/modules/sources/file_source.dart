// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ source_modules/file_source/src/main.cpp (lines 1-230, minus ImGui/FileSelect)
// and wavreader.h (lines 1-80) @8c9f5ee.
//
// Differences:
//  * Input formats: besides WAV (16-bit PCM or 32-bit float stereo = I/Q, as SDR++'s
//    int16 / "Float32 Mode" workers), raw headerless interleaved files are supported:
//    cf32 (float32 LE), cu8 (rtl_sdr: (x − 127.5)/128), cs8 (hackrf_transfer: x/128),
//    cs16 (int16 LE /32768). Raw files need the sample rate as a parameter.
//  * WAV: C++ reads a fixed 44-byte header; the port walks the RIFF chunks to find `fmt ` and
//    `data` (files with LIST/other chunks work), and picks float32 mode from the format tag
//    (3 = IEEE float) or bit depth instead of a checkbox. 8-bit WAV is read as cu8.
//  * Centre frequency: `[0-9]+Hz` in the file name (getFrequency, main.cpp:183), or the
//    `centerFreq` parameter. Tuning is ignored (C++: `tuner::TUNER_MODE_IQ_ONLY`,
//    `centerFrequencyLocked = true`).
//  * Looping as in WavReader::readSamples (wraps to the data start at EOF).
//  * Pacing: [SourcePump] (real time, as fast as possible, or manual).
import 'dart:io';
import 'dart:typed_data';

import '../../signal_path/source_handler.dart';
import 'source_pump.dart';

/// Sample format of the IQ file.
enum IQFileFormat {
  cf32(8),
  cu8(2),
  cs8(2),
  cs16(4);

  const IQFileFormat(this.bytesPerSample);

  /// Bytes per complex sample.
  final int bytesPerSample;

  static IQFileFormat? parse(String s) {
    for (final f in values) {
      if (f.name == s.toLowerCase()) return f;
    }
    return null;
  }
}

/// Result of parsing a WAV header (`WavReader`).
class WavInfo {
  WavInfo(this.format, this.channelCount, this.sampleRate, this.bitDepth, this.dataOffset, this.dataSize);
  final int format; // 1 = PCM, 3 = IEEE float
  final int channelCount;
  final int sampleRate;
  final int bitDepth;
  final int dataOffset;
  final int dataSize;

  IQFileFormat? get iqFormat {
    if (format == 3 && bitDepth == 32) return IQFileFormat.cf32;
    if (bitDepth == 16) return IQFileFormat.cs16;
    if (bitDepth == 8) return IQFileFormat.cu8;
    if (format == 0xFFFE && bitDepth == 32) return IQFileFormat.cf32; // WAVE_FORMAT_EXTENSIBLE float
    return null;
  }

  /// Parses the RIFF chunks; returns null if not a valid WAV (wavreader.h:18-22).
  static WavInfo? parse(RandomAccessFile f) {
    f.setPositionSync(0);
    final hdr = f.readSync(12);
    if (hdr.length < 12) return null;
    if (String.fromCharCodes(hdr, 0, 4) != 'RIFF' || String.fromCharCodes(hdr, 8, 12) != 'WAVE') return null;
    int fmtTag = 0, channels = 0, rate = 0, bits = 0;
    bool haveFmt = false;
    int pos = 12;
    final len = f.lengthSync();
    while (pos + 8 <= len) {
      f.setPositionSync(pos);
      final ch = f.readSync(8);
      if (ch.length < 8) break;
      final id = String.fromCharCodes(ch, 0, 4);
      final size = ByteData.sublistView(ch).getUint32(4, Endian.little);
      if (id == 'fmt ') {
        final b = ByteData.sublistView(f.readSync(size < 16 ? 16 : size));
        fmtTag = b.getUint16(0, Endian.little);
        channels = b.getUint16(2, Endian.little);
        rate = b.getUint32(4, Endian.little);
        bits = b.getUint16(14, Endian.little);
        haveFmt = true;
      } else if (id == 'data') {
        if (!haveFmt) return null;
        final dataSize = (size == 0 || pos + 8 + size > len) ? len - pos - 8 : size;
        return WavInfo(fmtTag, channels, rate, bits, pos + 8, dataSize);
      }
      pos += 8 + size + (size & 1);
    }
    return null;
  }
}

class FileSource extends SourceHandler {
  /// [path]: WAV or raw IQ file. [format]: forced raw format (else deduced from the WAV header,
  /// then from the extension: .cf32/.cfile/.raw → cf32, .cu8, .cs8, .cs16). [sampleRate]: raw
  /// files only (WAV uses its header). [centerFreq]: overrides the `NNNHz` filename tag.
  FileSource(this.core,
      {required this.path,
      IQFileFormat? format,
      double sampleRate = 1000000,
      double? centerFreq,
      PumpMode mode = PumpMode.realTime}) {
    _open(format, sampleRate, centerFreq);
    _pump = SourcePump(_fill, sampleRate: this.sampleRate, mode: mode);
  }

  final SourceCore core;
  final String path;
  late final SourcePump _pump;

  late IQFileFormat format;
  late double sampleRate;
  double centerFreq = 0;
  bool isWav = false;

  RandomAccessFile? _file;
  int _dataStart = 0;
  int _dataEnd = 0;
  Uint8List _raw = Uint8List(0);
  bool running = false;
  bool selected = false;

  /// The file source ignores tuning (C++ `gui::waterfall.centerFrequencyLocked = true`).
  bool get centerFrequencyLocked => true;

  SourcePump get pump => _pump;

  /// Samples in the file (one loop).
  int get sampleCount => (_dataEnd - _dataStart) ~/ format.bytesPerSample;

  void _open(IQFileFormat? forced, double rawRate, double? center) {
    final f = File(path).openSync();
    _file = f;
    final wav = WavInfo.parse(f);
    if (wav != null && forced == null) {
      final fmt = wav.iqFormat;
      if (fmt == null || wav.channelCount != 2) {
        f.closeSync();
        throw FormatException('Unsupported WAV IQ file (fmt ${wav.format}, ${wav.bitDepth} bit, '
            '${wav.channelCount} ch): $path');
      }
      isWav = true;
      format = fmt;
      sampleRate = wav.sampleRate.toDouble();
      _dataStart = wav.dataOffset;
      _dataEnd = wav.dataOffset + wav.dataSize;
    } else {
      format = forced ?? _formatFromExtension(path);
      sampleRate = rawRate;
      _dataStart = 0;
      _dataEnd = f.lengthSync();
    }
    // Truncate to whole samples.
    _dataEnd = _dataStart + ((_dataEnd - _dataStart) ~/ format.bytesPerSample) * format.bytesPerSample;
    if (_dataEnd <= _dataStart) {
      f.closeSync();
      throw FormatException('IQ file has no samples: $path');
    }
    centerFreq = center ?? getFrequency(path);
    f.setPositionSync(_dataStart);
  }

  static IQFileFormat _formatFromExtension(String p) {
    final l = p.toLowerCase();
    if (l.endsWith('.cu8')) return IQFileFormat.cu8;
    if (l.endsWith('.cs8')) return IQFileFormat.cs8;
    if (l.endsWith('.cs16')) return IQFileFormat.cs16;
    return IQFileFormat.cf32;
  }

  /// main.cpp:183-190.
  static double getFrequency(String filename) {
    final m = RegExp(r'[0-9]+Hz').firstMatch(filename);
    if (m == null) return 0;
    final s = m.group(0)!;
    return double.tryParse(s.substring(0, s.length - 2)) ?? 0;
  }

  /// main.cpp:69-80 `menuSelected`.
  @override
  void select() {
    selected = true;
    core.setInputSampleRate(sampleRate);
    // tuner::tune(IQ_ONLY, centerFreq) / setBuffering(false): done by the host (DSP isolate)
    // which reads [centerFreq] and [centerFrequencyLocked].
  }

  /// main.cpp:82-88.
  @override
  void deselect() {
    selected = false;
  }

  /// main.cpp:90-97.
  @override
  Future<void> start(SourceSink sink) async {
    if (running) return;
    if (_file == null) return;
    running = true;
    _pump.start(sink);
  }

  /// main.cpp:99-110.
  @override
  Future<void> stop() async {
    if (!running) return;
    _pump.stop();
    running = false;
    rewind();
  }

  /// wavreader.h:53.
  void rewind() => _file?.setPositionSync(_dataStart);

  @override
  void tune(double frequencyHz) {}

  @override
  List<SourceSetting> get settings => <SourceSetting>[
        ChoiceSetting('format', 'Format', IQFileFormat.values.map((f) => f.name).toList(), format.index),
      ];

  @override
  void applySetting(String id, Object value) {
    // Format/sample rate are fixed when the file is opened (C++: only the file path is a setting).
  }

  void close() {
    _pump.stop();
    _file?.closeSync();
    _file = null;
  }

  /// Reads [count] samples (looping at EOF, wavreader.h:41-51) and converts to cf32.
  @pragma('vm:unsafe:no-bounds-checks')
  void _fill(Float32List out, int count) {
    final f = _file;
    if (f == null) {
      out.fillRange(0, 2 * count, 0);
      return;
    }
    final bytes = count * format.bytesPerSample;
    if (_raw.length < bytes) _raw = Uint8List(bytes);
    int got = 0;
    while (got < bytes) {
      final pos = f.positionSync();
      final avail = _dataEnd - pos;
      if (avail <= 0) {
        f.setPositionSync(_dataStart);
        continue;
      }
      final want = bytes - got < avail ? bytes - got : avail;
      final n = f.readIntoSync(_raw, got, got + want);
      if (n <= 0) {
        f.setPositionSync(_dataStart);
        continue;
      }
      got += n;
    }
    convert(format, _raw, out, count);
  }

  /// Converts [count] complex samples of [format] from [raw] into interleaved cf32 [out].
  @pragma('vm:unsafe:no-bounds-checks')
  static void convert(IQFileFormat format, Uint8List raw, Float32List out, int count) {
    final n = 2 * count;
    switch (format) {
      case IQFileFormat.cf32:
        final src = raw.buffer.asFloat32List(raw.offsetInBytes, n);
        out.setRange(0, n, src);
      case IQFileFormat.cu8:
        for (int i = 0; i < n; i++) {
          out[i] = (raw[i] - 127.5) * (1.0 / 128.0);
        }
      case IQFileFormat.cs8:
        final s = raw.buffer.asInt8List(raw.offsetInBytes, n);
        for (int i = 0; i < n; i++) {
          out[i] = s[i] * (1.0 / 128.0);
        }
      case IQFileFormat.cs16:
        final s = raw.buffer.asInt16List(raw.offsetInBytes, n);
        for (int i = 0; i < n; i++) {
          out[i] = s[i] * (1.0 / 32768.0); // volk_16i_s32f_convert_32f(…, 32768.0f, …)
        }
    }
  }
}

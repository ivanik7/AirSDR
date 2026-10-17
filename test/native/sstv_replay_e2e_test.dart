// SPDX-License-Identifier: GPL-3.0-or-later
//
// End-to-end SSTV replay through the production Dart + native path, no
// radio required: a CU8 IQ recording of a pySSTV transmission (made by
// native/tests/sstv_replay.cpp `make-iq`, see tool/sstv_oracle/README.md)
// is replayed in real time by the native file source (sdr_v2_open_file,
// paced at its declared rate) into NativeRadioController + DecoderSession,
// exactly as the Decoder tab drives a live dongle. Checks:
//
//   1. retune reset: a retune in the middle of a frame closes it as
//      partial (`retune`) and no row of the old tune is drawn afterwards;
//   2. after tuning back, the next pass of the (looping) recording decodes
//      a complete frame with the expected VIS/mode/size and no padded rows;
//   3. UI save: the gallery thumbnail opens the dialog, "Save PNG"
//      writes through the real Linux PlatformSstvImageSaver, and the PNG
//      on disk holds exactly the decoded rows. The PNG path is printed so
//      tool/sstv_oracle can score it against the source image.
//
// Run (skipped otherwise):
//   SDRCORE_HOST_LIBRARY=<build>/libsdrcore.so \
//   SSTV_REPLAY_IQ=<file.cu8> [SSTV_REPLAY_RATE=240000] \
//   [SSTV_REPLAY_VIS=8 SSTV_REPLAY_SIZE=320x240] [SSTV_REPLAY_SAVE_DIR=dir] \
//     flutter test test/native/sstv_replay_e2e_test.dart
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_decoder_api.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/native_radio_controller.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/decoders/sstv_image.dart';
import 'package:sdr_flutter/ui/decoders/sstv_panel.dart';
import 'package:sdr_flutter/ui/decoders/sstv_save.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

const _tunedHz = 14230000;

/// Production FFI API whose "synthetic" open replays [fd] instead: the
/// controller opens a device without fd/bus via openSynthetic, and the
/// native file source then paces the recording at its declared rate.
class _FileReplayApi implements NativeRadioApi {
  _FileReplayApi(this._inner, this.fd);
  final NativeRadioApi _inner;
  final int fd;
  @override
  void openSynthetic(Pointer<SdrHandle> h, int rate) =>
      _inner.openFile(h, fd, rate);
  @override
  Pointer<SdrHandle> create() => _inner.create();
  @override
  void destroy(Pointer<SdrHandle> h) => _inner.destroy(h);
  @override
  void openFile(Pointer<SdrHandle> h, int fd, int rate) =>
      _inner.openFile(h, fd, rate);
  @override
  void openUsb(Pointer<SdrHandle> h, int fd, int source) =>
      _inner.openUsb(h, fd, source);
  @override
  void openHostUsb(Pointer<SdrHandle> h, int bus, int address, int source) =>
      _inner.openHostUsb(h, bus, address, source);
  @override
  List<int> rtlTunerGains(Pointer<SdrHandle> h) => _inner.rtlTunerGains(h);
  @override
  List<SdrHostUsbDevice> hostDevices() => const [];
  @override
  void controls(Pointer<SdrHandle> h, NativeControls c) =>
      _inner.controls(h, c);
  @override
  void display(Pointer<SdrHandle> h, NativeDisplay d) => _inner.display(h, d);
  @override
  void stereo(Pointer<SdrHandle> h, bool enabled) => _inner.stereo(h, enabled);
  @override
  void audioSink(Pointer<SdrHandle> h, String spec) =>
      _inner.audioSink(h, spec);
  @override
  void start(Pointer<SdrHandle> h) => _inner.start(h);
  @override
  void stop(Pointer<SdrHandle> h) => _inner.stop(h);
  @override
  void close(Pointer<SdrHandle> h) => _inner.close(h);
  @override
  NativeSnapshot snapshot(Pointer<SdrHandle> h) => _inner.snapshot(h);
  @override
  NativeFft? fft(Pointer<SdrHandle> h, int afterSequence) =>
      _inner.fft(h, afterSequence);
}

class _ReplaySource implements NativeDeviceSource {
  _ReplaySource(this.rate);
  final int rate;
  late final NativeDevice device = NativeDevice(
    SdrDeviceInfo(
      id: 'replay:sstv',
      name: 'SSTV IQ replay',
      sampleRates: [rate.toDouble()],
      gain: const GainRange(min: 0, max: 50),
      hasAgc: false,
    ),
    // Any source id: without fd/bus the controller takes the synthetic
    // path, which _FileReplayApi turns into the file source.
    SdrSourceId.rtlsdr,
  );
  @override
  Stream<void> get changes => const Stream<void>.empty();
  @override
  Future<List<NativeDevice>> list() async => [device];
  @override
  Future<NativeDevice> open(NativeDevice d) async => d;
  @override
  Future<void> close(NativeDevice d) async {}
}

final DynamicLibrary _libc = DynamicLibrary.process();
final int Function(Pointer<Utf8>, int, int) _open = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
      int Function(Pointer<Utf8>, int, int)
    >('open');
final int Function(int) _close = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

int _openReadOnly(String path) {
  final p = path.toNativeUtf8();
  try {
    return _open(p, 0 /* O_RDONLY */, 0);
  } finally {
    calloc.free(p);
  }
}

/// Minimal reader for the PNGs encodeSstvPng writes (8-bit RGB, one IDAT,
/// filter 0 on every row). Returns (width, height, rgb).
(int, int, Uint8List) _readOwnPng(Uint8List png) {
  final bd = ByteData.sublistView(png);
  var o = 8;
  late int w, h;
  final idat = BytesBuilder();
  while (o < png.length) {
    final len = bd.getUint32(o);
    final type = String.fromCharCodes(png.sublist(o + 4, o + 8));
    final body = png.sublist(o + 8, o + 8 + len);
    if (type == 'IHDR') {
      w = ByteData.sublistView(body).getUint32(0);
      h = ByteData.sublistView(body).getUint32(4);
      expect(body[8], 8);
      expect(body[9], 2);
    } else if (type == 'IDAT') {
      idat.add(body);
    }
    o += 12 + len;
  }
  final raw = Uint8List.fromList(ZLibDecoder().convert(idat.takeBytes()));
  final rgb = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    expect(raw[y * (1 + w * 3)], 0, reason: 'filter none');
    rgb.setRange(y * w * 3, (y + 1) * w * 3, raw, y * (1 + w * 3) + 1);
  }
  return (w, h, rgb);
}

Future<void> _until(
  bool Function() done,
  Duration limit,
  String what,
) async {
  final end = DateTime.now().add(limit);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timeout waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final library = Platform.environment['SDRCORE_HOST_LIBRARY'];
  final iq = Platform.environment['SSTV_REPLAY_IQ'];
  final rate =
      int.tryParse(Platform.environment['SSTV_REPLAY_RATE'] ?? '') ?? 240000;
  final vis = int.tryParse(Platform.environment['SSTV_REPLAY_VIS'] ?? '') ?? 8;
  final size = (Platform.environment['SSTV_REPLAY_SIZE'] ?? '320x240')
      .split('x')
      .map(int.parse)
      .toList();
  final skip = library == null || iq == null
      ? 'set SDRCORE_HOST_LIBRARY and SSTV_REPLAY_IQ'
      : null;

  // Shared by the two tests: the first drives the real receiver, the
  // second saves the decoded frame through the real panel.
  NativeRadioController? radio;
  DecoderSession? session;
  var fd = -1;
  SstvFrame? decoded;

  tearDownAll(() {
    session?.dispose();
    radio?.dispose();
    if (fd >= 0) _close(fd);
  });

  test(
    'replayed IQ: retune resets a frame, next pass decodes it completely',
    () async {
      final iqBytes = File(iq!).lengthSync();
      final passSeconds = iqBytes / 2 / rate;
      fd = _openReadOnly(iq);
      expect(fd, greaterThanOrEqualTo(0), reason: 'open $iq');
      final lib = openSdrCoreLibrary(library);
      final r = NativeRadioController(
        api: _FileReplayApi(FfiNativeRadioApi(lib), fd),
        decoderApi: FfiNativeDecoderApi.tryOpen(lib),
        source: _ReplaySource(rate),
        autoStart: false,
      );
      radio = r;
      await r.refreshDevices();
      r.setSampleRate(rate.toDouble());
      r.setMode(DemodMode.usb);
      r.setTuning(centerFrequency: _tunedHz.toDouble(), vfoOffset: 0);
      await r.start();
      expect(r.running, isTrue, reason: '${r.lastError}');
      expect(r.sampleRate, rate);
      // At-rest invariant: the VFO is centred.
      expect(r.vfoOffset, 0);
      final s = DecoderSession(r);
      session = s;
      s.selectPreview('sstv');
      expect(s.failureReason, isNull);
      expect(s.active, isTrue);
      expect(s.currentSettings, {'mode': 'auto', 'underlying': 'usb'});

      // 1. Retune in the middle of the first pass.
      await _until(
        () => (s.sstv.current?.receivedLines ?? 0) >= 40,
        Duration(seconds: (passSeconds + 10).ceil()),
        'first 40 rows',
      );
      final first = s.sstv.current!;
      expect(first.vis, vis);
      expect(first.frequencyHz, _tunedHz);
      r.setTuning(centerFrequency: _tunedHz + 1000.0, vfoOffset: 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(first.status, SstvFrameStatus.partial);
      expect(first.reason, 'retune');
      final rowsAtRetune = first.receivedLines;
      expect(s.sstv.gallery.first, same(first));
      r.setTuning(centerFrequency: _tunedHz.toDouble(), vfoOffset: 0);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(first.receivedLines, rowsAtRetune, reason: 'no stale rows');
      // The rest of the first pass has no VIS: nothing may start.
      expect(s.sstv.current, isNull);

      // 2. The recording loops; its next pass is a whole transmission.
      await _until(
        () => s.sstv.gallery.length >= 2,
        Duration(seconds: (2 * passSeconds + 20).ceil()),
        'second frame',
      );
      final f = s.sstv.gallery.first;
      // ignore: avoid_print
      print(
        'sstv replay: ${f.mode} vis=${f.vis} ${f.width}x${f.height} '
        'rows=${f.receivedLines} padded=${f.paddedLines} status=${f.status} '
        'reason=${f.reason} dropped=${s.droppedEvents} '
        'first=${first.receivedLines} rows/${first.reason}',
      );
      expect(f, isNot(same(first)));
      expect(f.vis, vis);
      expect([f.width, f.height], size);
      expect(f.status, SstvFrameStatus.complete);
      expect(f.reason, 'end');
      expect(f.receivedLines, f.height);
      expect(f.paddedLines, 0);
      expect(f.frequencyHz, _tunedHz);
      expect(f.underlying, 'usb');
      expect(s.droppedEvents, 0);
      decoded = f;
      await r.stop();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  testWidgets('decoded frame saves from the panel as an exact PNG', (
    tester,
  ) async {
    final s = session;
    final f = decoded;
    if (s == null || f == null) fail('replay test did not decode a frame');
    final dir =
        Environment.saveDir ??
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp('sstv_save'),
        ))!;
    final saver = PlatformSstvImageSaver(
      platform: SstvSavePlatform.linux,
      linuxDirectory: () => dir,
    );
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SstvDecoderPanel(session: s, saver: saver),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(ValueKey('sstvThumb-${f.frameId}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sstvDialog')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sstvSave')));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.byKey(const ValueKey('sstvSaveResult')).evaluate().isNotEmpty) {
          break;
        }
      }
    });
    final text = tester
        .widget<SelectableText>(find.byKey(const ValueKey('sstvSaveResult')))
        .data!;
    expect(text, startsWith('Saved: '));
    final path = text.substring('Saved: '.length);
    expect(path, startsWith(dir.path));
    expect(path, endsWith('${f.fileStem}.png'));
    expect(f.fileStem, contains('-${_tunedHz ~/ 1000}'));
    expect(f.fileStem, isNot(contains('partial')));
    final png = (await tester.runAsync(() => File(path).readAsBytes()))!;
    final (w, h, rgb) = _readOwnPng(png);
    expect([w, h], [f.width, f.height]);
    for (var i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
      if (rgb[i] != f.rgba[j] ||
          rgb[i + 1] != f.rgba[j + 1] ||
          rgb[i + 2] != f.rgba[j + 2]) {
        fail('PNG pixel ${i ~/ 3} differs from the decoded frame');
      }
    }
    // ignore: avoid_print
    print('sstv saved: $path (${png.length} bytes)');
    await tester.pumpWidget(const SizedBox());
  }, skip: skip != null);
}

abstract final class Environment {
  static Directory? get saveDir {
    final d = Platform.environment['SSTV_REPLAY_SAVE_DIR'];
    if (d == null) return null;
    return Directory(d)..createSync(recursive: true);
  }
}

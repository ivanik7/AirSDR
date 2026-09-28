// Trace-diff test: lib/drivers/hackrf/hackrf.dart vs the real libhackrf
// (hackrf.c built on the host with a fake libusb, tool/oracle/hackrf/).
//
// Each scenario below mirrors the scenario_* function of
// tool/oracle/hackrf/hackrf_oracle.c line by line; the resulting trace must
// equal the committed golden trace tool/oracle/hackrf/golden/<name>.trace.
// Regenerate goldens with tool/oracle/hackrf/build.sh.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/drivers/hackrf/hackrf.dart';

import 'recording_usb_handle.dart';

String _dbits(double d) {
  final b = ByteData(8)..setFloat64(0, d, Endian.host);
  return b.getUint64(0, Endian.host).toRadixString(16).padLeft(16, '0');
}

String _hex8(int v) => v.toRadixString(16).padLeft(8, '0');
String _hex4(int v) => v.toRadixString(16).padLeft(4, '0');

int _rxCb(HackrfTransfer transfer) => 0;

class _Scenario {
  final RecordingUsbHandle usb;
  _Scenario(this.usb);

  void trace(String s) => usb.log(s);
  void r(String name, int v) => trace('RESULT $name=$v');

  void sampleRate(HackrfDevice dev, double sr) {
    final res = dev.setSampleRate(sr);
    trace('RESULT set_sample_rate(${_dbits(sr)})=$res');
  }

  HackrfDevice? doOpen() {
    final (res, dev) = hackrfOpenSetup(usb);
    trace('RESULT open=$res');
    if (res != hackrfSuccess) {
      trace('INFO open_error=${hackrfErrorName(res)}');
      return null;
    }
    return dev;
  }

  Future<void> doClose(HackrfDevice dev) async => r('close', await dev.close());
}

Future<List<String>> scenarioMain() async {
  final usb = RecordingUsbHandle(bcdDevice: 0x0112, currentConfig: 0);
  final s = _Scenario(usb);
  s.r('init', hackrfInit());
  final dev = s.doOpen();
  if (dev == null) return usb.trace;

  final (ra, api) = dev.usbApiVersionRead();
  s.r('usb_api_version_read', ra);
  s.trace('INFO usb_api_version=${_hex4(api)}');

  final (rb, boardId) = dev.boardIdRead();
  s.r('board_id_read', rb);
  s.trace('INFO board_id=$boardId name=${hackrfBoardIdName(boardId)}');

  final (rv, version) = dev.versionStringRead(255);
  s.r('version_string_read', rv);
  s.trace('INFO version=$version');

  final (rp, ps) = dev.boardPartidSerialnoRead();
  s.r('board_partid_serialno_read', rp);
  s.trace(
    'INFO part_id=${_hex8(ps!.partId[0])} ${_hex8(ps.partId[1])} '
    'serial=${_hex8(ps.serialNo[0])} ${_hex8(ps.serialNo[1])} '
    '${_hex8(ps.serialNo[2])} ${_hex8(ps.serialNo[3])}',
  );

  for (final sr in [2e6, 8e6, 20e6, 10.123456e6]) {
    s.sampleRate(dev, sr);
    final bw = hackrfComputeBasebandFilterBw(sr.truncate());
    s.trace('INFO bw_auto=$bw');
    s.r('set_baseband_filter_bandwidth', dev.setBasebandFilterBandwidth(bw));
  }

  for (final f in [100000000, 433920000, 2400000000]) {
    s.r('set_freq', dev.setFreq(f));
  }

  s.r(
    'set_freq_explicit',
    dev.setFreqExplicit(2600000000, 2500000000, rfPathFilterHighPass),
  );
  s.r(
    'set_freq_explicit_bypass',
    dev.setFreqExplicit(2450000000, 0, rfPathFilterBypass),
  );
  s.r(
    'set_freq_explicit_bad_if',
    dev.setFreqExplicit(1900000000, 2500000000, rfPathFilterLowPass),
  );
  s.r(
    'set_freq_explicit_bad_lo',
    dev.setFreqExplicit(2600000000, 80000000, rfPathFilterLowPass),
  );

  s.r('set_lna_gain(16)', dev.setLnaGain(16));
  s.r('set_vga_gain(20)', dev.setVgaGain(20));
  s.r('set_lna_gain(39)', dev.setLnaGain(39));
  s.r('set_lna_gain(41)', dev.setLnaGain(41));
  s.r('set_vga_gain(21)', dev.setVgaGain(21));
  s.r('set_vga_gain(62)', dev.setVgaGain(62));
  s.r('set_vga_gain(63)', dev.setVgaGain(63));
  s.r('set_amp_enable(1)', dev.setAmpEnable(1));
  s.r('set_amp_enable(0)', dev.setAmpEnable(0));
  s.r('set_antenna_enable(1)', dev.setAntennaEnable(1));
  s.r('set_antenna_enable(0)', dev.setAntennaEnable(0));

  s.r('is_streaming', dev.isStreaming());
  s.r('start_rx', await dev.startRx(_rxCb));
  s.r('is_streaming', dev.isStreaming());
  s.r('start_rx_again', await dev.startRx(_rxCb));
  s.r('stop_rx', await dev.stopRx());
  s.r('is_streaming', dev.isStreaming());
  s.r('stop_rx_again', await dev.stopRx());

  // SDR++ hackrf_source stop(): no hackrf_stop_rx, just hackrf_close
  s.r('start_rx', await dev.startRx(_rxCb));
  await s.doClose(dev);
  return usb.trace;
}

Future<List<String>> scenarioOldfw() async {
  final usb = RecordingUsbHandle(
    bcdDevice: 0x0100,
    currentConfig: 1,
    productId: 0x604b,
  );
  final s = _Scenario(usb);
  s.r('init', hackrfInit());
  final dev = s.doOpen();
  if (dev == null) return usb.trace;
  final (ra, api) = dev.usbApiVersionRead();
  s.r('usb_api_version_read', ra);
  s.trace('INFO usb_api_version=${_hex4(api)}');
  s.sampleRate(dev, 2e6);
  await s.doClose(dev);
  return usb.trace;
}

Future<List<String>> scenarioErrors() async {
  final usb = RecordingUsbHandle(
    bcdDevice: 0x0112,
    currentConfig: 0,
    failReq: 16,
    shortReq: 6,
  );
  final s = _Scenario(usb);
  s.r('init', hackrfInit());
  final dev = s.doOpen();
  if (dev == null) return usb.trace;

  final res = dev.setFreq(100000000);
  s.trace('RESULT set_freq=$res');
  s.trace('INFO error_name=${hackrfErrorName(res)}');

  s.sampleRate(dev, 10e6);
  s.r('set_lna_gain(8)', dev.setLnaGain(8));
  await s.doClose(dev);
  return usb.trace;
}

Future<List<String>> scenarioOpenfail() async {
  final usb = RecordingUsbHandle(
    bcdDevice: 0x0112,
    currentConfig: 0,
    failReq: 61,
  );
  final s = _Scenario(usb);
  s.r('init', hackrfInit());
  s.doOpen();
  return usb.trace;
}

Future<List<String>> scenarioRates() async {
  final usb = RecordingUsbHandle(bcdDevice: 0x0112, currentConfig: 1);
  final s = _Scenario(usb);
  const rates = <double>[
    1e6,
    2e6,
    2.048e6,
    2.4e6,
    3.2e6,
    4e6,
    5e6,
    8e6,
    10e6,
    10.123456e6,
    12.5e6,
    16e6,
    20e6,
    8e6 / 3,
    20e6 / 3,
    10e6 / 7,
    1234567.891,
    5555555.5555,
    7.777777e6,
    19999999.999,
    4410000.5,
    3e6 + 1.0 / 3,
    6e6 + 0.25,
    9e6 + 0.1,
  ];
  const bws = <int>[
    0,
    1,
    1000000,
    1749999,
    1750000,
    1750001,
    2499999,
    2500000,
    3000000,
    5500000,
    7500000,
    9000000,
    10000000,
    13999999,
    15000001,
    20000000,
    24000000,
    27999999,
    28000000,
    28000001,
    40000000,
    0xffffffff,
  ];
  s.r('init', hackrfInit());
  for (final bw in bws) {
    s.trace(
      'INFO bw($bw)=${hackrfComputeBasebandFilterBw(bw)} '
      'lt=${hackrfComputeBasebandFilterBwRoundDownLt(bw)}',
    );
  }
  final dev = s.doOpen();
  if (dev == null) return usb.trace;
  for (final sr in rates) {
    s.sampleRate(dev, sr);
  }
  for (var i = 0; i < 16; i++) {
    s.trace('INFO error_name(${-i})=${hackrfErrorName(-i)}');
  }
  for (final c in [
    1,
    -1000,
    -1001,
    -1002,
    -1003,
    -1004,
    -1005,
    -2000,
    -9999,
    42,
  ]) {
    s.trace('INFO error_name($c)=${hackrfErrorName(c)}');
  }
  for (var i = 0; i < 8; i++) {
    s.trace('INFO board_id_name($i)=${hackrfBoardIdName(i)}');
  }
  s.trace('INFO board_id_name(254)=${hackrfBoardIdName(boardIdUnrecognized)}');
  s.trace('INFO board_id_name(255)=${hackrfBoardIdName(boardIdUndetected)}');
  await s.doClose(dev);
  return usb.trace;
}

final _scenarios = <String, Future<List<String>> Function()>{
  'main': scenarioMain,
  'oldfw': scenarioOldfw,
  'errors': scenarioErrors,
  'openfail': scenarioOpenfail,
  'rates': scenarioRates,
};

const _goldenDir = 'tool/oracle/hackrf/golden';

List<String> _readGolden(String dir, String name) {
  final lines = File('$dir/$name.trace').readAsLinesSync();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

void _expectSameTrace(List<String> dart, List<String> c) {
  final n = dart.length < c.length ? dart.length : c.length;
  for (var i = 0; i < n; i++) {
    if (dart[i] != c[i]) {
      fail(
        'trace mismatch at line ${i + 1}:\n  C:    ${c[i]}\n  Dart: ${dart[i]}',
      );
    }
  }
  expect(dart.length, c.length, reason: 'trace length differs');
}

void main() {
  setUp(() => lastLibusbError = 0); // fresh process per scenario in C

  group('hackrf trace == libhackrf C oracle (golden)', () {
    for (final e in _scenarios.entries) {
      test(e.key, () async {
        final dart = await e.value();
        _expectSameTrace(dart, _readGolden(_goldenDir, e.key));
      });
    }
  });

  // Rebuilds the oracle from ~/prj/ref/hackrf and compares against a fresh
  // C run too (guards against stale goldens). Skipped without gcc/sources.
  final src =
      Platform.environment['HACKRF_SRC'] ??
      '${Platform.environment['HOME']}/prj/ref/hackrf/host/libhackrf/src';
  final canBuild =
      File('$src/hackrf.c').existsSync() &&
      Process.runSync('which', ['gcc']).exitCode == 0;
  group('hackrf trace == freshly built C oracle', () {
    late Directory tmp;
    late String exe;
    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('hackrf_oracle');
      exe = '${tmp.path}/hackrf_oracle';
      const o = 'tool/oracle/hackrf';
      final r = Process.runSync('gcc', [
        '-std=gnu11',
        '-O2',
        '-w',
        '-DLIBRARY_VERSION="oracle"',
        '-DLIBRARY_RELEASE="oracle"',
        '-I$o/fake_libusb',
        '-I$src',
        '$src/hackrf.c',
        '$o/fake_libusb/fake_libusb.c',
        '$o/hackrf_oracle.c',
        '-lpthread',
        '-o',
        exe,
      ]);
      if (r.exitCode != 0) throw StateError('gcc failed: ${r.stderr}');
    });
    tearDownAll(() => tmp.deleteSync(recursive: true));
    for (final e in _scenarios.entries) {
      test(e.key, () async {
        final r = Process.runSync(exe, [e.key, '${tmp.path}/${e.key}.trace']);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final c = _readGolden(tmp.path, e.key);
        expect(c, _readGolden(_goldenDir, e.key), reason: 'golden is stale');
        _expectSameTrace(await e.value(), c);
      });
    }
  }, skip: canBuild ? false : 'gcc or libhackrf sources not available');
}

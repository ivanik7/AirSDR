// Oracle trace-diff test: runs every scenario in tool/oracle/rtlsdr/scenarios
// through the Dart librtlsdr port (over FakeRtlUsbDevice) and compares the
// resulting USB trace line by line with the golden trace produced by the real
// C librtlsdr + fake libusb (tool/oracle/rtlsdr/build.sh).
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/drivers/rtlsdr/librtlsdr.dart';

import 'fake_rtl_usb.dart';

const oracleDir = 'tool/oracle/rtlsdr';

/// Runs [scenario] (oracle_main.c format) and returns the trace text.
Future<String> runScenario(String scenario) async {
  final trace = StringBuffer();
  FakeRtlUsbDevice? usb;
  RtlSdrDev? dev;

  for (var line in const LineSplitterLite().convert(scenario)) {
    if (line.startsWith('#') || line.trim().isEmpty) continue;
    final parts = line.trim().split(RegExp(r'\s+'));
    final cmd = parts[0];
    int arg(int i) => parts.length > i ? (int.tryParse(parts[i]) ?? 0) : 0;
    final a = arg(1), b = arg(2);

    void out(String s) => trace.writeln(s);

    switch (cmd) {
      case 'model':
        usb = FakeRtlUsbDevice(FakeModel.parse(line.substring(5)), trace);
      case 'open':
        final res = RtlSdrDev.open(usb!);
        dev = res.dev;
        out('CALL open -> ${res.r}');
      case 'close':
        final r = await dev!.close();
        dev = null;
        out('CALL close -> $r');
      case 'set_sample_rate':
        out('CALL $cmd $a -> ${dev!.setSampleRate(a)}');
      case 'get_sample_rate':
        out('CALL $cmd -> ${dev!.getSampleRate()}');
      case 'set_center_freq':
        out('CALL $cmd $a -> ${dev!.setCenterFreq(a)}');
      case 'get_center_freq':
        out('CALL $cmd -> ${dev!.getCenterFreq()}');
      case 'set_freq_correction':
        out('CALL $cmd $a -> ${dev!.setFreqCorrection(a)}');
      case 'get_freq_correction':
        out('CALL $cmd -> ${dev!.getFreqCorrection()}');
      case 'set_xtal_freq':
        out('CALL $cmd $a $b -> ${dev!.setXtalFreq(a, b)}');
      case 'get_xtal_freq':
        final x = dev!.getXtalFreq();
        out('CALL $cmd -> ${x.r} ${x.rtlFreq} ${x.tunerFreq}');
      case 'get_tuner_type':
        out('CALL $cmd -> ${dev!.getTunerType()}');
      case 'get_tuner_gains':
        final g = dev!.getTunerGains();
        out('CALL $cmd -> ${g.length}${g.map((v) => ' $v').join()}');
      case 'set_tuner_bandwidth':
        out('CALL $cmd $a -> ${dev!.setTunerBandwidth(a)}');
      case 'set_tuner_gain':
        out('CALL $cmd $a -> ${dev!.setTunerGain(a)}');
      case 'get_tuner_gain':
        out('CALL $cmd -> ${dev!.getTunerGain()}');
      case 'set_tuner_if_gain':
        out('CALL $cmd $a $b -> ${dev!.setTunerIfGain(a, b)}');
      case 'set_tuner_gain_mode':
        out('CALL $cmd $a -> ${dev!.setTunerGainMode(a)}');
      case 'set_testmode':
        out('CALL $cmd $a -> ${dev!.setTestmode(a)}');
      case 'set_agc_mode':
        out('CALL $cmd $a -> ${dev!.setAgcMode(a)}');
      case 'set_direct_sampling':
        out('CALL $cmd $a -> ${dev!.setDirectSampling(a)}');
      case 'get_direct_sampling':
        out('CALL $cmd -> ${dev!.getDirectSampling()}');
      case 'set_offset_tuning':
        out('CALL $cmd $a -> ${dev!.setOffsetTuning(a)}');
      case 'get_offset_tuning':
        out('CALL $cmd -> ${dev!.getOffsetTuning()}');
      case 'set_bias_tee':
        out('CALL $cmd $a -> ${dev!.setBiasTee(a)}');
      case 'set_bias_tee_gpio':
        out('CALL $cmd $a $b -> ${dev!.setBiasTeeGpio(a, b)}');
      case 'reset_buffer':
        out('CALL $cmd -> ${dev!.resetBuffer()}');
      case 'read_sync':
        final buf = Uint8List(a);
        final res = dev!.readSync(buf, a);
        var sum = 0;
        for (var i = 0; i < res.nRead; i++) {
          sum = (sum * 31 + buf[i]) & 0xffffffff;
        }
        out('CALL $cmd $a -> ${res.r} ${res.nRead} $sum');
      case 'read_eeprom':
        final buf = Uint8List(256);
        final r = dev!.readEeprom(buf, a & 0xff, b & 0xffff);
        final sb = StringBuffer('CALL $cmd $a $b -> $r');
        for (var i = 0; i < b && i < 256; i++) {
          sb.write(' ${buf[i].toRadixString(16).padLeft(2, '0')}');
        }
        out(sb.toString());
      case 'write_eeprom':
        final buf = Uint8List(256);
        for (var i = 0; i < 256; i++) {
          buf[i] = (i * 5 + 1) & 0xff;
        }
        out('CALL $cmd $a $b -> ${dev!.writeEeprom(buf, a & 0xff, b & 0xffff)}');
      case 'get_usb_strings':
        final s = dev!.getUsbStrings();
        out('CALL $cmd -> ${s.r} [${s.manufact}] [${s.product}] [${s.serial}]');
      default:
        throw ArgumentError('unknown scenario command: $cmd');
    }
  }
  return trace.toString();
}

class LineSplitterLite {
  const LineSplitterLite();
  List<String> convert(String s) => s.replaceAll('\r', '').split('\n');
}

void main() {
  rtlsdrLog = (_) {}; // silence driver diagnostics

  final scenarios = Directory('$oracleDir/scenarios')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.txt'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('oracle scenarios exist', () {
    expect(scenarios, isNotEmpty);
  });

  for (final f in scenarios) {
    final name = f.uri.pathSegments.last.replaceAll('.txt', '');
    test('trace matches C librtlsdr: $name', () async {
      final golden = File('$oracleDir/golden/$name.trace').readAsLinesSync();
      final actual = const LineSplitterLite()
          .convert(await runScenario(f.readAsStringSync()));
      if (actual.isNotEmpty && actual.last.isEmpty) actual.removeLast();

      final n = golden.length < actual.length ? golden.length : actual.length;
      for (var i = 0; i < n; i++) {
        if (golden[i] != actual[i]) {
          final from = i - 5 < 0 ? 0 : i - 5;
          fail('first difference at line ${i + 1}\n'
              '  C   : ${golden[i]}\n'
              '  Dart: ${actual[i]}\n'
              'context (C):\n  ${golden.sublist(from, i + 1).join('\n  ')}');
        }
      }
      expect(actual.length, golden.length, reason: 'trace length differs');
      // sanity: the traces are not trivially empty
      expect(golden.where((l) => l.startsWith('CTRL ')).length,
          greaterThan(100));
    });
  }
}

// Oracle trace-diff test: runs every scenario in tool/oracle/rtlsdr/scenarios
// through the Dart librtlsdr port (over FakeRtlUsbDevice) and compares the
// resulting USB trace line by line with the golden trace produced by the real
// C librtlsdr + fake libusb (tool/oracle/rtlsdr/build.sh).
//
// Probe-only scenarios (tool/oracle/rtlsdr/scenarios_probe, tuners whose
// driver is not ported) are compared up to and including the tuner ID read.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/drivers/rtlsdr/librtlsdr.dart';

import 'oracle_runner.dart';

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

  final probeScenarios = Directory('$oracleDir/scenarios_probe')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.txt'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final f in probeScenarios) {
    final name = f.uri.pathSegments.last.replaceAll('.txt', '');
    test('probe/open prefix matches C librtlsdr: $name', () async {
      final golden = File('$oracleDir/golden/$name.trace').readAsLinesSync();
      final actual = const LineSplitterLite()
          .convert(await runScenario(f.readAsStringSync()));
      final openIdx = actual.indexOf('CALL open -> 0');
      expect(openIdx, greaterThan(4));
      // Dart open() = C open() without tuner->init(): everything before the
      // final "I2C repeater off" (demod write + dummy read) must be a prefix
      // of the C trace.
      final prefix = actual.sublist(0, openIdx - 2);
      expect(golden.sublist(0, prefix.length), prefix);
      // and the tuner type / gain table reported afterwards are the same
      for (final call in ['CALL get_tuner_type', 'CALL get_tuner_gains']) {
        expect(actual.firstWhere((l) => l.startsWith(call)),
            golden.firstWhere((l) => l.startsWith(call)));
      }
    });
  }
}

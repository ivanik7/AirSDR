// Test helpers for the source module tests.
//
//  * [rtlMockHandle]: lib/usb/mock_transport.dart MockUsbDeviceHandle whose
//    control transfers are answered by the RTL2832U + tuner register model of
//    test/drivers/rtlsdr/fake_rtl_usb.dart (the Dart twin of the C oracle's
//    fake libusb), so the mock trace can be compared with the oracle goldens.
//  * [hackrfMockHandle]: MockUsbDeviceHandle answering HackRF vendor requests
//    like tool/oracle/hackrf/fake_libusb.
//  * [goldenCtrlAsMock]: converts oracle trace lines to the mock trace format.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:sdr_flutter/sdrpp/signal_path/source_handler.dart';
import 'package:sdr_flutter/usb/mock_transport.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

import '../../../drivers/rtlsdr/fake_rtl_usb.dart';

const sourcesOracleDir = 'tool/oracle/sources';

class FakeCore implements SourceCore {
  final List<double> rates = [];
  @override
  void setInputSampleRate(double sampleRate) => rates.add(sampleRate);
}

/// Collects everything a source pushes into its sink (copied: the buffer is
/// only valid during the call).
class SinkRecorder {
  final List<Float32List> blocks = [];
  final List<int> counts = [];
  void call(Float32List iq, int count) {
    counts.add(count);
    blocks.add(Float32List.fromList(iq.sublist(0, 2 * count)));
  }

  int get totalSamples => counts.fold(0, (a, b) => a + b);
}

MockUsbDeviceHandle rtlMockHandle(
  FakeRtlUsbDevice model, {
  Map<int, String>? strings,
}) {
  final d = model.deviceDescriptor;
  return MockUsbDeviceHandle(
    deviceDescriptor: d,
    strings:
        strings ??
        {
          d.iManufacturer: model.model.manufact,
          d.iProduct: model.model.product,
          d.iSerialNumber: model.model.serial,
        },
    onControlIn: (req, resp) => model.controlTransfer(
      req.requestType,
      req.request,
      req.value,
      req.index,
      resp,
      req.length,
    ),
    onControlOut: (req) => model.controlTransfer(
      req.requestType,
      req.request,
      req.value,
      req.index,
      Uint8List.fromList(req.outData),
      req.length,
    ),
  );
}

/// HackRF One with API 0x0112 (fake_libusb.c fake_script_in()).
MockUsbDeviceHandle hackrfMockHandle({int currentConfig = 1}) {
  var config = currentConfig;
  late MockUsbDeviceHandle h;
  h = MockUsbDeviceHandle(
    deviceDescriptor: const UsbDeviceDescriptor(
      vendorId: 0x1d50,
      productId: 0x6089,
      bcdDevice: 0x0112,
      iManufacturer: 1,
      iProduct: 2,
      iSerialNumber: 3,
    ),
    onControlIn: (req, resp) {
      if (req.requestType == 0x80 && req.request == 0x08) {
        resp[0] = config;
        return 1;
      }
      switch (req.request) {
        case 19: // SET_LNA_GAIN: always accepted
          resp[0] = 1;
          return 1;
        case 20: // SET_VGA_GAIN: 62 "rejected" (retval 0), as fake_libusb.c
          resp[0] = req.index == 62 ? 0 : 1;
          return 1;
        case 61: // GET_BUFFER_SIZE 32768
          resp.setAll(0, [0x00, 0x80, 0x00, 0x00]);
          return 4;
      }
      throw UsbException(UsbError.pipe, 'unscripted IN ${req.request}');
    },
  );
  return h;
}

/// Oracle trace lines -> MockUsbDeviceHandle trace lines (control only):
///   RTL   : CTRL rt=40 req=00 val=2000 idx=0110 len=1 to=300 ret=1 data=09
///   HackRF: CTRL 40 07 b3f0 001a len=0 to=100 ret=0 data=
///   Mock  : C 40 00 2000 0110 0001 09
List<String> goldenCtrlAsMock(List<String> golden) {
  final rtl = RegExp(
    r'^CTRL rt=(\w\w) req=(\w\w) val=(\w{4}) idx=(\w{4}) len=(\d+) to=\d+ ret=(-?\d+) data=(\w*)$',
  );
  final hrf = RegExp(
    r'^CTRL (\w\w) (\w\w) (\w{4}) (\w{4}) len=(\d+) to=\d+ ret=(-?\d+) data=(\w*)$',
  );
  final out = <String>[];
  for (final l in golden) {
    final m = rtl.firstMatch(l) ?? hrf.firstMatch(l);
    if (m == null) continue;
    // failed IN transfers are not recorded by MockUsbDeviceHandle (the
    // handler throws before the trace entry is added)
    if ((int.parse(m[1]!, radix: 16) & 0x80) != 0 && int.parse(m[6]!) < 0) {
      continue;
    }
    final len = int.parse(m[5]!).toRadixString(16).padLeft(4, '0');
    final data = m[7]!.isEmpty ? '' : ' ${m[7]}';
    out.add('C ${m[1]} ${m[2]} ${m[3]} ${m[4]} $len$data');
  }
  return out;
}

List<String> readGolden(String name) =>
    File('$sourcesOracleDir/golden/$name.trace').readAsLinesSync();

/// Fails with context at the first differing line.
void expectSameLines(List<String> actual, List<String> golden) {
  final n = actual.length < golden.length ? actual.length : golden.length;
  for (var i = 0; i < n; i++) {
    if (actual[i] != golden[i]) {
      final from = i - 5 < 0 ? 0 : i - 5;
      throw StateError(
        'first difference at line ${i + 1}\n'
        '  C   : ${golden[i]}\n'
        '  Dart: ${actual[i]}\n'
        'context (C):\n  ${golden.sublist(from, i + 1).join('\n  ')}',
      );
    }
  }
  if (actual.length != golden.length) {
    throw StateError(
      'trace length differs: Dart ${actual.length} vs C ${golden.length}\n'
      'extra: ${(actual.length > golden.length ? actual.sublist(n) : golden.sublist(n)).take(5).join('\n')}',
    );
  }
}

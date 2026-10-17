// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real-hardware SSTV session check on the production Dart path: the real
// FFI library, an attached RTL-SDR and DecoderSession exactly as the
// Decoder tab drives it. Verifies that the native backend accepts the v1
// settings the UI sends ({mode: auto, underlying}), that choosing an
// underlying demod switches the one receiver through the normal mode
// control and reattaches, that WFM reports "not ready", and that a retune
// keeps the decoder attached. It reports (does not require) image events:
// live-air SSTV depends on band activity.
//
// Run (skipped otherwise):
//   SDR_HW_TEST=1 SDRCORE_V3_PROBE_LIBRARY=<build>/libsdrcore.so \
//     flutter test test/native/sstv_session_hw_test.dart
// SDR_HW_SSTV_HZ (default 14230000) and SDR_HW_SSTV_LISTEN_S (default 20).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_decoder_api.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/native_radio_controller.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/ui/decoders/decoder_session.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

void main() {
  final library = Platform.environment['SDRCORE_V3_PROBE_LIBRARY'];
  final hw = Platform.environment['SDR_HW_TEST'] == '1';
  test(
    'SSTV selection on a running RTL session attaches with the UI settings',
    () async {
      final hz =
          int.tryParse(Platform.environment['SDR_HW_SSTV_HZ'] ?? '') ??
          14230000;
      final listen =
          int.tryParse(Platform.environment['SDR_HW_SSTV_LISTEN_S'] ?? '') ??
          20;
      final dir = await Directory.systemTemp.createTemp('sstv_hw');
      final lib = openSdrCoreLibrary(library);
      final api = FfiNativeRadioApi(lib);
      final radio = NativeRadioController(
        api: api,
        decoderApi: FfiNativeDecoderApi.tryOpen(lib),
        source: HostNativeDeviceSource(api),
        configDir: dir.path,
      );
      DecoderSession? session;
      try {
        for (var i = 0; i < 200 && !radio.running; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(radio.running, isTrue, reason: '${radio.lastError}');
        radio.setMode(DemodMode.usb);
        radio.setTuning(centerFrequency: hz.toDouble(), vfoOffset: 0);
        await Future<void>.delayed(const Duration(milliseconds: 500));

        session = DecoderSession(radio);
        expect(session.isAvailable('sstv'), isTrue);
        session.selectPreview('sstv');
        expect(session.failureReason, isNull);
        expect(session.active, isTrue);
        expect(session.currentSettings, {'mode': 'auto', 'underlying': 'usb'});

        session.setSetting('sstv', 'underlying', 'lsb');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(radio.mode, DemodMode.lsb);
        expect(session.active, isTrue, reason: '${session.failureReason}');

        radio.setMode(DemodMode.wfm);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(session.active, isFalse);
        expect(session.failureReason, contains('Not ready'));

        session.setSetting('sstv', 'underlying', 'usb');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(radio.mode, DemodMode.usb);
        expect(session.active, isTrue);

        radio.setTuning(centerFrequency: hz + 1000.0, vfoOffset: 0);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        radio.setTuning(centerFrequency: hz.toDouble(), vfoOffset: 0);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(session.active, isTrue, reason: 'retune keeps it attached');

        await Future<void>.delayed(Duration(seconds: listen));
        final sstv = session.sstv;
        // ignore: avoid_print
        print(
          'sstv hw: ${hz}Hz USB ${listen}s, current='
          '${sstv.current?.mode ?? '-'} rows=${sstv.current?.receivedLines ?? 0}'
          ' gallery=${sstv.gallery.length} dropped=${session.droppedEvents} '
          'issue=${sstv.lastIssue ?? '-'}',
        );
        expect(session.active, isTrue);
      } finally {
        session?.dispose();
        await radio.stop();
        radio.dispose();
        await dir.delete(recursive: true);
      }
    },
    skip: hw && library != null
        ? false
        : 'set SDR_HW_TEST=1 and SDRCORE_V3_PROBE_LIBRARY',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

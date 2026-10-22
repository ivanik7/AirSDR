// SPDX-License-Identifier: GPL-3.0-or-later
// Run with xvfb and interact with the actual GTK system folder chooser.
// SDR_RECORD_QA_FOLDER must be an existing writable directory.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/native_record_api.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/platform/record_folder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'GTK folder chooser writes generated IQ through native recorder',
    (tester) async {
      if (!Platform.isLinux) return;
      final expected = Platform.environment['SDR_RECORD_QA_FOLDER'];
      expect(expected, isNotNull);
      final folder = await RecordFolderStore().choose();
      expect(folder, isNotNull);
      expect(folder!.locator, 'file:$expected');
      expect(await RecordFolderStore().isAccessible(), isTrue);
      expect((await RecordFolderStore().load())!.locator, folder.locator);

      final radio = FfiNativeRadioApi.open();
      final recorder = FfiNativeRecordApi.tryOpen(openSdrCoreLibrary())!;
      final handle = radio.create();
      try {
        radio.openSynthetic(handle, 300000);
        radio.controls(
          handle,
          const NativeControls(
            centerHz: 100000000,
            offsetHz: 0,
            sampleRate: 300000,
            mode: 1,
            bandwidthHz: 150000,
            gainTenthsDb: 0,
            agc: false,
            squelch: 0,
            squelchLevelDb: -50,
            autoOffsetDb: 0,
            volume: 0,
            muted: true,
          ),
        );
        radio.audioSink(handle, 'null');
        radio.start(handle);
        final config = SdrRecordConfig(
          streams: SdrRecordStream.iq,
          audioFormat: SdrRecordFormat.none,
          startUnixMs: DateTime.now().millisecondsSinceEpoch,
          utcOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
        );
        expect(
          recorder.start(handle, config, folder.locator, []),
          SdrResult.ok,
        );
        for (var attempt = 0; attempt < 40; attempt++) {
          if (recorder.status(handle).iqSamplesWritten > 0) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(recorder.status(handle).state, SdrRecordState.active);
        expect(recorder.status(handle).iqSamplesWritten, greaterThan(0));
        expect(recorder.stop(handle), SdrResult.ok);
        final stopped = recorder.status(handle);
        expect(stopped.state, SdrRecordState.idle);
        expect(stopped.filesCreated, 2);
        expect(stopped.bytesWritten, greaterThan(100));
        expect(radio.snapshot(handle).state, SdrState.running);
        radio.stop(handle);
      } finally {
        radio.close(handle);
        radio.destroy(handle);
      }
    },
  );
}

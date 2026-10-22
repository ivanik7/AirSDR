// SPDX-License-Identifier: GPL-3.0-or-later
// Run on an Android emulator only. The first run chooses a SAF tree; rerun the
// installed instrumentation without reinstalling the APK after force-stop to
// prove that both the grant and the native writer survive a cold process start.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/native_record_api.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/platform/record_folder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('saved SAF grant writes IQ across cold process starts', (
    tester,
  ) async {
    if (!Platform.isAndroid) return;
    final store = RecordFolderStore();
    final previous = await store.load();
    final hadGrant = previous != null && await store.isAccessible();
    final folder = hadGrant ? previous : await store.choose();
    expect(folder, isNotNull, reason: 'Choose Documents on the first run');
    expect(await store.isAccessible(), isTrue);

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
      expect(recorder.start(handle, config, folder!.locator, []), SdrResult.ok);
      for (var attempt = 0; attempt < 40; attempt++) {
        if (recorder.status(handle).iqSamplesWritten > 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final live = recorder.status(handle);
      expect(live.state, SdrRecordState.active);
      expect(live.iqSamplesWritten, greaterThan(0));
      expect(recorder.stop(handle), SdrResult.ok);
      final stopped = recorder.status(handle);
      expect(stopped.state, SdrRecordState.idle);
      expect(stopped.filesCreated, 2);
      expect(stopped.bytesWritten, greaterThan(100));
      expect(radio.snapshot(handle).state, SdrState.running);
      radio.stop(handle);
      // ignore: avoid_print
      print(
        'SAF cold-run previous=$hadGrant files=${stopped.filesCreated} '
        'bytes=${stopped.bytesWritten} iq=${stopped.iqSamplesWritten}',
      );
    } finally {
      radio.close(handle);
      radio.destroy(handle);
    }
    expect((await RecordFolderStore().load())?.locator, folder.locator);
  });
}

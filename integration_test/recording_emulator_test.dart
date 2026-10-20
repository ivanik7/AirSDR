// SPDX-License-Identifier: GPL-3.0-or-later
// Run on the API 35 emulator only; select Documents in the system tree picker.
// Synthetic IQ is produced by the native core, never by a live receiver.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/native_record_api.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/platform/record_folder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native synthetic IQ, all audio codecs and RDS log reach SAF', (
    tester,
  ) async {
    if (!Platform.isAndroid) return;
    final folderStore = RecordFolderStore();
    // ignore: avoid_print
    print('SAF saved folder: ${(await folderStore.load())?.displayName}');
    final accessible = await folderStore.isAccessible();
    // ignore: avoid_print
    print('SAF saved folder accessible: $accessible');
    final selected = accessible
        ? await folderStore.load()
        : await folderStore.choose();
    expect(selected, isNotNull, reason: 'Choose Documents in the SAF picker');
    expect(await folderStore.isAccessible(), isTrue);
    final locator = selected!.locator;
    final radio = FfiNativeRadioApi.open();
    final library = openSdrCoreLibrary();
    final recorder = FfiNativeRecordApi.tryOpen(library)!;
    expect(recorder.capabilities().streams, 15);
    expect(recorder.capabilities().formats, 30);
    final setRbds = library
        .lookupFunction<
          Int32 Function(Pointer<SdrHandle>, Int32),
          int Function(Pointer<SdrHandle>, int)
        >('sdr_rds_set_rbds');
    final handle = radio.create();
    try {
      radio.openSynthetic(handle, 300000);
      radio.controls(
        handle,
        const NativeControls(
          centerHz: 100000000,
          offsetHz: 0,
          sampleRate: 300000,
          mode: 1, // WFM stereo; source produces generated IQ.
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
      radio.stereo(handle, true);
      radio.audioSink(handle, 'null');
      radio.start(handle);
      for (final format in [
        SdrRecordFormat.wav,
        SdrRecordFormat.flac,
        SdrRecordFormat.mp3,
        SdrRecordFormat.opus,
      ]) {
        final config = SdrRecordConfig(
          streams:
              SdrRecordStream.iq |
              SdrRecordStream.audio |
              SdrRecordStream.squelchAudio |
              SdrRecordStream.decoderLog,
          audioFormat: format,
          audioBitrateKbps: format == SdrRecordFormat.mp3
              ? 128
              : format == SdrRecordFormat.opus
              ? 96
              : 0,
          startUnixMs: DateTime.now().millisecondsSinceEpoch,
          utcOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
        );
        expect(recorder.start(handle, config, locator, ['rds']), SdrResult.ok);
        expect(
          setRbds(handle, format.isOdd ? 1 : 0),
          SdrResult.ok,
        ); // A real native RDS reset event.
        for (var attempt = 0; attempt < 40; attempt++) {
          if (recorder.status(handle).iqSamplesWritten > 0 &&
              recorder.status(handle).audioFramesWritten > 0) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        final live = recorder.status(handle);
        // ignore: avoid_print
        print(
          'SAF live format=$format state=${live.state} error=${live.lastError} '
          'iq=${live.iqSamplesWritten} audio=${live.audioFramesWritten} '
          'logs=${live.logEventsWritten} source=${radio.snapshot(handle).source} '
          'input=${radio.snapshot(handle).inputSamples} '
          'processed=${radio.snapshot(handle).processedSamples}',
        );
        expect(live.state, SdrRecordState.active);
        expect(live.iqSamplesWritten, greaterThan(0));
        expect(live.audioFramesWritten, greaterThan(0));
        expect(live.audioChannels, 2);
        expect(live.audioSampleRate, 48000);
        expect(live.logEventsWritten, greaterThan(0));
        expect(recorder.stop(handle), SdrResult.ok);
        final stopped = recorder.status(handle);
        expect(stopped.state, SdrRecordState.idle);
        expect(stopped.stopReason, 1);
        expect(stopped.lastError, SdrResult.ok);
        expect(stopped.filesCreated, greaterThanOrEqualTo(5));
        expect(stopped.segmentsCompleted, greaterThan(0));
        expect(stopped.bytesWritten, greaterThan(100));
        // Printed counters let the host correlate SAF files and final lengths.
        // ignore: avoid_print
        print(
          'SAF format=$format files=${stopped.filesCreated} '
          'bytes=${stopped.bytesWritten} iq=${stopped.iqSamplesWritten} '
          'audio=${stopped.audioFramesWritten} logs=${stopped.logEventsWritten}',
        );
      }
      expect(radio.snapshot(handle).state, SdrState.running);
      await AndroidRecordFolderPlatform().release(locator);
      expect(await folderStore.isAccessible(), isFalse);
      expect((await folderStore.load())?.locator, locator);
      final revoked = SdrRecordConfig(
        streams: SdrRecordStream.iq,
        audioFormat: SdrRecordFormat.none,
        startUnixMs: DateTime.now().millisecondsSinceEpoch,
        utcOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
      );
      expect(recorder.start(handle, revoked, locator, []), SdrResult.ok);
      for (var attempt = 0; attempt < 40; attempt++) {
        if (recorder.status(handle).state == SdrRecordState.failed) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final failure = recorder.status(handle);
      expect(failure.state, SdrRecordState.failed);
      expect(failure.lastError, SdrRecordError.folderUnavailable);
      expect(failure.errorStream, SdrRecordStream.iq);
      expect(radio.snapshot(handle).state, SdrState.running);
      expect(recorder.stop(handle), SdrResult.ok);
      radio.stop(handle);
    } finally {
      radio.close(handle);
      radio.destroy(handle);
    }
    // The persisted grant must survive a new process; a separate cold launch
    // verifies access without releasing it here.
    expect((await RecordFolderStore().load())?.locator, locator);
  });
}

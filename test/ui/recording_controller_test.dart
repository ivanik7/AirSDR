// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/native/native_record_api.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/platform/record_folder.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/recording/recording_controller.dart';

class _Folder implements RecordFolderPlatform {
  bool writable = true;
  @override
  Future<RecordFolder?> choose() async =>
      const RecordFolder('file:/records', 'records');
  @override
  Future<bool> validate(String locator) async => writable;
}

SdrRecordStatus status(
  int state, {
  int elapsed = 0,
  int bytes = 0,
  int error = 0,
}) => SdrRecordStatus(
  state: state,
  stopReason: 0,
  lastError: error,
  errorStream: SdrRecordStream.audio,
  streams: SdrRecordStream.audio,
  audioFormat: SdrRecordFormat.wav,
  audioSampleRate: 48000,
  audioChannels: 1,
  squelchSegmentOpen: 0,
  sessionId: 1,
  elapsedMs: elapsed,
  bytesWritten: bytes,
  filesCreated: 1,
  segmentsCompleted: 0,
  iqSamplesWritten: 0,
  audioFramesWritten: 0,
  iqDroppedSamples: 0,
  audioDroppedFrames: 0,
  logEventsWritten: 0,
  logDroppedEvents: 0,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'stream combinations and bitrate choices persist; invalid fields fall back',
    () async {
      final prefs = RecordingPreferences();
      final choice = RecordChoices(
        streams: SdrRecordStream.iq | SdrRecordStream.squelchAudio,
        logIds: {'rds', 'rtl_433'},
        format: SdrRecordFormat.opus,
        mp3Bitrate: 192,
        opusBitrate: 64,
      );
      await prefs.save(choice);
      expect(await prefs.load(), choice);
      final raw = await SharedPreferences.getInstance();
      await raw.setInt('recording.format', 99);
      expect((await prefs.load()).format, SdrRecordFormat.wav);
      await raw.setInt('recording.format', SdrRecordFormat.mp3);
      await raw.setInt('recording.mp3Bitrate', 33);
      await raw.setInt('recording.opusBitrate', 7);
      expect((await prefs.load()).mp3Bitrate, 128);
      expect((await prefs.load()).opusBitrate, 96);
    },
  );

  test(
    'validation routes to precise settings and never calls native on failure',
    () async {
      final radio = DemoRadioController();
      final folder = _Folder();
      final store = RecordFolderStore(platform: folder);
      var starts = 0;
      final recording = RecordingController(
        radio: radio,
        folderStore: store,
        capabilities: const SdrRecordCapabilities(15, 30),
        availableLogIds: () => {'rds', 'rtl_433'},
        startNative: (config, locator, logs) async {
          starts++;
          return SdrResult.ok;
        },
        stopNative: () async => SdrResult.ok,
        readStatus: () => status(SdrRecordState.idle),
      );
      await recording.load();
      await recording.toggle();
      expect(recording.settingsTarget, RecordingSettingsTarget.folder);
      expect(starts, 0);
      await store.choose();
      await recording.toggle();
      expect(recording.settingsTarget, RecordingSettingsTarget.streams);
      expect(starts, 0);
      await recording.saveChoices(
        const RecordChoices(streams: SdrRecordStream.iq, logIds: {}),
      );
      folder.writable = false;
      await recording.toggle();
      expect(recording.settingsTarget, RecordingSettingsTarget.folder);
      expect(recording.error, contains('not accessible'));
      expect(starts, 0);
      radio.dispose();
      recording.dispose();
    },
  );

  test(
    'latches format and filters unavailable decoder logs; failure and recovery',
    () async {
      final radio = DemoRadioController();
      await radio.start();
      final store = RecordFolderStore(platform: _Folder());
      await store.choose();
      SdrRecordStatus current = status(SdrRecordState.idle);
      SdrRecordConfig? started;
      List<String>? ids;
      var starts = 0;
      final recording = RecordingController(
        radio: radio,
        folderStore: store,
        capabilities: const SdrRecordCapabilities(15, 30),
        availableLogIds: () => {'rds'},
        startNative: (config, locator, logs) async {
          started = config;
          ids = logs;
          starts++;
          current = status(SdrRecordState.active);
          return SdrResult.ok;
        },
        stopNative: () async {
          current = status(SdrRecordState.idle);
          return SdrResult.ok;
        },
        readStatus: () => current,
      );
      await recording.load();
      await recording.saveChoices(
        const RecordChoices(
          streams: SdrRecordStream.audio | SdrRecordStream.decoderLog,
          logIds: {'rds', 'missing'},
          format: SdrRecordFormat.mp3,
          mp3Bitrate: 192,
        ),
      );
      await recording.toggle();
      expect(starts, 1);
      expect(started!.audioFormat, SdrRecordFormat.mp3);
      expect(started!.audioBitrateKbps, 192);
      expect(ids, ['rds']);
      await recording.saveChoices(
        recording.choices.copyWith(format: SdrRecordFormat.opus),
      );
      expect(started!.audioFormat, SdrRecordFormat.mp3);
      current = status(SdrRecordState.failed, error: SdrRecordError.noSpace);
      recording.refresh();
      expect(recording.active, false);
      expect(recording.error, contains('space'));
      expect(radio.running, true);
      await recording.toggle();
      expect(starts, 2);
      expect(started!.audioFormat, SdrRecordFormat.opus);
      recording.dispose();
      radio.dispose();
    },
  );

  test('elapsed and byte units use bounded, cumulative status', () {
    expect(formatRecordingElapsed(59999), '00:59');
    expect(formatRecordingElapsed(3600000), '1:00:00');
    expect(formatRecordingBytes(0), '0 B');
    expect(formatRecordingBytes(1024), '1.0 KB');
    expect(formatRecordingBytes(1048576), '1.0 MB');
    expect(formatRecordingBytes(1073741824), '1.0 GB');
  });
}

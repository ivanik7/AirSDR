// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/native/native_record_api.dart';
import 'package:sdr_flutter/native/sdr_core.dart';
import 'package:sdr_flutter/platform/record_folder.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/recording/recording_controller.dart';

class _Folder implements RecordFolderPlatform {
  @override
  Future<RecordFolder?> choose() async =>
      const RecordFolder('file:/records', 'records');
  @override
  Future<bool> validate(String locator) async => true;
}

SdrRecordStatus _status(
  int state, {
  int elapsed = 0,
  int bytes = 0,
  int error = 0,
}) => SdrRecordStatus(
  state: state,
  stopReason: 0,
  lastError: error,
  errorStream: SdrRecordStream.iq,
  streams: SdrRecordStream.iq,
  audioFormat: 0,
  audioSampleRate: 0,
  audioChannels: 0,
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

  testWidgets(
    'Record navigates to folder, then What to record; controls and status fit 344x690',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(344, 690);
      addTearDown(tester.view.reset);
      final radio = DemoRadioController();
      await radio.start();
      var current = _status(SdrRecordState.idle);
      SdrRecordConfig? config;
      final recording = RecordingController(
        radio: radio,
        folderStore: RecordFolderStore(platform: _Folder()),
        capabilities: const SdrRecordCapabilities(15, 30),
        availableLogIds: () => {'rds', 'rtl_433'},
        startNative: (selection, folder, logs) async {
          config = selection;
          current = _status(SdrRecordState.active, elapsed: 62000, bytes: 2048);
          return SdrResult.ok;
        },
        stopNative: () async {
          current = _status(SdrRecordState.idle);
          return SdrResult.ok;
        },
        readStatus: () => current,
      );
      await recording.load();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: const ValueKey('recordingScreenshot'),
            child: LegacyAppShell(controller: radio, recording: recording),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('recordToggle')), findsOneWidget);
      expect(find.byKey(const ValueKey('legacyMute')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('recordToggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recordFolder')), findsOneWidget);
      expect(find.text('Not set'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recordFolder')));
      await tester.pump();
      expect(find.text('records'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tab-0')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('recordToggle')));
      await tester.pumpAndSettle();
      expect(find.text('What to record'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('recordStream-1')));
      await tester.tap(find.byKey(const ValueKey('recordStream-2')));
      await tester.tap(find.byKey(const ValueKey('recordLog-rds')));
      await tester.tap(find.byKey(const ValueKey('recordChoicesApply')));
      await tester.pumpAndSettle();
      expect(recording.choices.streams, 11);
      expect(recording.choices.logIds, {'rds'});
      await tester.tap(find.byKey(const ValueKey('tab-0')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('recordToggle')));
      await tester.pump();
      expect(config?.streams, 11);
      expect(find.textContaining('REC 01:02 · 2.0 KB'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const ValueKey('recordToggle'))).right,
        lessThanOrEqualTo(344),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('key-OK'))).bottom,
        lessThanOrEqualTo(690 - 64),
      );
      final screenshot = Platform.environment['SDR_UI_SCREENSHOT'];
      if (screenshot != null) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('recordingScreenshot')),
          );
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(screenshot).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      current = _status(SdrRecordState.failed, error: SdrRecordError.noSpace);
      recording.refresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('no space left'), findsOneWidget);
      expect(radio.running, true);
      await radio.stop();
      await tester.pump();
      expect(find.text('reception stopped'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      recording.dispose();
      radio.dispose();
    },
  );

  testWidgets(
    'audio formats and bitrates persist while active without changing current session',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(344, 690);
      addTearDown(tester.view.reset);
      final radio = DemoRadioController();
      await radio.start();
      final store = RecordFolderStore(platform: _Folder());
      await store.choose();
      var current = _status(SdrRecordState.idle);
      SdrRecordConfig? config;
      final recording = RecordingController(
        radio: radio,
        folderStore: store,
        capabilities: const SdrRecordCapabilities(15, 30),
        availableLogIds: () => {'rds'},
        startNative: (selection, folder, logs) async {
          config = selection;
          current = _status(SdrRecordState.active);
          return SdrResult.ok;
        },
        stopNative: () async {
          current = _status(SdrRecordState.idle);
          return SdrResult.ok;
        },
        readStatus: () => current,
      );
      await recording.load();
      await recording.saveChoices(
        const RecordChoices(streams: SdrRecordStream.audio),
      );
      await recording.toggle();
      expect(config!.audioFormat, SdrRecordFormat.wav);
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(controller: radio, recording: recording),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('recordFormat')));
      await tester.tap(find.byKey(const ValueKey('recordFormat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MP3').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recordBitrate')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('192 kbps').last);
      await tester.pumpAndSettle();
      expect(config!.audioFormat, SdrRecordFormat.wav);
      expect((await RecordingPreferences().load()).mp3Bitrate, 192);
      await recording.toggle();
      await recording.toggle();
      expect(config!.audioFormat, SdrRecordFormat.mp3);
      expect(config!.audioBitrateKbps, 192);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      recording.dispose();
      radio.dispose();
    },
  );
}

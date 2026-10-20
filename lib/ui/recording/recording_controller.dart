// SPDX-License-Identifier: GPL-3.0-or-later
// Low-rate recording controls; IQ, PCM, codecs and file writes stay native.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../native/native_radio_controller.dart';
import '../../native/native_record_api.dart';
import '../../native/sdr_core.dart';
import '../../platform/record_folder.dart';
import '../radio_controller.dart';

const recordingLogIds = <String>{
  'rds',
  'rtl_433',
  'adsb',
  'sstv',
  'dmr',
  'meshtastic',
  'meshcore',
};

const recordingMp3Bitrates = <int>[
  32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
];
const recordingOpusBitrates = <int>[24, 32, 48, 64, 96, 128, 160, 192, 256];

class RecordChoices {
  const RecordChoices({
    this.streams = 0,
    this.logIds = const {},
    this.format = SdrRecordFormat.wav,
    this.mp3Bitrate = 128,
    this.opusBitrate = 96,
  });
  final int streams, format, mp3Bitrate, opusBitrate;
  final Set<String> logIds;

  RecordChoices copyWith({
    int? streams,
    Set<String>? logIds,
    int? format,
    int? mp3Bitrate,
    int? opusBitrate,
  }) => RecordChoices(
    streams: streams ?? this.streams,
    logIds: logIds ?? this.logIds,
    format: format ?? this.format,
    mp3Bitrate: mp3Bitrate ?? this.mp3Bitrate,
    opusBitrate: opusBitrate ?? this.opusBitrate,
  );

  @override
  bool operator ==(Object other) =>
      other is RecordChoices &&
      other.streams == streams &&
      other.format == format &&
      other.mp3Bitrate == mp3Bitrate &&
      other.opusBitrate == opusBitrate &&
      setEquals(other.logIds, logIds);
  @override
  int get hashCode => Object.hash(
    streams,
    format,
    mp3Bitrate,
    opusBitrate,
    Object.hashAll((logIds.toList()..sort())),
  );
}

class RecordingPreferences {
  Future<RecordChoices> load() async {
    final prefs = await SharedPreferences.getInstance();
    final streams = prefs.getInt('recording.streams') ?? 0;
    final format = prefs.getInt('recording.format') ?? SdrRecordFormat.wav;
    final mp3 = prefs.getInt('recording.mp3Bitrate') ?? 128;
    final opus = prefs.getInt('recording.opusBitrate') ?? 96;
    return RecordChoices(
      streams: streams & 15,
      logIds: (prefs.getStringList('recording.logIds') ?? const <String>[])
          .where(recordingLogIds.contains)
          .toSet(),
      format: format >= SdrRecordFormat.wav && format <= SdrRecordFormat.opus
          ? format
          : SdrRecordFormat.wav,
      mp3Bitrate: recordingMp3Bitrates.contains(mp3) ? mp3 : 128,
      opusBitrate: recordingOpusBitrates.contains(opus) ? opus : 96,
    );
  }

  Future<void> save(RecordChoices choice) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('recording.streams', choice.streams);
    await prefs.setStringList(
      'recording.logIds',
      choice.logIds.toList()..sort(),
    );
    await prefs.setInt('recording.format', choice.format);
    await prefs.setInt('recording.mp3Bitrate', choice.mp3Bitrate);
    await prefs.setInt('recording.opusBitrate', choice.opusBitrate);
  }
}

enum RecordingSettingsTarget { folder, streams, format }

String formatRecordingElapsed(int ms) {
  final seconds = ms < 0 ? 0 : ms ~/ 1000;
  final minutes = seconds ~/ 60;
  final tail = '${seconds % 60}'.padLeft(2, '0');
  return minutes >= 60
      ? '${minutes ~/ 60}:${'${minutes % 60}'.padLeft(2, '0')}:$tail'
      : '${'$minutes'.padLeft(2, '0')}:$tail';
}

String formatRecordingBytes(int bytes) {
  if (bytes < 1024) return '${bytes < 0 ? 0 : bytes} B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
}

String recordingError(int code) => switch (code) {
  SdrRecordError.noSpace => 'Recording stopped: no space left in the folder',
  SdrRecordError.folderUnavailable =>
    'Recording folder is not accessible; choose another folder',
  SdrRecordError.notSeekable => 'Recording folder cannot create seekable files',
  SdrRecordError.nameExhausted =>
    'Recording file names exhausted in this folder',
  SdrRecordError.exists => 'Recording file already exists',
  SdrResult.invalidState => 'Start reception before recording',
  SdrResult.unsupported =>
    'Selected recording output is not supported by this build',
  SdrResult.invalidArgument =>
    'Invalid recording options; check Recording settings',
  _ => 'Recording error ($code)',
};

class RecordingController extends ChangeNotifier {
  RecordingController({
    required this.radio,
    required this.folderStore,
    required this.capabilities,
    required this.availableLogIds,
    required this.startNative,
    required this.stopNative,
    required this.readStatus,
    RecordingPreferences? preferences,
  }) : preferences = preferences ?? RecordingPreferences() {
    radio.addListener(refresh);
    _timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => refresh(),
    );
  }

  factory RecordingController.forNative(NativeRadioController radio) =>
      RecordingController(
        radio: radio,
        folderStore: RecordFolderStore(),
        capabilities: radio.recordApi?.capabilities(),
        availableLogIds: () => {
          if (radio.recordApi != null) 'rds',
          ...radio.decoderBackend.availableIds,
        }.intersection(recordingLogIds),
        startNative: radio.startRecording,
        stopNative: radio.stopRecording,
        readStatus: () => radio.recordingStatus,
      );

  final RadioController radio;
  final RecordFolderStore folderStore;
  final SdrRecordCapabilities? capabilities;
  final Set<String> Function() availableLogIds;
  final Future<int> Function(SdrRecordConfig, String, List<String>) startNative;
  final Future<int> Function() stopNative;
  final SdrRecordStatus? Function() readStatus;
  final RecordingPreferences preferences;
  late final Timer _timer;
  bool _busy = false, _disposed = false;
  RecordChoices choices = const RecordChoices();
  RecordFolder? folder;
  SdrRecordStatus? status;
  String? error;
  RecordingSettingsTarget? settingsTarget;

  bool get active => status?.state == SdrRecordState.active;
  bool get available => capabilities != null;
  bool get busy => _busy;

  Future<void> load() async {
    choices = await preferences.load();
    folder = await folderStore.load();
    refresh();
  }

  Future<void> saveChoices(RecordChoices updated) async {
    choices = updated;
    await preferences.save(updated);
    _notify();
  }

  Future<void> chooseFolder() async {
    try {
      folder = await folderStore.choose();
      error = null;
      settingsTarget = null;
    } catch (e) {
      error = '$e';
      settingsTarget = RecordingSettingsTarget.folder;
    }
    _notify();
  }

  void refresh() {
    if (_disposed || capabilities == null) return;
    try {
      final current = readStatus();
      if (current != null) {
        status = current;
        if (current.state == SdrRecordState.failed) {
          error = recordingError(current.lastError);
          settingsTarget = current.lastError == SdrRecordError.folderUnavailable
              ? RecordingSettingsTarget.folder
              : null;
        }
      }
    } catch (e) {
      error = 'Could not read recording status: $e';
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> toggle() async {
    if (_busy || _disposed) return;
    _busy = true;
    _notify();
    try {
      if (active) {
        final result = await stopNative();
        if (result != SdrResult.ok) error = recordingError(result);
        refresh();
        return;
      }
      error = null;
      settingsTarget = null;
      if (!available) {
        error = 'Recording is unavailable in this native build';
        return;
      }
      final selected = folder = await folderStore.load();
      if (selected == null) {
        error = 'Choose a recording folder in Settings';
        settingsTarget = RecordingSettingsTarget.folder;
        return;
      }
      if (!await folderStore.isAccessible()) {
        error = 'Recording folder is not accessible; choose another folder';
        settingsTarget = RecordingSettingsTarget.folder;
        return;
      }
      final supported = capabilities!;
      final streams = choices.streams;
      final ids = (choices.logIds.intersection(availableLogIds()).toList()
        ..sort());
      if (streams == 0 ||
          streams == SdrRecordStream.decoderLog && ids.isEmpty) {
        error = 'Select at least one available output in What to record';
        settingsTarget = RecordingSettingsTarget.streams;
        return;
      }
      if (streams & ~supported.streams != 0 ||
          (streams & SdrRecordStream.decoderLog != 0 && ids.isEmpty)) {
        error =
            'Selected recording output is not available; change What to record';
        settingsTarget = RecordingSettingsTarget.streams;
        return;
      }
      final audio =
          streams & (SdrRecordStream.audio | SdrRecordStream.squelchAudio) != 0;
      final format = audio ? choices.format : SdrRecordFormat.none;
      if (!supported.supports(streams, format)) {
        error = 'Selected audio format is not supported by this build';
        settingsTarget = RecordingSettingsTarget.format;
        return;
      }
      if (!radio.running) {
        error = 'Start reception before recording';
        return;
      }
      if (status?.state == SdrRecordState.failed) {
        // Failed writer threads must be joined before another native start.
        final acknowledged = await stopNative();
        if (acknowledged != SdrResult.ok) {
          error = recordingError(acknowledged);
          return;
        }
      }
      final now = DateTime.now();
      final result = await startNative(
        SdrRecordConfig(
          streams: streams,
          audioFormat: format,
          audioBitrateKbps: format == SdrRecordFormat.mp3
              ? choices.mp3Bitrate
              : format == SdrRecordFormat.opus
              ? choices.opusBitrate
              : 0,
          startUnixMs: now.millisecondsSinceEpoch,
          utcOffsetMinutes: now.timeZoneOffset.inMinutes,
        ),
        selected.locator,
        ids,
      );
      if (result != SdrResult.ok) {
        error = recordingError(result);
      } else {
        refresh();
      }
    } catch (e) {
      error = 'Recording failed: $e';
    } finally {
      _busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer.cancel();
    radio.removeListener(refresh);
    super.dispose();
  }
}

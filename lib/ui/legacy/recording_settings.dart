// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../native/native_record_api.dart';
import '../recording/recording_controller.dart';
import 'theme.dart';

class RecordingSettings extends StatelessWidget {
  const RecordingSettings({super.key, required this.recording});
  final RecordingController recording;

  static const _formats = <int, String>{
    SdrRecordFormat.wav: 'WAV',
    SdrRecordFormat.flac: 'FLAC',
    SdrRecordFormat.mp3: 'MP3',
    SdrRecordFormat.opus: 'Ogg Opus',
  };

  static Future<void> showChoices(
    BuildContext context,
    RecordingController recording,
  ) async {
    var draft = recording.choices;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          Widget check(String title, int stream) => CheckboxListTile(
            key: ValueKey('recordStream-$stream'),
            title: Text(title, style: plex(size: 13)),
            dense: true,
            value: draft.streams & stream != 0,
            onChanged:
                recording.capabilities?.streams == null ||
                    recording.capabilities!.streams & stream == 0
                ? null
                : (enabled) => update(
                    () => draft = draft.copyWith(
                      streams: enabled == true
                          ? draft.streams | stream
                          : draft.streams & ~stream,
                    ),
                  ),
          );
          final ids = recording.availableLogIds().toList()..sort();
          return AlertDialog(
            title: const Text('What to record'),
            contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    check('Raw IQ (SigMF)', SdrRecordStream.iq),
                    check('Continuous audio', SdrRecordStream.audio),
                    check(
                      'Audio per squelch opening',
                      SdrRecordStream.squelchAudio,
                    ),
                    const Divider(),
                    for (final id in ids)
                      CheckboxListTile(
                        key: ValueKey('recordLog-$id'),
                        title: Text(
                          '${id == 'rds' ? 'RDS' : id} log',
                          style: plex(size: 13),
                        ),
                        dense: true,
                        value: draft.logIds.contains(id),
                        onChanged:
                            recording.capabilities?.streams == null ||
                                recording.capabilities!.streams &
                                        SdrRecordStream.decoderLog ==
                                    0
                            ? null
                            : (enabled) => update(() {
                                final selected = {...draft.logIds};
                                if (enabled == true) {
                                  selected.add(id);
                                } else {
                                  selected.remove(id);
                                }
                                draft = draft.copyWith(
                                  logIds: selected,
                                  streams: selected.isNotEmpty
                                      ? draft.streams |
                                            SdrRecordStream.decoderLog
                                      : draft.streams &
                                            ~SdrRecordStream.decoderLog,
                                );
                              }),
                      ),
                    if (ids.isEmpty)
                      const ListTile(title: Text('No decoder logs available')),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('recordChoicesApply'),
                onPressed: () async {
                  await recording.saveChoices(draft);
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: recording,
    builder: (context, _) {
      final capabilities = recording.capabilities;
      final selected = recording.choices;
      final supportedFormats = _formats.keys
          .where(
            (format) =>
                capabilities?.formats != null &&
                capabilities!.formats & (1 << format) != 0,
          )
          .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 15, 4, 8),
            child: Text(
              'RECORDING',
              style: plex(size: 11, color: LegacyColors.accent),
            ),
          ),
          if (recording.error case final message?)
            _card('Recording error', message),
          _card(
            'Folder',
            recording.folder?.displayName ?? 'Not set',
            trailing: TextButton(
              key: const ValueKey('recordFolder'),
              onPressed: capabilities == null ? null : recording.chooseFolder,
              child: const Text('Choose'),
            ),
          ),
          _card(
            'What to record',
            selected.streams == 0
                ? 'Nothing selected'
                : '${selected.streams & SdrRecordStream.iq != 0 ? 'IQ · ' : ''}'
                      '${selected.streams & SdrRecordStream.audio != 0 ? 'Audio · ' : ''}'
                      '${selected.streams & SdrRecordStream.squelchAudio != 0 ? 'Squelch · ' : ''}'
                      '${selected.logIds.isEmpty ? 'No logs' : '${selected.logIds.length} logs'}',
            trailing: TextButton(
              key: const ValueKey('recordChoices'),
              onPressed: capabilities == null
                  ? null
                  : () => showChoices(context, recording),
              child: const Text('Select'),
            ),
          ),
          _card(
            'Audio format',
            'Changes apply to the next recording',
            trailing: DropdownButton<int>(
              key: const ValueKey('recordFormat'),
              value: supportedFormats.contains(selected.format)
                  ? selected.format
                  : null,
              hint: const Text('Unavailable'),
              items: [
                for (final format in supportedFormats)
                  DropdownMenuItem(
                    value: format,
                    child: Text(_formats[format]!, style: plex(size: 12)),
                  ),
              ],
              onChanged: (format) {
                if (format != null) {
                  recording.saveChoices(selected.copyWith(format: format));
                }
              },
            ),
          ),
          if (selected.format == SdrRecordFormat.mp3 ||
              selected.format == SdrRecordFormat.opus)
            _card(
              'Audio bitrate',
              'kbps · next recording',
              trailing: DropdownButton<int>(
                key: const ValueKey('recordBitrate'),
                value: selected.format == SdrRecordFormat.mp3
                    ? selected.mp3Bitrate
                    : selected.opusBitrate,
                items: [
                  for (final bitrate
                      in selected.format == SdrRecordFormat.mp3
                          ? recordingMp3Bitrates
                          : recordingOpusBitrates)
                    DropdownMenuItem(
                      value: bitrate,
                      child: Text('$bitrate kbps', style: plex(size: 12)),
                    ),
                ],
                onChanged: (bitrate) {
                  if (bitrate != null) {
                    recording.saveChoices(
                      selected.format == SdrRecordFormat.mp3
                          ? selected.copyWith(mp3Bitrate: bitrate)
                          : selected.copyWith(opusBitrate: bitrate),
                    );
                  }
                },
              ),
            ),
          if (capabilities == null)
            _card('Unavailable', 'This native build has no recording support'),
        ],
      );
    },
  );

  Widget _card(String label, String detail, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: legacyCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: plex(size: 14)),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: plex(size: 11, color: LegacyColors.muted),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
}

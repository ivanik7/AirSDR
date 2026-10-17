// SPDX-License-Identifier: GPL-3.0-or-later
// DMR panel modelled on OpenWebRX+ MetaPanel `DmrMetaSlot`: two timeslot
// cards (tap = mute/unmute that slot via the upstream slot-filter bitmask),
// plus a bounded call history and the optional colour-code filter. Volume
// stays on the normal audio controls; no PCM enters Dart.
import 'package:flutter/material.dart';

import '../legacy/theme.dart';
import 'decoder_session.dart';
import 'dmr_call.dart';

class DmrDecoderPanel extends StatelessWidget {
  const DmrDecoderPanel({super.key, required this.session});
  final DecoderSession session;

  /// Slot-filter bitmask after toggling [slot] (0=TS1, 1=TS2), or null if
  /// that would mute both slots (the native filter needs at least one).
  static int? toggledSlotMask(int mask, int slot) {
    final next = mask ^ (1 << slot);
    return next == 0 ? null : next;
  }

  @override
  Widget build(BuildContext context) {
    final available = session.isAvailable('dmr');
    final running = session.radio.running;
    final settings = session.currentSettings;
    final mask = settings['slot_filter'] as int;
    return Column(
      key: const ValueKey('decoderPanel-dmr'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('DMR · 12.5 kHz', style: plex(size: 14)),
              const SizedBox(height: 4),
              Text(
                !available
                    ? 'Unavailable in the current native build'
                    : !running
                    ? 'Reception stopped'
                    : session.failureReason ??
                          (session.active
                              ? 'Decoding active'
                              : 'Decoder not running'),
                key: const ValueKey('dmrStatus'),
                style: plex(
                  size: 12,
                  color: session.active
                      ? LegacyColors.accent
                      : LegacyColors.muted,
                ),
              ),
              Text(
                'Frequency is the shared VFO · volume is the shared audio setting · '
                'dropped events: ${session.droppedEvents}',
                style: plex(size: 11, color: LegacyColors.muted),
              ),
              Text(
                'Callsign lookup by DMR ID (radioid.net) is not supported: '
                'only over-the-air data is shown.',
                key: const ValueKey('dmrIdLookupNote'),
                style: plex(size: 11, color: LegacyColors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (var slot = 0; slot < 2; slot++) ...[
          _slotCard(slot, mask),
          const SizedBox(height: 8),
        ],
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Filters', style: plex(size: 14)),
              _filter(
                'Timeslot',
                'slot_filter',
                settings['slot_filter'] as int,
                const {3: 'Both', 1: 'TS1', 2: 'TS2'},
              ),
              _filter(
                'Color code',
                'color_code',
                settings['color_code'] as int,
                {for (var i = -1; i < 16; i++) i: i < 0 ? 'Any' : '$i'},
              ),
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile(
                  key: const ValueKey('dmrVoice'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('Voice', style: plex(size: 13)),
                  value: settings['voice'] as bool,
                  onChanged: session.canConfigure('dmr')
                      ? (value) => session.setSetting('dmr', 'voice', value)
                      : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Call history · ${session.dmrHistory.length}',
                style: plex(size: 14),
              ),
            ),
            TextButton(
              key: const ValueKey('dmrClearHistory'),
              onPressed: session.dmrHistory.isEmpty
                  ? null
                  : session.clearDmrHistory,
              child: const Text('Clear'),
            ),
          ],
        ),
        for (final call in session.dmrHistory)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: legacyCard(child: _callDetails(call, history: true)),
          ),
      ],
    );
  }

  Widget _filter(
    String label,
    String key,
    int selected,
    Map<int, String> options,
  ) => Row(
    children: [
      Expanded(child: Text(label, style: plex(size: 12))),
      DropdownButton<int>(
        key: ValueKey('dmrSetting-$key'),
        value: selected,
        items: [
          for (final option in options.entries)
            DropdownMenuItem(
              value: option.key,
              child: Text(option.value, style: plex(size: 12)),
            ),
        ],
        onChanged: session.canConfigure('dmr')
            ? (value) {
                if (value != null) session.setSetting('dmr', key, value);
              }
            : null,
      ),
    ],
  );

  Widget _slotCard(int slot, int mask) {
    final call = session.dmrSlots[slot];
    final sync = session.dmrSync[slot];
    final muted = mask & (1 << slot) == 0;
    final next = toggledSlotMask(mask, slot);
    final canToggle = session.canConfigure('dmr') && next != null;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: ValueKey('dmrSlotToggle-${slot + 1}'),
        onTap: canToggle
            ? () => session.setSetting('dmr', 'slot_filter', next)
            : null,
        child: legacyCard(
          child: Column(
            key: ValueKey('dmrSlot-${slot + 1}'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('TS${slot + 1}', style: plex(size: 14))),
                  if (muted)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        'Disabled',
                        key: ValueKey('dmrSlotMuted-${slot + 1}'),
                        style: plex(size: 11, color: LegacyColors.danger),
                      ),
                    ),
                  Text(
                    sync == 'voice'
                        ? 'Voice · sync'
                        : sync == 'data'
                        ? 'Data · sync'
                        : 'No sync',
                    key: ValueKey('dmrSync-${slot + 1}'),
                    style: plex(
                      size: 11,
                      color: sync == null
                          ? LegacyColors.muted
                          : LegacyColors.accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (call == null)
                Text(
                  'No current call',
                  style: plex(size: 12, color: LegacyColors.muted),
                )
              else
                _callDetails(call),
            ],
          ),
        ),
      ),
    );
  }

  Widget _callDetails(DmrCall call, {bool history = false}) {
    final parts = <String>[
      if (call.type != null) call.type == 'group' ? 'Group' : 'Private',
      if (call.target != null)
        '${call.type == 'group' ? 'TG' : 'Target'} ${call.target}',
      if (call.source != null) 'Source ${call.source}',
      if (call.colorCode != null) 'CC ${call.colorCode}',
    ];
    final details = <String>[
      if (call.alias != null) 'Alias: ${call.alias}',
      if (call.latitude != null && call.longitude != null)
        'GPS: ${call.latitude!.toStringAsFixed(5)}, '
            '${call.longitude!.toStringAsFixed(5)}',
      if (call.voice == 'unavailable') 'Audio unavailable',
      if (call.voice == 'muted') 'Audio muted',
      if (call.durationMs != null)
        'Duration (voice frames): '
            '${(call.durationMs! / 1000).toStringAsFixed(1)} s'
      else if (history)
        'Duration (by events): '
            '${call.elapsed(call.endedAt!).inSeconds} s',
      if (history) 'TS${call.slot + 1} · ${_clock(call.startedAt)}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                parts.isEmpty
                    ? 'Call · no metadata received'
                    : parts.join(' · '),
                style: plex(size: 12),
              ),
            ),
            if (call.privacy == true)
              Container(
                key: ValueKey(
                  'dmrEncrypted-${history ? 'h' : 's'}${call.slot + 1}',
                ),
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  border: Border.all(color: LegacyColors.danger),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.lock_outline,
                      size: 12,
                      color: LegacyColors.danger,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      'Enc.',
                      style: plex(size: 11, color: LegacyColors.danger),
                    ),
                  ],
                ),
              ),
          ],
        ),
        for (final detail in details)
          Text(detail, style: plex(size: 11, color: LegacyColors.muted)),
      ],
    );
  }

  static String _clock(DateTime t) =>
      t.toLocal().toIso8601String().substring(11, 19);
}

// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../legacy/theme.dart';
import 'decoder_session.dart';
import 'dmr_call.dart';

class DmrDecoderPanel extends StatelessWidget {
  const DmrDecoderPanel({super.key, required this.session});
  final DecoderSession session;

  @override
  Widget build(BuildContext context) {
    final available = session.isAvailable('dmr');
    final running = session.radio.running;
    final settings = session.currentSettings;
    return Column(
      key: const ValueKey('decoderPanel-dmr'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('DMR · 12,5 кГц', style: plex(size: 14)),
              const SizedBox(height: 4),
              Text(
                !available
                    ? 'Недоступен в текущей нативной сборке'
                    : !running
                    ? 'Приём остановлен'
                    : session.failureReason ??
                          (session.active
                              ? 'Декодирование активно'
                              : 'Декодер не запущен'),
                key: const ValueKey('dmrStatus'),
                style: plex(
                  size: 12,
                  color: session.active
                      ? LegacyColors.accent
                      : LegacyColors.muted,
                ),
              ),
              Text(
                'Частота — общий VFO · громкость — общая настройка аудио · '
                'потеряно событий: ${session.droppedEvents}',
                style: plex(size: 11, color: LegacyColors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (var slot = 0; slot < 2; slot++) ...[
          _slotCard(slot),
          const SizedBox(height: 8),
        ],
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Фильтры', style: plex(size: 14)),
              _filter(
                'Таймслот',
                'slot_filter',
                settings['slot_filter'] as int,
                const {3: 'Оба', 1: 'TS1', 2: 'TS2'},
              ),
              _filter(
                'Цветовой код',
                'color_code',
                settings['color_code'] as int,
                {for (var i = -1; i < 16; i++) i: i < 0 ? 'Любой' : '$i'},
              ),
              SwitchListTile(
                key: const ValueKey('dmrVoice'),
                contentPadding: EdgeInsets.zero,
                title: Text('Голос', style: plex(size: 13)),
                value: settings['voice'] as bool,
                onChanged: session.canConfigure('dmr')
                    ? (value) => session.setSetting('dmr', 'voice', value)
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'История вызовов · ${session.dmrHistory.length}',
                style: plex(size: 14),
              ),
            ),
            TextButton(
              key: const ValueKey('dmrClearHistory'),
              onPressed: session.dmrHistory.isEmpty
                  ? null
                  : session.clearDmrHistory,
              child: const Text('Очистить'),
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

  Widget _slotCard(int slot) {
    final call = session.dmrSlots[slot];
    final sync = session.dmrSync[slot];
    return legacyCard(
      child: Column(
        key: ValueKey('dmrSlot-${slot + 1}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('TS${slot + 1}', style: plex(size: 14))),
              Text(
                sync == 'voice'
                    ? 'Голос · синхр.'
                    : sync == 'data'
                    ? 'Данные · синхр.'
                    : 'Нет синхронизации',
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
              'Нет текущего вызова',
              style: plex(size: 12, color: LegacyColors.muted),
            )
          else
            _callDetails(call),
        ],
      ),
    );
  }

  Widget _callDetails(DmrCall call, {bool history = false}) {
    final parts = <String>[
      if (call.type != null) call.type == 'group' ? 'Групповой' : 'Прямой',
      if (call.target != null)
        '${call.type == 'group' ? 'TG' : 'Адресат'} ${call.target}',
      if (call.source != null) 'Источник ${call.source}',
      if (call.colorCode != null) 'CC ${call.colorCode}',
      if (call.privacy == true) 'Шифрование',
    ];
    final details = <String>[
      if (call.alias != null) 'Псевдоним: ${call.alias}',
      if (call.latitude != null && call.longitude != null)
        'GPS: ${call.latitude}, ${call.longitude}',
      if (call.voice == 'unavailable') 'Аудио недоступно',
      if (call.voice == 'muted') 'Аудио выключено',
      if (history)
        'Длительность (по событиям): ${call.elapsed(call.endedAt!).inSeconds} с',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          parts.isEmpty ? 'Вызов · метаданные не получены' : parts.join(' · '),
          style: plex(size: 12),
        ),
        for (final detail in details)
          Text(detail, style: plex(size: 11, color: LegacyColors.muted)),
      ],
    );
  }
}

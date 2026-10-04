// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../radio_controller.dart';
import 'centered_receiver.dart';
import 'squelch_controls.dart';
import 'theme.dart';

const _optionLabels = <String, String>{
  'stereo': 'Стерео',
  'lowPass': 'Фильтр НЧ',
  'carrierAgc': 'АРУ несущей',
};

/// Receiver audio controls and backend-dependent decoder results.
class DecoderScreen extends StatelessWidget {
  const DecoderScreen({
    super.key,
    required this.controller,
    required this.receiver,
  });

  final RadioController controller;
  final CenteredReceiver receiver;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final radio = controller;
      final mode = radio.mode;
      final params = mode.params;
      final options = radio.demodOptions;
      return ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: [
          Text('Decoder', style: plex(size: 22, weight: FontWeight.w600)),
          const SizedBox(height: 12),
          _heading('АУДИО · ДЕМОДУЛЯТОР'),
          legacyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Режим приёма', style: plex(size: 14)),
                const SizedBox(height: 6),
                PopupMenuButton<DemodMode>(
                  key: const ValueKey('legacyModeSelect'),
                  tooltip: 'Модуляция',
                  initialValue: mode,
                  onSelected: receiver.changeMode,
                  itemBuilder: (context) => [
                    for (final choice in DemodMode.values)
                      PopupMenuItem(
                        key: ValueKey('legacyMode-${choice.label}'),
                        value: choice,
                        child: Text(choice.label),
                      ),
                  ],
                  child: SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            mode.label,
                            style: plex(size: 16, color: LegacyColors.accent),
                          ),
                        ),
                        const Icon(
                          Icons.arrow_drop_down,
                          color: LegacyColors.accent,
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(color: LegacyColors.key),
                Row(
                  children: [
                    Expanded(
                      child: Text('Полоса канала', style: plex(size: 14)),
                    ),
                    Text(
                      '${(radio.bandwidth / 1000).toStringAsFixed(1)} кГц',
                      key: const ValueKey('decoderBandwidthValue'),
                      style: plex(
                        mono: true,
                        size: 12,
                        color: LegacyColors.accent,
                      ),
                    ),
                  ],
                ),
                Slider(
                  key: const ValueKey('decoderBandwidth'),
                  value: radio.bandwidth.clamp(
                    params.minBandwidth,
                    params.maxBandwidth,
                  ),
                  min: params.minBandwidth,
                  max: params.maxBandwidth > params.minBandwidth
                      ? params.maxBandwidth
                      : params.minBandwidth + 1,
                  onChanged: params.bandwidthLocked ? null : radio.setBandwidth,
                ),
                Text(
                  'Демодуляция · ${(params.minBandwidth / 1000).toStringAsFixed(1)}–${(params.maxBandwidth / 1000).toStringAsFixed(1)} кГц · не частота выборки IQ',
                  style: plex(size: 11, color: LegacyColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SquelchControls(controller: radio),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 8),
            legacyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Параметры ${mode.label}', style: plex(size: 14)),
                  for (final entry in _optionLabels.entries)
                    if (options[entry.key] is bool)
                      Material(
                        type: MaterialType.transparency,
                        child: SwitchListTile(
                          key: ValueKey('demod:${entry.key}'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(entry.value, style: plex(size: 14)),
                          value: options[entry.key]! as bool,
                          onChanged: (value) =>
                              radio.setDemodOption(entry.key, value),
                        ),
                      ),
                ],
              ),
            ),
          ] else if (mode == DemodMode.wfm) ...[
            const SizedBox(height: 8),
            Text(
              'Стерео WFM недоступно в текущем нативном приёмнике (моно).',
              style: plex(size: 12, color: LegacyColors.muted),
            ),
          ],
          const SizedBox(height: 18),
          _heading('РЕЗУЛЬТАТЫ ДЕКОДИРОВАНИЯ'),
          Text(
            'Декодеры пока недоступны. Нет полученных данных.',
            style: plex(size: 12, color: LegacyColors.muted),
          ),
          const SizedBox(height: 8),
          const _ResultPanel(
            id: 'rtl433',
            icon: Icons.sensors,
            title: 'rtl_433 · устройства',
            description: 'Сообщений нет. Позже: устройство, поля, время последнего приёма и подробности.',
          ),
          const _ResultPanel(
            id: 'sstvFax',
            icon: Icons.image_outlined,
            title: 'SSTV / FAX · изображения',
            description: 'Изображения нет. Позже: процесс приёма и сохранённые результаты.',
          ),
          const _ResultPanel(
            id: 'adsb',
            icon: Icons.flight_outlined,
            title: 'ADS-B · самолёты',
            description: 'Списка нет. Позже: позывной, высота, положение и время обновления.',
          ),
          const _ResultPanel(
            id: 'textPacket',
            icon: Icons.message_outlined,
            title: 'Текст / пакеты',
            description:
                'Сообщений нет. RDS и другие текстовые декодеры недоступны.',
          ),
          const SizedBox(height: 8),
          Text(
            'Для широкополосных режимов (rtl_433, ADS-B) один приёмник остановит обычное прослушивание. Запуск будет доступен только с настоящим декодером.',
            style: plex(size: 12, color: LegacyColors.muted),
          ),
        ],
      );
    },
  );

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
    child: Text(title, style: plex(size: 11, color: LegacyColors.accent)),
  );
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({
    required this.id,
    required this.icon,
    required this.title,
    required this.description,
  });

  final String id;
  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: KeyedSubtree(
      key: ValueKey('decoder-$id'),
      child: legacyCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 24, color: LegacyColors.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: plex(size: 14)),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: plex(size: 12, color: LegacyColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

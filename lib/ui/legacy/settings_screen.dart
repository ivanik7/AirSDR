// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../radio_controller.dart';
import '../source_settings.dart';
import 'centered_receiver.dart';
import 'theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
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
      final r = controller;
      final d = r.selectedDevice;
      final g = d?.gain;
      return ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
        children: [
          Text(
            'Настройки приёмника',
            style: plex(size: 22, weight: FontWeight.w600),
          ),
          Text(
            d?.name ?? 'Устройство не выбрано',
            style: plex(size: 12, color: LegacyColors.muted),
          ),
          const SizedBox(height: 14),
          _section('ПОДКЛЮЧЕНИЕ К SDR'),
          _row(
            'Устройство',
            d?.name ?? 'Не найдено',
            trailing: IconButton(
              tooltip: 'Обновить устройства',
              onPressed: r.running ? null : r.refreshDevices,
              icon: const Icon(Icons.refresh),
            ),
          ),
          _row(
            'USB параметры',
            'Bias-T · PPM · sample rate · direct sampling',
            trailing: TextButton(
              onPressed: () => showSourceSettingsSheet(context, r),
              child: const Text('Открыть'),
            ),
          ),
          if (d != null)
            _row(
              'Частота выборки',
              'Ширина обзора спектра',
              trailing: DropdownButton<double>(
                value: d.sampleRates.contains(r.sampleRate)
                    ? r.sampleRate
                    : null,
                onChanged: r.running
                    ? null
                    : (v) {
                        if (v != null) r.setSampleRate(v);
                      },
                items: [
                  for (final rate in d.sampleRates)
                    DropdownMenuItem(
                      value: rate,
                      child: Text(
                        '${(rate / 1000000).toStringAsFixed(2)} МГц',
                        style: plex(size: 12),
                      ),
                    ),
                ],
              ),
            ),
          _section('ПАРАМЕТРЫ ПРИЁМНИКА'),
          _row(
            'AGC приёмника',
            'Автоматическое усиление',
            trailing: Switch(
              value: r.agc,
              onChanged: d?.hasAgc == true ? r.setAgc : null,
            ),
          ),
          _slider(
            'Усиление RF',
            r.gain,
            g?.min ?? 0,
            g?.max ?? 1,
            g == null || r.agc ? null : r.setGain,
            '${r.gain.toStringAsFixed(1)} ${g?.unit ?? 'dB'}',
          ),
          _slider(
            'Громкость',
            r.volume,
            0,
            1,
            r.setVolume,
            '${(r.volume * 100).round()}%',
          ),
          _row(
            'Шумодав',
            'Порог ${r.squelchLevel.toStringAsFixed(0)} dB',
            trailing: Switch(
              value: r.squelchEnabled,
              onChanged: r.mode.params.squelchAllowed
                  ? r.setSquelchEnabled
                  : null,
            ),
          ),
          _slider(
            'Порог шумодава',
            r.squelchLevel,
            -100,
            0,
            r.squelchEnabled && r.mode.params.squelchAllowed
                ? r.setSquelchLevel
                : null,
            '${r.squelchLevel.toStringAsFixed(0)} dB',
          ),
          _section('СОСТОЯНИЕ'),
          _row(
            'Приём',
            r.running
                ? 'Активен · ${(r.tunedFrequency / 1000000).toStringAsFixed(3)} MHz'
                : 'Остановлен',
            trailing: TextButton(
              onPressed: () => r.running ? r.stop() : receiver.start(),
              child: Text(r.running ? 'Стоп' : 'Старт'),
            ),
          ),
          if (r.lastError != null)
            _row(
              'Ошибка',
              r.lastError!,
              trailing: IconButton(
                onPressed: r.clearError,
                icon: const Icon(Icons.close),
              ),
            ),
          for (final entry in r.stats.entries)
            _row(entry.key, '${entry.value}'),
          _section('ПОЗЖЕ'),
          _row('Запись · rtl_tcp · уведомления', 'Недоступно в текущем движке'),
          _row('Сканирование каналов', 'Недоступно · работает один VFO'),
        ],
      );
    },
  );

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 15, 4, 8),
    child: Row(
      children: [
        Text(text, style: plex(size: 11, color: LegacyColors.accent)),
        const SizedBox(width: 9),
        const Expanded(child: Divider(color: LegacyColors.key)),
      ],
    ),
  );
  Widget _row(String label, String sub, {Widget? trailing}) => Padding(
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
                  sub,
                  style: plex(size: 11, color: LegacyColors.muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double>? change,
    String formatted,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: legacyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: plex(size: 14))),
              Text(
                formatted,
                style: plex(mono: true, size: 12, color: LegacyColors.accent),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: max > min ? change : null,
          ),
        ],
      ),
    ),
  );
}

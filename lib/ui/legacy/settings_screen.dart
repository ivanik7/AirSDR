// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../auto_levels.dart';
import '../device_dropdown.dart';
import '../radio_controller.dart';
import '../sdr_ui_state.dart';
import '../source_settings.dart';
import 'centered_receiver.dart';
import 'squelch_controls.dart';
import 'step_grid.dart';
import 'theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    required this.receiver,
    this.spectrum,
  });
  final RadioController controller;
  final CenteredReceiver receiver;

  /// Waterfall levels (Max/Min + Auto); the section is hidden without it.
  final SdrUiState? spectrum;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, ?spectrum]),
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
            'Выбрать устройство',
            'Автоподключение при обнаружении SDR',
            trailing: SizedBox(
              width: 150,
              child: DropdownButton<SdrDeviceInfo>(
                key: const ValueKey('legacyDevice'),
                isExpanded: true,
                value: dropdownDeviceValue(r),
                hint: const Text('Не найдено'),
                items: [
                  for (final device in r.devices)
                    DropdownMenuItem(
                      value: device,
                      child: Text(device.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: r.running
                    ? null
                    : (device) {
                        if (device != null) r.selectDevice(device);
                      },
              ),
            ),
          ),
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
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: SquelchControls(controller: r),
          ),
          if (spectrum case final s?) ..._waterfallLevels(s),
          _section('СОСТОЯНИЕ'),
          if (!r.running &&
              (r.linkState == DeviceLinkState.permissionDenied ||
                  r.linkState == DeviceLinkState.failed))
            _row(
              'Подключение USB',
              'Нет доступа к устройству',
              trailing: TextButton(
                key: const ValueKey('legacyRetryUsb'),
                onPressed: r.retryDevice,
                child: const Text('Повторить'),
              ),
            ),
          _row(
            'Приём',
            r.running
                ? 'Активен · ${formatMhz(r.tunedFrequency)} MHz'
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

  /// Waterfall/spectrum levels: Auto (auto_levels.dart) or manual Max/Min.
  /// In Auto the sliders show the automatic levels and are disabled.
  List<Widget> _waterfallLevels(SdrUiState s) {
    final auto = s.autoLevels;
    final floor = s.autoNoiseFloor;
    return [
      _section('ВОДОПАД'),
      _row(
        'Авто-контраст',
        auto
            ? (floor == null
                  ? 'Шум и пики за ${AutoLevelTuning.window.inSeconds} с · ждёт спектр'
                  : 'Шум ${floor.round()} dB · пик ${s.autoPeak!.round()} dB '
                        'за ${AutoLevelTuning.window.inSeconds} с')
            : 'Выкл. · уровни задаются вручную',
        trailing: Switch(
          key: const ValueKey('legacyAutoLevels'),
          value: auto,
          onChanged: s.setAutoLevels,
        ),
      ),
      _slider(
        'Max',
        s.fftMax,
        -150,
        0,
        auto ? null : (v) => s.setLevels(s.fftMin, v),
        '${s.fftMax.round()} dB',
        key: const ValueKey('legacyFftMax'),
      ),
      _slider(
        'Min',
        s.fftMin,
        -160,
        -10,
        auto ? null : (v) => s.setLevels(v, s.fftMax),
        '${s.fftMin.round()} dB',
        key: const ValueKey('legacyFftMin'),
      ),
    ];
  }

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
    String formatted, {
    Key? key,
  }) => Padding(
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
            key: key,
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

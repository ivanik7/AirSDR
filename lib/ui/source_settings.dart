// SPDX-License-Identifier: GPL-3.0-or-later
// Source-specific SDR++ settings; protocol IDs and option indices are unchanged.
import 'package:flutter/material.dart';

import 'radio_controller.dart';

Future<void> showSourceSettingsSheet(
  BuildContext context,
  RadioController radio,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, scroll) =>
          SourceSettingsPanel(radio: radio, scrollController: scroll),
    ),
  );
}

const _settingLabels = <String, String>{
  'gain': 'Усиление RF',
  'tunerAgc': 'АРУ тюнера',
  'directSampling': 'Прямая дискретизация',
  'ppm': 'Коррекция PPM',
  'biasT': 'Питание антенны (Bias-T)',
  'offsetTuning': 'Смещение настройки',
  'rtlAgc': 'АРУ RTL',
  'bandwidth': 'Полоса RF-фильтра',
  'lnaGain': 'Усиление LNA',
  'vgaGain': 'Усиление VGA',
  'amp': 'Усилитель HackRF',
  'noise': 'Уровень шума (dBFS)',
  'format': 'Формат IQ',
};

String _settingLabel(SourceSetting s) => _settingLabels[s.id] ?? s.label;

String _choiceLabel(String id, String value) => switch ((id, value)) {
  ('directSampling', 'Disabled') => 'Выкл.',
  ('directSampling', 'I branch') => 'Ветвь I',
  ('directSampling', 'Q branch') => 'Ветвь Q',
  ('bandwidth', 'Auto') => 'Авто',
  _ => value,
};

class SourceSettingsPanel extends StatelessWidget {
  const SourceSettingsPanel({
    super.key,
    required this.radio,
    this.scrollController,
  });

  final RadioController radio;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: radio,
      builder: (context, _) {
        final theme = Theme.of(context);
        final settings = radio.sourceSettings;
        final children = <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(switch (radio.selectedDevice) {
              null => 'Устройство не выбрано',
              final device when device.id.startsWith('synth:') =>
                'Генератор сигнала',
              final device => device.name,
            }, style: theme.textTheme.titleMedium),
          ),
          if (radio.selectedDevice == null)
            const ListTile(
              dense: true,
              title: Text('Выберите устройство в настройках'),
            ),
          for (final s in settings)
            // The shared controls are on the main Settings tab. RTL AGC is
            // distinct from tuner AGC; HackRF LNA/VGA are not combined RF gain.
            if (s.id != 'device' &&
                s.id != 'sampleRate' &&
                !(radio.selectedDevice?.hasAgc == true &&
                    (s.id == 'gain' || s.id == 'tunerAgc')))
              _SettingTile(
                key: ValueKey<String>('src:${s.id}'),
                setting: s,
                running: radio.running,
                radio: radio,
              ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              statsLine(radio),
              key: const ValueKey<String>('statsLine'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ];
        return ListView(controller: scrollController, children: children);
      },
    );
  }
}

/// Compact runtime status for the source sheet.
String statsLine(RadioController radio) {
  final st = radio.stats;
  final parts = <String>[
    '${(radio.sampleRate / 1e6).toStringAsFixed(2)} Мвыб/с',
    if (st['droppedBuffers'] is num) 'USB потери ${st['droppedBuffers']}',
    if (st['audioDropped'] is num) 'потери аудио ${st['audioDropped']}',
    if (st['audioOutput'] is String) 'выход ${st['audioOutput']}',
  ];
  return parts.join(' · ');
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    super.key,
    required this.setting,
    required this.running,
    required this.radio,
  });

  final SourceSetting setting;
  final bool running;
  final RadioController radio;

  @override
  Widget build(BuildContext context) {
    final s = setting;
    final enabled = !(running && s.id == 'refresh');
    final style = Theme.of(context).textTheme.bodyMedium;
    switch (s) {
      case ChoiceSetting c:
        return ListTile(
          dense: true,
          title: Text(_settingLabel(c), style: style),
          trailing: SizedBox(
            width: 132,
            child: DropdownButton<int>(
              isExpanded: true,
              value: (c.selected >= 0 && c.selected < c.options.length)
                  ? c.selected
                  : null,
              onChanged: enabled
                  ? (v) => v == null ? null : radio.setSourceSetting(c.id, v)
                  : null,
              items: [
                for (int i = 0; i < c.options.length; i++)
                  DropdownMenuItem<int>(
                    value: i,
                    child: Text(
                      _choiceLabel(c.id, c.options[i]),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        );
      case BoolSetting b:
        return SwitchListTile(
          dense: true,
          title: Text(_settingLabel(b), style: style),
          value: b.value,
          onChanged: enabled ? (v) => radio.setSourceSetting(b.id, v) : null,
        );
      case SliderSetting sl:
        final steps = sl.step > 0 ? ((sl.max - sl.min) / sl.step).round() : 0;
        if (steps > 1000) {
          return _NumberSettingTile(
            setting: sl,
            enabled: enabled,
            radio: radio,
          );
        }
        return _SliderSettingTile(setting: sl, enabled: enabled, radio: radio);
    }
  }
}

/// Slider applied on release (every applySetting is a USB round trip on the device).
class _SliderSettingTile extends StatefulWidget {
  const _SliderSettingTile({
    required this.setting,
    required this.enabled,
    required this.radio,
  });
  final SliderSetting setting;
  final bool enabled;
  final RadioController radio;

  @override
  State<_SliderSettingTile> createState() => _SliderSettingTileState();
}

class _SliderSettingTileState extends State<_SliderSettingTile> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final s = widget.setting;
    final steps = s.step > 0 ? ((s.max - s.min) / s.step).round() : 0;
    final v = (_drag ?? s.value).clamp(s.min, s.max);
    final valueText = s.step >= 1 ? v.round().toString() : v.toStringAsFixed(1);
    return ListTile(
      dense: true,
      title: Text(_settingLabel(s)),
      subtitle: Slider(
        value: v,
        min: s.min,
        max: s.max > s.min ? s.max : s.min + 1,
        divisions: steps > 0 ? steps : null,
        label: valueText,
        onChanged: (widget.enabled && s.max > s.min)
            ? (x) => setState(() => _drag = x)
            : null,
        onChangeEnd: (x) {
          widget.radio.setSourceSetting(s.id, x);
          setState(() => _drag = null);
        },
      ),
      trailing: SizedBox(
        width: 48,
        child: Text(valueText, textAlign: TextAlign.right),
      ),
    );
  }
}

/// Wide-range integer settings (PPM correction) as a number field.
class _NumberSettingTile extends StatelessWidget {
  const _NumberSettingTile({
    required this.setting,
    required this.enabled,
    required this.radio,
  });
  final SliderSetting setting;
  final bool enabled;
  final RadioController radio;

  @override
  Widget build(BuildContext context) {
    final s = setting;
    return ListTile(
      dense: true,
      title: Text(_settingLabel(s)),
      trailing: SizedBox(
        width: 104,
        child: TextFormField(
          key: ValueKey<double>(s.value),
          enabled: enabled,
          initialValue: s.value.round().toString(),
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          onFieldSubmitted: (t) {
            final v = int.tryParse(t.trim());
            if (v != null) {
              radio.setSourceSetting(
                s.id,
                v.clamp(s.min.toInt(), s.max.toInt()),
              );
            }
          },
        ),
      ),
    );
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// Source-specific settings (the SDR++ source menu: gui/menus/source.cpp + the selected source
// module's menuHandler, e.g. rtl_sdr_source/src/main.cpp:361-524) and demodulator options
// (radio module menu, e.g. the WFM "Stereo" checkbox), rendered from the declarative
// [SourceSetting] list of [RadioController.sourceSettings] / [RadioController.demodOptions].
// Also the one-line runtime status (sample rate, dropped buffers, audio output).

import 'package:flutter/material.dart';

import 'hrfreq.dart';
import 'radio_controller.dart';

/// Opens the settings as a modal bottom sheet.
Future<void> showSourceSettingsSheet(BuildContext context, RadioController radio) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, scroll) => SourceSettingsPanel(radio: radio, scrollController: scroll),
    ),
  );
}

/// Demod option keys shown as switches, with labels (bool options only; RDS is not ported).
const Map<String, String> _demodBoolOptions = <String, String>{
  'stereo': 'Stereo',
  'lowPass': 'Low pass',
  'carrierAgc': 'Carrier AGC',
};

class SourceSettingsPanel extends StatelessWidget {
  const SourceSettingsPanel({super.key, required this.radio, this.scrollController});

  final RadioController radio;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: radio,
      builder: (context, _) {
        final theme = Theme.of(context);
        final settings = radio.sourceSettings;
        final demod = radio.demodOptions;
        final children = <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(radio.selectedDevice?.name ?? 'No device', style: theme.textTheme.titleMedium),
          ),
          if (settings.isEmpty)
            const ListTile(dense: true, title: Text('No device-specific settings (select the device first)')),
          for (final s in settings)
            if (s.id != 'device') // one device per fd on Android
              _SettingTile(key: ValueKey<String>('src:${s.id}'), setting: s, running: radio.running, radio: radio),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('Demodulator ${radio.mode.label}', style: theme.textTheme.titleSmall),
          ),
          for (final e in _demodBoolOptions.entries)
            if (demod[e.key] is bool)
              SwitchListTile(
                key: ValueKey<String>('demod:${e.key}'),
                dense: true,
                title: Text(e.value),
                value: demod[e.key]! as bool,
                onChanged: (v) => radio.setDemodOption(e.key, v),
              ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(statsLine(radio), key: const ValueKey<String>('statsLine'), style: theme.textTheme.bodySmall),
          ),
        ];
        return ListView(controller: scrollController, children: children);
      },
    );
  }
}

/// "2.4 MSPS · drops 0 · audio mp_audio_stream" status text.
String statsLine(RadioController radio) {
  final st = radio.stats;
  final parts = <String>[
    '${hrfreqToString(radio.sampleRate)}S/s',
    if (st['droppedBuffers'] is num) 'USB drops ${st['droppedBuffers']}',
    if (st['audioDropped'] is num) 'audio drops ${st['audioDropped']}',
    if (st['audioOutput'] is String) 'out ${st['audioOutput']}',
  ];
  return parts.join(' · ');
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({super.key, required this.setting, required this.running, required this.radio});

  final SourceSetting setting;
  final bool running;
  final RadioController radio;

  // SDR++ disables these while the source runs (BeginDisabled in the module menus).
  static const Set<String> _disabledWhileRunning = <String>{'device', 'sampleRate', 'refresh'};

  @override
  Widget build(BuildContext context) {
    final s = setting;
    final enabled = !(running && _disabledWhileRunning.contains(s.id));
    final style = Theme.of(context).textTheme.bodyMedium;
    switch (s) {
      case ChoiceSetting c:
        return ListTile(
          dense: true,
          title: Text(c.label, style: style),
          trailing: DropdownButton<int>(
            value: (c.selected >= 0 && c.selected < c.options.length) ? c.selected : null,
            onChanged: enabled ? (v) => v == null ? null : radio.setSourceSetting(c.id, v) : null,
            items: [
              for (int i = 0; i < c.options.length; i++) DropdownMenuItem<int>(value: i, child: Text(c.options[i])),
            ],
          ),
        );
      case BoolSetting b:
        return SwitchListTile(
          dense: true,
          title: Text(b.label, style: style),
          value: b.value,
          onChanged: enabled ? (v) => radio.setSourceSetting(b.id, v) : null,
        );
      case SliderSetting sl:
        final steps = sl.step > 0 ? ((sl.max - sl.min) / sl.step).round() : 0;
        if (steps > 1000) {
          return _NumberSettingTile(setting: sl, enabled: enabled, radio: radio);
        }
        return _SliderSettingTile(setting: sl, enabled: enabled, radio: radio);
    }
  }
}

/// Slider applied on release (every applySetting is a USB round trip on the device).
class _SliderSettingTile extends StatefulWidget {
  const _SliderSettingTile({required this.setting, required this.enabled, required this.radio});
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
      title: Text(s.label),
      subtitle: Slider(
        value: v,
        min: s.min,
        max: s.max > s.min ? s.max : s.min + 1,
        divisions: steps > 0 ? steps : null,
        label: valueText,
        onChanged: (widget.enabled && s.max > s.min) ? (x) => setState(() => _drag = x) : null,
        onChangeEnd: (x) {
          widget.radio.setSourceSetting(s.id, x);
          setState(() => _drag = null);
        },
      ),
      trailing: SizedBox(width: 48, child: Text(valueText, textAlign: TextAlign.right)),
    );
  }
}

/// Wide-range integer settings (PPM correction) as a number field.
class _NumberSettingTile extends StatelessWidget {
  const _NumberSettingTile({required this.setting, required this.enabled, required this.radio});
  final SliderSetting setting;
  final bool enabled;
  final RadioController radio;

  @override
  Widget build(BuildContext context) {
    final s = setting;
    return ListTile(
      dense: true,
      title: Text(s.label),
      trailing: SizedBox(
        width: 120,
        child: TextFormField(
          key: ValueKey<double>(s.value),
          enabled: enabled,
          initialValue: s.value.round().toString(),
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          onFieldSubmitted: (t) {
            final v = int.tryParse(t.trim());
            if (v != null) radio.setSourceSetting(s.id, v.clamp(s.min.toInt(), s.max.toInt()));
          },
        ),
      ),
    );
  }
}

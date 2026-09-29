// SPDX-License-Identifier: GPL-3.0-or-later
// Squelch controls of the legacy UI (Приём and Настройки tabs): Выкл / Ручной / Авто.
//  * Ручной — the SDR++ power squelch, slider = level (−100..0 dB).
//  * Авто — the automatic squelch (app extension, auto_squelch.dart): noise squelch in NFM,
//    level squelch in AM/SSB/DSB/CW; the slider becomes the threshold offset ("sensitivity")
//    and the caption shows the live automatic threshold and open/closed state.
// A mode without a detector disables its segment (no fake switches).
import 'package:flutter/material.dart';

import '../radio_controller.dart';
import 'theme.dart';

/// One-line status of the squelch for [r] (also used by tests).
String squelchStatusText(RadioController r) {
  switch (r.squelchType) {
    case SquelchType.off:
      return 'Выкл.';
    case SquelchType.manual:
      return 'Ручной · порог ${r.squelchLevel.toStringAsFixed(0)} dB';
    case SquelchType.auto:
      final noise = r.mode.params.autoSquelch == AutoSquelchKind.noise;
      final kind = noise ? 'по шуму ЧМ' : 'по уровню';
      final s = r.autoSquelchStatus;
      if (s == null) return 'Авто $kind · ждёт приём';
      final state = s.open ? 'ОТКРЫТ' : 'закрыт';
      final th = s.thresholdDb;
      if (th == null) return 'Авто $kind · $state · учит шумовой пол…';
      final m = s.metricDb;
      final mTxt = m == null ? '—' : m.toStringAsFixed(0);
      return noise
          ? 'Авто $kind · $state · тишина $mTxt / порог ${th.toStringAsFixed(0)} dB'
          : 'Авто $kind · $state · $mTxt / порог ${th.toStringAsFixed(0)} dB';
  }
}

String _offsetText(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(0)} dB';

class SquelchControls extends StatelessWidget {
  const SquelchControls({super.key, required this.controller, this.compact = false});

  final RadioController controller;

  /// Receive tab: smaller paddings/fonts.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final r = controller;
    final manualOk = r.mode.params.squelchAllowed;
    final autoOk = r.autoSquelchAvailable;
    final type = r.squelchType;
    final auto = type == SquelchType.auto;
    final open = auto && (r.autoSquelchStatus?.open ?? false);
    return legacyCard(
      padding: EdgeInsets.all(compact ? 9 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Шумодав', style: plex(size: compact ? 13 : 14)),
              const SizedBox(width: 8),
              if (auto)
                Icon(
                  open ? Icons.graphic_eq : Icons.volume_off,
                  key: const ValueKey('squelchOpenIcon'),
                  size: 15,
                  color: open ? LegacyColors.accent : LegacyColors.muted,
                ),
              const Spacer(),
              SegmentedButton<SquelchType>(
                key: const ValueKey('squelchType'),
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(
                    value: SquelchType.off,
                    label: Text('Выкл', style: plex(size: 11)),
                  ),
                  ButtonSegment(
                    value: SquelchType.manual,
                    enabled: manualOk,
                    label: Text('Ручной', style: plex(size: 11)),
                  ),
                  ButtonSegment(
                    value: SquelchType.auto,
                    enabled: autoOk,
                    label: Text('Авто', style: plex(size: 11)),
                  ),
                ],
                selected: <SquelchType>{type},
                onSelectionChanged: (s) => r.setSquelchType(s.first),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            squelchStatusText(r),
            key: const ValueKey('squelchStatus'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: plex(
              mono: true,
              size: 11,
              color: open ? LegacyColors.accent : LegacyColors.muted,
            ),
          ),
          if (type == SquelchType.manual)
            _slider(
              'Порог',
              r.squelchLevel,
              -100,
              0,
              manualOk ? r.setSquelchLevel : null,
              '${r.squelchLevel.toStringAsFixed(0)} dB',
              const ValueKey('squelchLevelSlider'),
            ),
          if (auto)
            _slider(
              'Смещение порога (+ строже)',
              r.autoSquelchOffset,
              RadioController.minAutoSquelchOffset,
              RadioController.maxAutoSquelchOffset,
              r.setAutoSquelchOffset,
              _offsetText(r.autoSquelchOffset),
              const ValueKey('squelchAutoOffsetSlider'),
            ),
        ],
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double>? change,
    String formatted,
    Key key,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 4),
      Row(
        children: [
          Expanded(
            child: Text(label, style: plex(size: 12, color: LegacyColors.muted)),
          ),
          Text(
            formatted,
            style: plex(mono: true, size: 12, color: LegacyColors.accent),
          ),
        ],
      ),
      SizedBox(
        height: compact ? 30 : 40,
        child: Slider(
          key: key,
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: (max - min).round(),
          onChanged: change,
        ),
      ),
    ],
  );
}

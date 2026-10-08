// SPDX-License-Identifier: GPL-3.0-or-later
//
// Decoder tab building blocks: the backend/catalog-aware selector plus one
// panel per decoder. Exactly one panel is visible at a time (see
// legacy/decoder_screen.dart) — selecting a decoder here only changes what
// is displayed; see decoder_session.dart for why it never touches the radio.
import 'package:flutter/material.dart';

import 'decoder_contract.dart';
import 'decoder_session.dart';
import '../legacy/centered_receiver.dart';
import '../legacy/squelch_controls.dart';
import '../legacy/theme.dart';
import '../radio_controller.dart';

const _demodOptionLabels = <String, String>{
  'stereo': 'Стерео',
  'lowPass': 'Фильтр НЧ',
  'carrierAgc': 'АРУ несущей',
};

/// Row of decoder choices (decoder_contract.dart `decoderCatalog`). Every
/// entry is always selectable for *preview* — including a decoder the real
/// backend does not report as installed — so its "unavailable" panel can
/// be inspected; only the panel's own settings controls (and any backend
/// `select` call) are gated on [DecoderSession.isAvailable].
class DecoderSelector extends StatelessWidget {
  const DecoderSelector({super.key, required this.session});
  final DecoderSession session;

  @override
  Widget build(BuildContext context) => SegmentedButton<String>(
    key: const ValueKey('decoderSelector'),
    showSelectedIcon: false,
    expandedInsets: EdgeInsets.zero,
    style: const ButtonStyle(visualDensity: VisualDensity.compact),
    segments: [
      for (final d in decoderCatalog)
        ButtonSegment(
          value: d.id,
          label: Text(
            d.label,
            key: ValueKey('decoderSelect-${d.id}'),
            style: plex(size: 11),
          ),
        ),
    ],
    selected: <String>{session.selectedId},
    onSelectionChanged: (s) => session.selectPreview(s.first),
  );
}

/// The plain voice/audio receive path: demodulator mode, bandwidth,
/// squelch and demod options (e.g. WFM stereo). Identical to the receiver
/// controls that existed before decoders were added — [DecoderSession]
/// defaults to this panel and it is never gated on backend availability
/// (voice is not a decoder engine, it IS the existing receive path).
class VoiceDecoderPanel extends StatelessWidget {
  const VoiceDecoderPanel({
    super.key,
    required this.controller,
    required this.receiver,
  });
  final RadioController controller;
  final CenteredReceiver receiver;

  @override
  Widget build(BuildContext context) {
    final radio = controller;
    final mode = radio.mode;
    final params = mode.params;
    final options = radio.demodOptions;
    return Column(
      key: const ValueKey('decoderPanel-voice'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                  Expanded(child: Text('Полоса канала', style: plex(size: 14))),
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
                for (final entry in _demodOptionLabels.entries)
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
      ],
    );
  }

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
    child: Text(title, style: plex(size: 11, color: LegacyColors.accent)),
  );
}

/// Per-id icon/title/empty-state text for the data decoders
/// (decoder_contract.dart `DecoderResult`). Keyed by [DecoderDescriptor.id].
const Map<String, (IconData, String, String)> _placeholderMeta = {
  'sstv': (
    Icons.image_outlined,
    'SSTV · изображение',
    'Изображение пока не получено.',
  ),
  'rtl_433': (Icons.sensors, 'rtl_433 · сообщения', 'Сообщений пока нет.'),
  'adsb': (
    Icons.flight_outlined,
    'ADS-B · самолёты',
    'Самолётов в радиусе приёма пока нет.',
  ),
};

String _settingLabel(String key) => switch (key) {
  'frequency_hz' => 'Частота',
  'mode' => 'Режим',
  _ => key,
};

String _settingValueLabel(String key, Object value) {
  if (key == 'frequency_hz' && value is num) {
    return '${(value / 1e6).toStringAsFixed(3)} МГц';
  }
  return '$value';
}

/// Honest empty-state panel for a data decoder that is not (yet) backed by
/// a real engine: an icon + "nothing received" text, its declared settings
/// shown but disabled while unavailable (changing them could never take
/// effect without a backend), and — for an [DecoderDescriptor.exclusiveReceiver]
/// decoder — a note that starting it would stop normal voice reception.
/// Never shows a Start control or any other control that would look live.
class DecoderPlaceholderPanel extends StatelessWidget {
  const DecoderPlaceholderPanel({
    super.key,
    required this.descriptor,
    required this.session,
  });
  final DecoderDescriptor descriptor;
  final DecoderSession session;

  @override
  Widget build(BuildContext context) {
    final available = session.isAvailable(descriptor.id);
    final configurable = session.canConfigure(descriptor.id);
    final meta =
        _placeholderMeta[descriptor.id] ??
        (Icons.extension_outlined, descriptor.label, 'Нет данных.');
    final settings = session.settingsFor(descriptor.id);
    return Column(
      key: ValueKey('decoderPanel-${descriptor.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        legacyCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(meta.$1, size: 26, color: LegacyColors.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(meta.$2, style: plex(size: 14)),
                    const SizedBox(height: 4),
                    Text(
                      meta.$3,
                      style: plex(size: 12, color: LegacyColors.muted),
                    ),
                    if (!available) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Декодер недоступен в текущей нативной сборке — выбор здесь '
                        'только предпросмотр панели, запуск не выполняется.',
                        key: ValueKey('decoderUnavailable-${descriptor.id}'),
                        style: plex(size: 11, color: LegacyColors.danger),
                      ),
                    ] else if (!configurable) ...[
                      const SizedBox(height: 6),
                      Text(
                        descriptor.exclusiveReceiver
                            ? 'Только предпросмотр: безопасное переключение единственного приёмника пока не реализовано.'
                            : 'Для настройки включите приём в совместимом режиме демодуляции.',
                        style: plex(size: 11, color: LegacyColors.muted),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (descriptor.id == 'sstv')
          AspectRatio(
            aspectRatio: 4 / 3,
            child: KeyedSubtree(
              key: const ValueKey('decoderResult-sstv'),
              child: legacyCard(
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.image_not_supported_outlined, size: 42),
                      SizedBox(height: 8),
                      Text('Изображение не получено'),
                    ],
                  ),
                ),
              ),
            ),
          )
        else
          SizedBox(
            height: 130,
            child: KeyedSubtree(
              key: ValueKey('decoderResult-${descriptor.id}'),
              child: legacyCard(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    descriptor.id == 'rtl_433'
                        ? 'Журнал сообщений пуст'
                        : 'Список самолётов пуст',
                    style: plex(size: 12, color: LegacyColors.muted),
                  ),
                ),
              ),
            ),
          ),
        if (descriptor.settings.isNotEmpty) ...[
          const SizedBox(height: 8),
          legacyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Параметры', style: plex(size: 14)),
                for (final spec in descriptor.settings)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _settingLabel(spec.key),
                            style: plex(size: 12, color: LegacyColors.muted),
                          ),
                        ),
                        DropdownButton<Object>(
                          key: ValueKey(
                            'decoderSetting-${descriptor.id}-${spec.key}',
                          ),
                          value: settings[spec.key],
                          items: [
                            for (final v in spec.allowed)
                              DropdownMenuItem(
                                value: v,
                                child: Text(
                                  _settingValueLabel(spec.key, v),
                                  style: plex(size: 12),
                                ),
                              ),
                          ],
                          // Disabled while unavailable: a setting a native
                          // backend never reads must never look live.
                          onChanged: configurable
                              ? (v) {
                                  if (v != null) {
                                    session.setSetting(
                                      descriptor.id,
                                      spec.key,
                                      v,
                                    );
                                  }
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (descriptor.exclusiveReceiver) ...[
          const SizedBox(height: 8),
          Text(
            'Широкополосный декодер: запуск займёт единственный приёмник '
            'целиком — обычный приём остановится на всё время работы.',
            style: plex(size: 11, color: LegacyColors.muted),
          ),
        ],
      ],
    );
  }
}

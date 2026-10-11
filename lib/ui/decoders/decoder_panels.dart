// SPDX-License-Identifier: GPL-3.0-or-later
//
// One choice list for native v3 modes and optional data decoder previews.
import 'package:flutter/material.dart';

import 'decoder_contract.dart';
import 'adsb_panel.dart';
import 'decoder_session.dart';
import 'rds_widgets.dart';
import 'sstv_panel.dart';
import '../legacy/centered_receiver.dart';
import '../legacy/squelch_controls.dart';
import '../legacy/theme.dart';
import '../radio_controller.dart';

const _demodOptionLabels = <String, String>{
  'stereo': 'Стерео',
  'lowPass': 'Фильтр НЧ',
  'carrierAgc': 'АРУ несущей',
};

/// Everything a decoder panel may need; each panel picks its own inputs.
class DecoderPanelContext {
  const DecoderPanelContext({
    required this.descriptor,
    required this.controller,
    required this.receiver,
    required this.session,
  });
  final DecoderDescriptor descriptor;
  final RadioController controller;
  final CenteredReceiver receiver;
  final DecoderSession session;
}

typedef DecoderPanelBuilder = Widget Function(DecoderPanelContext context);

Widget _voicePanel(DecoderPanelContext c) =>
    VoiceDecoderPanel(controller: c.controller, receiver: c.receiver);

/// One panel per decoder id. Panels never share widgets: RDS/RBDS belongs
/// to the WFM panel only, data decoders show only their own results.
final Map<String, DecoderPanelBuilder> decoderPanels = {
  for (final d in decoderCatalog)
    if (d.voice && d.demodMode != DemodMode.wfm) d.id: _voicePanel,
  decoderIdForMode(DemodMode.wfm): (c) => WfmDecoderPanel(
    controller: c.controller,
    receiver: c.receiver,
    session: c.session,
  ),
  'rtl_433': (c) => Rtl433DecoderPanel(session: c.session),
  'sstv': (c) => SstvDecoderPanel(session: c.session),
  'adsb': (c) => AdsbPanel(session: c.session, receiver: c.receiver),
};

/// Exactly one panel for [selectedId]; an unknown id falls back to the
/// panel of the radio's current demodulator. The wrapper is keyed
/// `decoderPanelFor-<id>` so tests can tell which panel is mounted.
Widget buildDecoderPanel({
  required String selectedId,
  required RadioController controller,
  required CenteredReceiver receiver,
  required DecoderSession session,
}) {
  final descriptor =
      decoderById(selectedId) ??
      decoderById(decoderIdForMode(controller.mode))!;
  final builder =
      decoderPanels[descriptor.id] ??
      (descriptor.voice
          ? _voicePanel
          : (c) => DecoderPlaceholderPanel(
              descriptor: c.descriptor,
              session: c.session,
            ));
  return KeyedSubtree(
    key: ValueKey('decoderPanelFor-${descriptor.id}'),
    child: builder(
      DecoderPanelContext(
        descriptor: descriptor,
        controller: controller,
        receiver: receiver,
        session: session,
      ),
    ),
  );
}

/// Scrollable menu keeps every choice accessible on the 344dp cover screen.
class DecoderSelector extends StatelessWidget {
  const DecoderSelector({super.key, required this.session});
  final DecoderSession session;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: const ValueKey('decoderSelector'),
    tooltip: 'Декодер',
    initialValue: session.selectedId,
    onSelected: session.selectPreview,
    itemBuilder: (context) => [
      for (final d in decoderCatalog)
        PopupMenuItem<String>(
          value: d.id,
          key: ValueKey('decoderSelect-${d.id}'),
          child: Row(
            children: [
              Expanded(child: Text(d.label, style: plex(size: 14))),
              if (!session.isAvailable(d.id))
                Text(
                  'Недоступен',
                  style: plex(size: 11, color: LegacyColors.muted),
                ),
            ],
          ),
        ),
    ],
    child: legacyCard(
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: Text(
                decoderById(session.selectedId)?.label ?? '',
                style: plex(size: 16, color: LegacyColors.accent),
              ),
            ),
            const Icon(Icons.arrow_drop_down, color: LegacyColors.accent),
          ],
        ),
      ),
    ),
  );
}

/// Existing v3 bandwidth, squelch and demod options for the selected mode.
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
        _heading('ДЕМОДУЛЯТОР · ${mode.label}'),
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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

/// WFM decoder: voice controls plus RDS station details and the RBDS switch.
class WfmDecoderPanel extends StatelessWidget {
  const WfmDecoderPanel({
    super.key,
    required this.controller,
    required this.receiver,
    required this.session,
  });
  final RadioController controller;
  final CenteredReceiver receiver;
  final DecoderSession session;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      VoiceDecoderPanel(controller: controller, receiver: receiver),
      RdsDetailsPanel(session: session),
    ],
  );
}

/// Per-id icon/title/empty-state text for the data decoders
/// (decoder_contract.dart `DecoderResult`). Keyed by [DecoderDescriptor.id].
const Map<String, (IconData, String, String)> _placeholderMeta = {
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

/// Live rtl_433 FIFO messages and decoder status; the VFO remains the
/// receiver's normal frequency control, not a second decoder setting.
class Rtl433DecoderPanel extends StatelessWidget {
  const Rtl433DecoderPanel({super.key, required this.session});
  final DecoderSession session;

  @override
  Widget build(BuildContext context) {
    final messages = session.messages;
    final available = session.isAvailable('rtl_433');
    final status = !available
        ? 'Недоступен в текущей нативной сборке'
        : !session.radio.running
        ? session.radio.lastError ?? 'Приём остановлен'
        : session.failureReason ??
              (session.active ? 'Декодирование активно' : 'Декодер не запущен');
    return Column(
      key: const ValueKey('decoderPanel-rtl_433'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('rtl_433 · сообщения', style: plex(size: 14)),
              const SizedBox(height: 6),
              Text(
                session.active
                    ? '$status · ${(session.radio.tunedFrequency / 1e6).toStringAsFixed(3)} МГц · ${session.decoderRateHz} отсч./с'
                    : status,
                key: const ValueKey('rtl433Status'),
                style: plex(
                  size: 12,
                  color: session.active
                      ? LegacyColors.accent
                      : LegacyColors.muted,
                ),
              ),
              Text(
                'IQ: ${session.inputRateHz} Гц · Потеряно событий: ${session.droppedEvents}',
                key: const ValueKey('rtl433RateDrops'),
                style: plex(size: 11, color: LegacyColors.muted),
              ),
              Text(
                'Частота задаётся обычной настройкой приёмника (VFO).',
                style: plex(size: 11, color: LegacyColors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Сообщения · ${messages.length}',
                style: plex(size: 14),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('rtl433Clear'),
              onPressed: messages.isEmpty ? null : session.clearMessages,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Очистить'),
            ),
          ],
        ),
        KeyedSubtree(
          key: const ValueKey('decoderResult-rtl_433'),
          child: messages.isEmpty
              ? legacyCard(
                  child: Text(
                    'Сообщений пока нет',
                    style: plex(size: 12, color: LegacyColors.muted),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: legacyCard(
                        child: Material(
                          type: MaterialType.transparency,
                          child: ExpansionTile(
                            key: ValueKey('rtl433Message-${message.sequence}'),
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: EdgeInsets.zero,
                            title: Text(
                              message.summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: plex(size: 13),
                            ),
                            subtitle: Text(
                              '${message.receivedAt.toLocal().toIso8601String().substring(11, 19)} · #${message.sequence}',
                              style: plex(size: 11),
                            ),
                            children: [
                              SelectableText(
                                message.formattedJson,
                                key: ValueKey('rtl433Json-${message.sequence}'),
                                style: plex(mono: true, size: 11),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Honest empty-state panel for decoders without a result UI or native engine.
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

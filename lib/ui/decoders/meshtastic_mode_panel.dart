// SPDX-License-Identifier: GPL-3.0-or-later
// Meshtastic decoder panel: status, preset/region quick tune, channel keys,
// and the packet log / text messages / node list. Layout follows OpenWebRX+
// MeshtasticMessagePanel (Time · From · To · Data rows, text and data rows
// below; htdocs/lib/MessagePanel.js f1e0d1a) adapted to cards for 344 dp.
// Results come only from real native events; keys are never displayed.
import 'package:flutter/material.dart';

import '../legacy/centered_receiver.dart';
import '../legacy/step_grid.dart';
import '../legacy/theme.dart';
import 'decoder_session.dart';
import 'meshtastic_keys.dart';
import 'meshtastic_packets.dart';
import 'meshtastic_tuning.dart';

/// OpenWebRX+ `Utils.HHMMSS` (UTC).
String meshtasticHhmmss(DateTime t) {
  final u = t.toUtc();
  String p(int v) => v.toString().padLeft(2, '0');
  return '${p(u.hour)}:${p(u.minute)}:${p(u.second)}';
}

class MeshtasticModePanel extends StatefulWidget {
  const MeshtasticModePanel({
    super.key,
    required this.session,
    required this.receiver,
  });
  final DecoderSession session;
  final CenteredReceiver receiver;

  @override
  State<MeshtasticModePanel> createState() => _MeshtasticModePanelState();
}

enum _View { packets, messages, nodes }

class _MeshtasticModePanelState extends State<MeshtasticModePanel> {
  _View _view = _View.packets;

  DecoderSession get session => widget.session;

  Map<String, Object> get _settings => session.settingsFor('meshtastic');

  MeshtasticPreset get _preset =>
      meshtasticPreset(_settings['preset']! as String);

  MeshtasticRegion get _region =>
      meshtasticRegion(_settings['region']! as String);

  String get _status {
    if (!session.isAvailable('meshtastic')) {
      return 'Decoder unavailable: native LoRa PHY not installed';
    }
    if (!session.radio.running) {
      return session.radio.lastError ?? 'Reception stopped';
    }
    return session.failureReason ??
        (session.active ? 'Decoding active' : 'Decoder not running');
  }

  void _tune(MeshtasticRegion region) {
    final preset = _preset;
    final channel = meshtasticChannelFrequency(region, preset);
    session.setSetting('meshtastic', 'region', region.code);
    try {
      final tuned = tuneMeshtasticRegion(widget.receiver, region, preset);
      if (mounted && tuned != channel.frequencyHz) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Receiver step snapped ${formatMhz(channel.frequencyHz)} '
              'to ${formatMhz(tuned)} MHz',
            ),
          ),
        );
      }
    } on ArgumentError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Frequency outside receiver range')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final log = session.meshtastic;
    return Column(
      key: const ValueKey('decoderPanel-meshtastic'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _statusCard(),
        const SizedBox(height: 8),
        _tuningCard(),
        const SizedBox(height: 8),
        _keysCard(),
        const SizedBox(height: 8),
        SegmentedButton<_View>(
          key: const ValueKey('meshtasticView'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: _View.packets,
              label: Text(
                'Packets ${log.packets.length}',
                key: const ValueKey('meshtasticView-packets'),
              ),
            ),
            ButtonSegment(
              value: _View.messages,
              label: Text(
                'Text ${log.messages.length}',
                key: const ValueKey('meshtasticView-messages'),
              ),
            ),
            ButtonSegment(
              value: _View.nodes,
              label: Text(
                'Nodes ${log.nodes.length}',
                key: const ValueKey('meshtasticView-nodes'),
              ),
            ),
          ],
          selected: {_view},
          onSelectionChanged: (s) => setState(() => _view = s.first),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('meshtasticClear'),
            onPressed: log.isEmpty
                ? null
                : () => session.clearMeshtastic(nodes: _view == _View.nodes),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(_view == _View.nodes ? 'Clear nodes' : 'Clear'),
          ),
        ),
        switch (_view) {
          _View.packets => _packetList(log.packets, 'No packets yet'),
          _View.messages => _packetList(log.messages, 'No text messages yet'),
          _View.nodes => _nodeList(log.nodes),
        },
      ],
    );
  }

  Widget _statusCard() {
    final preset = _preset;
    return legacyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Meshtastic · receive only', style: plex(size: 14)),
          const SizedBox(height: 4),
          Text(
            _status,
            key: const ValueKey('meshtasticStatus'),
            style: plex(
              size: 12,
              color: session.active ? LegacyColors.accent : LegacyColors.muted,
            ),
          ),
          Text(
            '${preset.name}: BW ${preset.bandwidthHz / 1000} kHz · '
            'SF${preset.sf} · CR 4/${preset.cr} · 1 MS/s IQ required',
            key: const ValueKey('meshtasticPhy'),
            style: plex(size: 11, color: LegacyColors.muted),
          ),
          if (preset.limitation != null)
            Text(
              preset.limitation!,
              style: plex(size: 11, color: LegacyColors.danger),
            ),
          Text(
            'IQ: ${session.inputRateHz} Hz · Dropped events: '
            '${session.droppedEvents}',
            style: plex(size: 11, color: LegacyColors.muted),
          ),
          Text(
            'Level is the uncalibrated lorarx signal level, not RSSI in dBm.',
            style: plex(size: 11, color: LegacyColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _dropdown(
    String label,
    String key,
    String value,
    List<String> values,
    String Function(String) text,
  ) => Row(
    children: [
      Expanded(
        child: Text(label, style: plex(size: 12, color: LegacyColors.muted)),
      ),
      DropdownButton<String>(
        key: ValueKey('decoderSetting-meshtastic-$key'),
        value: value,
        items: [
          for (final v in values)
            DropdownMenuItem(
              value: v,
              child: Text(text(v), style: plex(size: 12)),
            ),
        ],
        onChanged: (v) {
          if (v != null) session.setSetting('meshtastic', key, v);
        },
      ),
    ],
  );

  Widget _tuningCard() {
    final preset = _preset;
    final region = _region;
    final allowed = region.presets.contains(preset.name);
    final channel = allowed ? meshtasticChannelFrequency(region, preset) : null;
    return legacyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Preset and region', style: plex(size: 14)),
          _dropdown(
            'Modem preset',
            'preset',
            preset.name,
            [for (final p in meshtasticPresets) p.name],
            (n) => meshtasticPreset(n).supported ? n : '$n (unsupported)',
          ),
          _dropdown('Region', 'region', region.code, [
            for (final r in meshtasticRegions) r.code,
          ], (c) => c),
          const SizedBox(height: 4),
          if (channel == null)
            Text(
              '${preset.name} is not a firmware preset for ${region.code}',
              key: const ValueKey('meshtasticRegionPresetInvalid'),
              style: plex(size: 12, color: LegacyColors.danger),
            )
          else
            OutlinedButton(
              key: const ValueKey('meshtasticTune'),
              onPressed: () => _tune(region),
              child: Text(
                'Tune ${region.code} · slot ${channel.slot} · '
                '${formatMhz(channel.frequencyHz)} MHz'
                '${channel.verified ? '' : ' · Unverified frequency'}',
              ),
            ),
          const SizedBox(height: 6),
          Text(
            '${preset.name} quick tune',
            style: plex(size: 12, color: LegacyColors.muted),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final code in ['EU_868', 'US', 'RU', 'KZ_863'])
                Builder(
                  builder: (context) {
                    final r = meshtasticRegion(code);
                    final ok = r.presets.contains(preset.name);
                    final c = ok ? meshtasticChannelFrequency(r, preset) : null;
                    return OutlinedButton(
                      key: ValueKey('meshtasticTune-$code'),
                      onPressed: ok ? () => _tune(r) : null,
                      child: Text(
                        c == null
                            ? '$code · n/a'
                            : '$code · ${formatMhz(c.frequencyHz)} MHz'
                                  '${c.verified ? '' : ' · Unverified frequency'}',
                      ),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Frequency is the shared receiver VFO; quick tune uses the normal '
            'tuning path. Frequencies are receive-only and do not imply '
            'legality.',
            style: plex(size: 11, color: LegacyColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _keysCard() {
    final channels = meshtasticChannels(_settings['channels']);
    return legacyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Channel keys', style: plex(size: 14))),
              TextButton.icon(
                key: const ValueKey('meshtasticAddKey'),
                onPressed: channels.length >= meshtasticMaxChannels
                    ? null
                    : () => _editChannel(channels.length),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
            ],
          ),
          Text(
            'The public default key (AQ==) is always tried. Keys are stored '
            'with presets on this device and are never shown again.',
            style: plex(size: 11, color: LegacyColors.muted),
          ),
          if (!session.isAvailable('meshtastic'))
            Text(
              'Keys take effect once the native decoder is available.',
              style: plex(size: 11, color: LegacyColors.muted),
            ),
          for (var i = 0; i < channels.length; i++)
            Row(
              key: ValueKey('meshtasticKey-$i'),
              children: [
                Expanded(
                  child: Text(
                    '${i + 1}. '
                    '${channels[i].name.isEmpty ? '${_preset.name} (preset name)' : channels[i].name}'
                    ' · ${_keyKind(channels[i].psk)}',
                    style: plex(size: 12),
                  ),
                ),
                IconButton(
                  key: ValueKey('meshtasticEditKey-$i'),
                  tooltip: 'Replace',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => _editChannel(i),
                ),
                IconButton(
                  key: ValueKey('meshtasticDeleteKey-$i'),
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => _setChannels([
                    for (var j = 0; j < channels.length; j++)
                      if (j != i) channels[j],
                  ]),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static String _keyKind(String psk) {
    try {
      return resolveMeshtasticKey(psk).kind;
    } on FormatException {
      return 'invalid key';
    }
  }

  void _setChannels(List<({String name, String psk})> channels) {
    session.setSetting('meshtastic', 'channels', [
      for (final c in channels) <String, Object>{'name': c.name, 'psk': c.psk},
    ]);
  }

  Future<void> _editChannel(int index) async {
    final channels = meshtasticChannels(_settings['channels']);
    final result = await showDialog<({String name, String psk})>(
      context: context,
      builder: (context) => _ChannelKeyDialog(
        initialName: index < channels.length ? channels[index].name : '',
      ),
    );
    if (result == null || !mounted) return;
    final next = [...channels];
    if (index < next.length) {
      next[index] = result;
    } else {
      next.add(result);
    }
    _setChannels(next);
  }

  Widget _packetList(List<MeshtasticPacket> packets, String empty) {
    if (packets.isEmpty) {
      return legacyCard(
        child: Text(
          empty,
          key: const ValueKey('meshtasticEmpty'),
          style: plex(size: 12, color: LegacyColors.muted),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('meshtasticPackets'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: packets.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: legacyCard(child: _packetTile(packets[i])),
      ),
    );
  }

  Widget _packetTile(MeshtasticPacket p) {
    final freq = p.frequencyHz;
    final meta = [
      if (freq != null) '${formatMhz(freq)} MHz',
      if (p.phySummary.isNotEmpty) p.phySummary,
      if (p.signalSummary.isNotEmpty) p.signalSummary,
    ].join(' · ');
    return Material(
      type: MaterialType.transparency,
      child: ExpansionTile(
        key: ValueKey('meshtasticPacket-${p.sequence}'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text(
          '${meshtasticHhmmss(p.time)}  ${p.from} → ${p.to}  ${p.headline}',
          style: plex(
            size: 13,
            color: p.encrypted ? LegacyColors.muted : LegacyColors.primary,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p.text != null && !p.encrypted)
              Text(
                p.text!,
                key: ValueKey('meshtasticText-${p.sequence}'),
                style: plex(size: 13, color: LegacyColors.accent),
              ),
            if (meta.isNotEmpty) Text(meta, style: plex(size: 11)),
            if (p.headerSummary.isNotEmpty)
              Text(
                p.headerSummary,
                style: plex(size: 11, color: LegacyColors.muted),
              ),
          ],
        ),
        children: [
          for (final (k, v) in p.dataRows)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(k, style: plex(size: 11, color: LegacyColors.muted)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      v,
                      textAlign: TextAlign.right,
                      style: plex(mono: true, size: 11),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          SelectableText(
            p.formattedJson,
            key: ValueKey('meshtasticJson-${p.sequence}'),
            style: plex(mono: true, size: 11),
          ),
        ],
      ),
    );
  }

  Widget _nodeList(List<MeshtasticNode> nodes) {
    if (nodes.isEmpty) {
      return legacyCard(
        child: Text(
          'No nodes heard yet',
          key: const ValueKey('meshtasticEmpty'),
          style: plex(size: 12, color: LegacyColors.muted),
        ),
      );
    }
    return Column(
      key: const ValueKey('meshtasticNodes'),
      children: [
        for (final n in nodes)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: legacyCard(
              child: Column(
                key: ValueKey('meshtasticNode-${n.id}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      n.label,
                      ?n.longName,
                      if (n.shortName != null) n.id,
                    ].join(' · '),
                    style: plex(size: 13),
                  ),
                  Text(
                    [
                      'heard ${meshtasticHhmmss(n.lastHeard)} UTC',
                      '${n.packets} pkt',
                      if (n.snr != null) 'SNR ${n.snr!.toStringAsFixed(1)} dB',
                      if (n.batteryLevel != null) 'battery ${n.batteryLevel}%',
                      if (n.voltage != null)
                        '${n.voltage!.toStringAsFixed(2)} V',
                    ].join(' · '),
                    style: plex(size: 11, color: LegacyColors.muted),
                  ),
                  if (n.hwModel != null || n.role != null || n.lat != null)
                    Text(
                      [
                        ?n.hwModel,
                        ?n.role,
                        if (n.lat != null && n.lon != null)
                          '${n.lat!.toStringAsFixed(5)}, '
                              '${n.lon!.toStringAsFixed(5)}'
                              '${n.altitude != null ? ' · ${n.altitude} m' : ''}',
                      ].join(' · '),
                      style: plex(size: 11, color: LegacyColors.muted),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Name + PSK entry. The key field is obscured, never pre-filled, and
/// validated with the native rules; errors never repeat the key text.
class _ChannelKeyDialog extends StatefulWidget {
  const _ChannelKeyDialog({required this.initialName});
  final String initialName;

  @override
  State<_ChannelKeyDialog> createState() => _ChannelKeyDialogState();
}

class _ChannelKeyDialogState extends State<_ChannelKeyDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  final _psk = TextEditingController();
  String? _nameError, _pskError;

  @override
  void dispose() {
    _name.dispose();
    _psk.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final psk = _psk.text.trim();
    setState(() {
      _nameError = meshtasticChannelNameError(name);
      _pskError = meshtasticKeyError(psk);
    });
    if (_nameError == null && _pskError == null) {
      Navigator.pop(context, (name: name, psk: psk));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Channel key'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('meshtasticKeyName'),
          controller: _name,
          decoration: InputDecoration(
            labelText: 'Channel name (empty = preset name)',
            errorText: _nameError,
          ),
        ),
        TextField(
          key: const ValueKey('meshtasticKeyPsk'),
          controller: _psk,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          decoration: InputDecoration(
            labelText: 'PSK (base64, hex, or default)',
            errorText: _pskError,
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('meshtasticKeySave'),
        onPressed: _save,
        child: const Text('Save'),
      ),
    ],
  );
}

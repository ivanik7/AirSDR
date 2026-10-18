// SPDX-License-Identifier: GPL-3.0-or-later
// Receive-only MeshCore panel; no second receiver or synthetic packets.
import 'package:flutter/material.dart';

import '../legacy/centered_receiver.dart';
import '../legacy/theme.dart';
import 'decoder_session.dart';
import 'meshcore_keys.dart';
import 'meshcore_packets.dart';

enum _View { packets, messages, nodes }

class MeshcoreModePanel extends StatefulWidget {
  const MeshcoreModePanel({
    super.key,
    required this.session,
    required this.receiver,
  });
  final DecoderSession session;
  final CenteredReceiver receiver;
  @override
  State<MeshcoreModePanel> createState() => _MeshcoreModePanelState();
}

class _MeshcoreModePanelState extends State<MeshcoreModePanel> {
  _View _view = _View.packets;
  DecoderSession get session => widget.session;
  List<({String name, String secret})> get _channels =>
      meshcoreChannels(session.settingsFor('meshcore')['channels']);

  void _saveChannels(List<({String name, String secret})> channels) =>
      session.setSetting('meshcore', 'channels', [
        for (final c in channels) {'name': c.name, 'secret': c.secret},
      ]);

  Future<void> _edit(int index) async {
    final old = _channels;
    final next = await showDialog<({String name, String secret})>(
      context: context,
      builder: (_) => _ChannelDialog(
        initialName: index < old.length ? old[index].name : '',
        existingNames: [
          for (var i = 0; i < old.length; i++)
            if (i != index) old[i].name,
        ],
      ),
    );
    if (next == null || !mounted) return;
    final updated = [...old];
    if (index < updated.length) {
      updated[index] = next;
    } else {
      updated.add(next);
    }
    _saveChannels(updated);
  }

  void _tune() {
    try {
      widget.receiver.tune(869618000);
      final tuned = widget.receiver.radio.tunedFrequency.round();
      if (tuned != 869618000 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Receiver step snapped 869.618 to '
              '${(tuned / 1e6).toStringAsFixed(6)} MHz',
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
    final log = session.meshcore;
    final channels = _channels;
    final available = session.isAvailable('meshcore');
    final status = !available
        ? 'Unavailable in the current native build'
        : !session.radio.running
        ? 'Reception stopped'
        : session.failureReason ??
              (session.active ? 'Decoding active' : 'Decoder not running');
    return Column(
      key: const ValueKey('decoderPanel-meshcore'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('MeshCore · receive only', style: plex(size: 14)),
              Text(
                status,
                key: const ValueKey('meshcoreStatus'),
                style: plex(
                  size: 12,
                  color: session.active
                      ? LegacyColors.accent
                      : LegacyColors.muted,
                ),
              ),
              Text(
                'SF7/8 · explicit CR5–8 · 1 MS/s IQ required',
                style: plex(size: 11, color: LegacyColors.muted),
              ),
              Text(
                'Level is relative; not calibrated RSSI in dBm. '
                'Dropped events: ${session.droppedEvents}',
                style: plex(size: 11, color: LegacyColors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('LoRa bandwidth', style: plex(size: 14)),
              DropdownButton<String>(
                key: const ValueKey('decoderSetting-meshcore-bandwidth'),
                isExpanded: true,
                value: session.settingsFor('meshcore')['bandwidth'] as String,
                items: const [
                  DropdownMenuItem(value: '6', child: Text('6 · 62.5 kHz')),
                  DropdownMenuItem(value: '7', child: Text('7 · 125 kHz')),
                  DropdownMenuItem(value: '8', child: Text('8 · 250 kHz')),
                  DropdownMenuItem(value: '9', child: Text('9 · 500 kHz')),
                ],
                onChanged: (v) {
                  if (v != null) session.setSetting('meshcore', 'bandwidth', v);
                },
              ),
              OutlinedButton(
                key: const ValueKey('meshcoreTune'),
                onPressed: _tune,
                child: const Text('Tune EU/UK suggestion · 869.618 MHz'),
              ),
              Text(
                'Suggested MeshCore EU/UK narrow: SF8, BW 62.5 kHz, CR 4/8. '
                'Receive-only; check local regulations. No KZ suitability claim. '
                'Quick tune uses the shared VFO grid and does not change bandwidth.',
                style: plex(size: 11, color: LegacyColors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Private channels', style: plex(size: 14)),
                  ),
                  TextButton.icon(
                    key: const ValueKey('meshcoreAddKey'),
                    onPressed: channels.length >= meshcoreMaxChannels
                        ? null
                        : () => _edit(channels.length),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                  ),
                ],
              ),
              Text(
                'The published public channel is always included. '
                'Private secrets are saved with presets, never shown again.',
                style: plex(size: 11, color: LegacyColors.muted),
              ),
              for (var i = 0; i < channels.length; i++)
                Row(
                  key: ValueKey('meshcoreKey-$i'),
                  children: [
                    Expanded(
                      child: Text(
                        '${channels[i].name} · private key',
                        style: plex(size: 12),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      key: ValueKey('meshcoreEditKey-$i'),
                      tooltip: 'Replace',
                      onPressed: () => _edit(i),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                    ),
                    IconButton(
                      key: ValueKey('meshcoreDeleteKey-$i'),
                      tooltip: 'Delete',
                      onPressed: () => _saveChannels([
                        for (var j = 0; j < channels.length; j++)
                          if (j != i) channels[j],
                      ]),
                      icon: const Icon(Icons.delete_outline, size: 18),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<_View>(
          key: const ValueKey('meshcoreView'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: _View.packets,
              label: Text('Packets ${log.packets.length}'),
            ),
            ButtonSegment(
              value: _View.messages,
              label: Text('Text ${log.messages.length}'),
            ),
            ButtonSegment(
              value: _View.nodes,
              label: Text('Nodes ${log.nodes.length}'),
            ),
          ],
          selected: {_view},
          onSelectionChanged: (v) => setState(() => _view = v.first),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('meshcoreClear'),
            onPressed: log.isEmpty
                ? null
                : () => session.clearMeshcore(nodes: _view == _View.nodes),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(_view == _View.nodes ? 'Clear nodes' : 'Clear'),
          ),
        ),
        if (_view == _View.nodes)
          if (log.nodes.isEmpty)
            legacyCard(child: const Text('No verified nodes yet'))
          else
            for (final node in log.nodes)
              legacyCard(
                child: Text(
                  '${node.name ?? 'Unnamed'} · ${node.publicKey}',
                  key: ValueKey('meshcoreNode-${node.publicKey}'),
                  style: plex(size: 12),
                  softWrap: true,
                ),
              )
        else if ((_view == _View.messages ? log.messages : log.packets).isEmpty)
          legacyCard(
            child: Text(
              _view == _View.messages
                  ? 'No verified group text yet'
                  : 'No packets yet',
            ),
          )
        else
          for (final packet
              in _view == _View.messages ? log.messages : log.packets)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: legacyCard(child: _tile(packet)),
            ),
      ],
    );
  }

  Widget _tile(MeshcorePacket packet) => Material(
    type: MaterialType.transparency,
    child: ExpansionTile(
      key: ValueKey('meshcorePacket-${packet.sequence}'),
      tilePadding: EdgeInsets.zero,
      title: Text(packet.headline, style: plex(size: 13)),
      subtitle: Text(
        [
          packet.time.toIso8601String(),
          if (packet.frequencyHz != null)
            '${(packet.frequencyHz! / 1e6).toStringAsFixed(6)} MHz',
          if (packet.text != null) packet.text!,
        ].join(' · '),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: plex(size: 11),
      ),
      children: [
        SelectableText(
          packet.formattedJson,
          key: ValueKey('meshcoreJson-${packet.sequence}'),
          style: plex(mono: true, size: 11),
        ),
      ],
    ),
  );
}

class _ChannelDialog extends StatefulWidget {
  const _ChannelDialog({
    required this.initialName,
    required this.existingNames,
  });
  final String initialName;
  final List<String> existingNames;
  @override
  State<_ChannelDialog> createState() => _ChannelDialogState();
}

class _ChannelDialogState extends State<_ChannelDialog> {
  late final name = TextEditingController(text: widget.initialName);
  final secret = TextEditingController();
  String? nameError, secretError;
  @override
  void dispose() {
    name.dispose();
    secret.dispose();
    super.dispose();
  }

  void _save() {
    final n = name.text.trim();
    final s = secret.text.trim();
    setState(() {
      nameError =
          meshcoreChannelNameError(n) ??
          (widget.existingNames.contains(n)
              ? 'Channel name already in use'
              : null);
      secretError = meshcoreSecretError(s);
    });
    if (nameError == null && secretError == null) {
      Navigator.pop(context, (name: n, secret: s));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Private channel'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('meshcoreKeyName'),
          controller: name,
          decoration: InputDecoration(labelText: 'Name', errorText: nameError),
        ),
        TextField(
          key: const ValueKey('meshcoreKeySecret'),
          controller: secret,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          decoration: InputDecoration(
            labelText: 'Hex secret (32 or 64 digits)',
            errorText: secretError,
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
        key: const ValueKey('meshcoreKeySave'),
        onPressed: _save,
        child: const Text('Save'),
      ),
    ],
  );
}

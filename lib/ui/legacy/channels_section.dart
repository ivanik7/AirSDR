// SPDX-License-Identifier: GPL-3.0-or-later
//
// "КАНАЛЫ" block of the Приём tab (layout from the old UI's _ChannelsSection:
// 2-column tile grid + "+ канал" tile + long-press menu), but honest about the
// single receiver: exactly one slot is active and only it shows a (real) level.
import 'package:flutter/material.dart';

import '../channels/channel_controller.dart';
import '../channels/channels.dart';
import '../channels/signal_meter.dart';
import '../radio_controller.dart';
import 'step_grid.dart';
import 'theme.dart';

class ChannelsSection extends StatefulWidget {
  const ChannelsSection({
    super.key,
    required this.controller,
    required this.radio,
    required this.meter,
  });
  final ChannelController controller;
  final RadioController radio;
  final SignalMeter meter;

  /// Tiles shown while collapsed (old UI: `collapsedChannels` = 4).
  static const collapsedTiles = 4;

  @override
  State<ChannelsSection> createState() => _ChannelsSectionState();
}

class _ChannelsSectionState extends State<ChannelsSection> {
  bool expanded = false;
  String? message;

  ChannelsRepository get repo => widget.controller.channels;

  void _select(ReceiverChannel c) {
    final ok = widget.controller.select(c.id);
    setState(
      () => message = ok ? null : 'Частота канала вне диапазона устройства',
    );
  }

  void _add() {
    widget.controller.add();
    setState(() => message = null);
  }

  Future<void> _menu(ReceiverChannel c, Offset position) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      color: LegacyColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: [
        _item('rename', Icons.edit_outlined, 'Переименовать'),
        _item('preset', Icons.bookmark_add_outlined, 'Сохранить как пресет'),
        _item(
          'delete',
          Icons.delete_outline,
          'Удалить',
          color: LegacyColors.danger,
        ),
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case 'rename':
        await _rename(c);
      case 'preset':
        final error = widget.controller.saveAsPreset(c.id);
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                error == null
                    ? 'Сохранено как пресет'
                    : 'Не удалось сохранить: $error',
              ),
            ),
          );
      case 'delete':
        await _confirmDelete(c);
    }
  }

  PopupMenuItem<String> _item(
    String value,
    IconData icon,
    String text, {
    Color color = LegacyColors.primary,
  }) => PopupMenuItem(
    key: ValueKey('channelMenu-$value'),
    value: value,
    child: Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: color == LegacyColors.primary ? LegacyColors.accent : color,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: plex(size: 14, color: color),
          ),
        ),
      ],
    ),
  );

  Future<void> _rename(ReceiverChannel c) async {
    var name = c.name;
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Переименовать канал'),
          content: TextFormField(
            key: const ValueKey('channelName'),
            initialValue: name,
            autofocus: true,
            maxLength: ChannelsRepository.maxNameLength,
            onChanged: (v) => name = v,
            decoration: InputDecoration(errorText: error),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const ValueKey('channelNameSave'),
              onPressed: () {
                if (name.trim().isEmpty) {
                  update(() => error = 'введите название');
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && repo.indexOf(c.id) >= 0) {
      widget.controller.rename(c.id, name);
    }
  }

  Future<void> _confirmDelete(ReceiverChannel c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить канал?'),
        content: Text('${c.name} · ${formatMhz(c.frequencyHz)} MHz'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const ValueKey('channelDeleteConfirm'),
            style: FilledButton.styleFrom(backgroundColor: LegacyColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true && repo.indexOf(c.id) >= 0) {
      widget.controller.delete(c.id);
      setState(() => message = null);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: repo,
    builder: (context, _) {
      final all = repo.channels;
      final more = all.length > ChannelsSection.collapsedTiles;
      final activeIndex = repo.activeId == null
          ? -1
          : repo.indexOf(repo.activeId!);
      final visible = expanded || !more
          ? all
          : [
              ...all.take(ChannelsSection.collapsedTiles - 1),
              // Keep the one live receiver visible even when its slot is
              // beyond the collapsed portion of the ordered list.
              all[activeIndex >= ChannelsSection.collapsedTiles
                  ? activeIndex
                  : ChannelsSection.collapsedTiles - 1],
            ];
      final showAdd = expanded || all.length < ChannelsSection.collapsedTiles;
      return Column(
        key: const ValueKey('channelsSection'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'КАНАЛЫ · ${all.length}',
                  key: const ValueKey('channelsHeader'),
                  overflow: TextOverflow.ellipsis,
                  style: plex(size: 12, color: LegacyColors.muted),
                ),
              ),
              if (more)
                GestureDetector(
                  key: const ValueKey('channelsExpand'),
                  onTap: () => setState(() => expanded = !expanded),
                  child: Text(
                    expanded ? 'Свернуть ▲' : 'Все каналы (${all.length}) ▼',
                    style: plex(size: 12, color: LegacyColors.accent),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 7),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.7,
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final c in visible)
                _ChannelTile(
                  key: ValueKey('channel-${c.id}'),
                  channel: c,
                  active: c.id == repo.activeId,
                  radio: widget.radio,
                  meter: widget.meter,
                  onTap: () => _select(c),
                  onMenu: (pos) => _menu(c, pos),
                  onDropped: (draggedId) =>
                      widget.controller.move(draggedId, repo.indexOf(c.id)),
                ),
              if (showAdd)
                DragTarget<String>(
                  onAcceptWithDetails: (d) =>
                      widget.controller.move(d.data, repo.length - 1),
                  builder: (context, candidates, _) => Material(
                    color: candidates.isEmpty
                        ? const Color(0xFF12161A)
                        : LegacyColors.key,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      key: const ValueKey('channelAdd'),
                      borderRadius: BorderRadius.circular(14),
                      onTap: _add,
                      child: Center(
                        child: Text(
                          '+ канал',
                          style: plex(size: 13, color: LegacyColors.accent),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                message!,
                style: plex(size: 12, color: LegacyColors.danger),
              ),
            ),
        ],
      );
    },
  );
}

class _ChannelTile extends StatefulWidget {
  const _ChannelTile({
    super.key,
    required this.channel,
    required this.active,
    required this.radio,
    required this.meter,
    required this.onTap,
    required this.onMenu,
    required this.onDropped,
  });
  final ReceiverChannel channel;
  final bool active;
  final RadioController radio;
  final SignalMeter meter;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onMenu;
  final void Function(String draggedId) onDropped;

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  Offset _down = Offset.zero;
  double _moved = 0;
  bool _dropped = false;

  /// Below this finger travel a long press is a "menu" press, not a move.
  static const _moveSlop = 18.0;

  void _dragEnded() {
    if (!_dropped && _moved < _moveSlop) widget.onMenu(_down);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.channel;
    return Listener(
      onPointerDown: (e) => _down = e.position,
      child: DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != c.id,
        onAcceptWithDetails: (d) => widget.onDropped(d.data),
        builder: (context, candidates, _) => LayoutBuilder(
          builder: (context, box) => LongPressDraggable<String>(
            data: c.id,
            hapticFeedbackOnStart: true,
            onDragStarted: () {
              _moved = 0;
              _dropped = false;
            },
            onDragUpdate: (d) => _moved += d.delta.distance,
            onDragCompleted: () => _dropped = true,
            onDragEnd: (_) => _dragEnded(),
            feedback: Material(
              color: Colors.transparent,
              child: SizedBox(
                width: box.maxWidth,
                height: box.maxHeight,
                child: Opacity(opacity: 0.85, child: _body(highlight: true)),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: _body()),
            child: GestureDetector(
              onTap: widget.onTap,
              child: _body(target: candidates.isNotEmpty),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body({bool highlight = false, bool target = false}) {
    final c = widget.channel;
    final active = widget.active;
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF1A2114) : LegacyColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: target
              ? LegacyColors.primary
              : active || highlight
              ? LegacyColors.accent
              : Colors.transparent,
          width: active ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    formatMhz(c.frequencyHz),
                    maxLines: 1,
                    style: plex(
                      size: 15,
                      mono: true,
                      color: active
                          ? LegacyColors.primary
                          : const Color(0xFFA6A29A),
                    ),
                  ),
                ),
              ),
              if (active) _Led(radio: widget.radio),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: plex(size: 11, color: LegacyColors.muted),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                c.mode.label,
                style: plex(
                  size: 10,
                  mono: true,
                  color: active ? LegacyColors.accent : LegacyColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Level only for the channel actually being received.
          SizedBox(
            height: 4,
            child: active
                ? _LevelBar(meter: widget.meter)
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// On while the receiver is running on this (active) channel.
class _Led extends StatelessWidget {
  const _Led({required this.radio});
  final RadioController radio;
  @override
  Widget build(BuildContext context) {
    final on = radio.running;
    return Container(
      key: const ValueKey('channelLed'),
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: on ? LegacyColors.accent : const Color(0xFF2A3037),
        shape: BoxShape.circle,
        boxShadow: on
            ? [
                BoxShadow(
                  color: LegacyColors.accent.withValues(alpha: 0.75),
                  blurRadius: 8,
                ),
              ]
            : null,
      ),
    );
  }
}

/// SNR of the tuned channel (SDR++ SNR meter scale: 0…90 dB).
class _LevelBar extends StatelessWidget {
  const _LevelBar({required this.meter});
  final SignalMeter meter;
  static const fullScaleDb = 60.0;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SignalInfo?>(
    valueListenable: meter,
    builder: (context, info, _) {
      final fraction = info == null
          ? 0.0
          : (info.snrDb / fullScaleDb).clamp(0.0, 1.0);
      return ClipRRect(
        key: const ValueKey('channelLevel'),
        borderRadius: BorderRadius.circular(2),
        child: Container(
          color: const Color(0xFF1C2126),
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: fraction,
            child: Container(color: LegacyColors.accent),
          ),
        ),
      );
    },
  );
}

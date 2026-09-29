// SPDX-License-Identifier: GPL-3.0-or-later
//
// "КАНАЛЫ" block of the Приём tab (tiles + "+ канал" + long-press menu from
// the old UI's _ChannelsSection), but honest about the single receiver:
// exactly one slot is active and only it shows a (real) level.
//
// Layout: a header and ONE horizontally scrolling row of fixed-size tiles.
// The block height never depends on the number of channels, so the Приём
// tab needs no vertical scrolling. The active channel (and the one the
// scanner is tuned to) is scrolled into view automatically; a tile dragged
// to the row edge scrolls the row, so it can be dropped anywhere.
//
// Channels have no own names: a tile shows the preset name at exactly the
// same frequency, else "<mode> <MHz>" ([ChannelController.displayName]).
import 'dart:async';

import 'package:flutter/material.dart';

import '../channels/channel_controller.dart';
import '../channels/channel_scanner.dart';
import '../channels/channels.dart';
import '../channels/signal_meter.dart';
import '../radio_controller.dart';
import 'step_grid.dart';
import 'theme.dart';

class ChannelsSection extends StatefulWidget {
  const ChannelsSection({
    super.key,
    required this.controller,
    required this.scanner,
    required this.radio,
    required this.meter,
  });
  final ChannelController controller;
  final ChannelScanner scanner;
  final RadioController radio;
  final SignalMeter meter;

  static const tileGap = 4.0;

  /// Tile width for a row of [rowWidth]: about 2.5 tiles are visible, so a
  /// cut-off tile hints that the row scrolls.
  static double tileWidthFor(double rowWidth) =>
      ((rowWidth - 2 * tileGap) / 2.5).clamp(104.0, 160.0);

  @override
  State<ChannelsSection> createState() => _ChannelsSectionState();
}

class _ChannelsSectionState extends State<ChannelsSection> {
  final _scroll = ScrollController();
  final _rowKey = GlobalKey();
  double _tileWidth = 120;
  String? _shownKey;

  // Auto-scroll while a tile is dragged near the row edge.
  bool _dragging = false;
  Offset? _pointer;
  Timer? _edgeTimer;
  static const _edgeZone = 36.0;
  static const _edgeSpeed = 9.0; // logical px per 16 ms tick

  ChannelsRepository get repo => widget.controller.channels;

  @override
  void dispose() {
    _edgeTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _select(ReceiverChannel c) {
    final ok = widget.controller.select(c.id);
    if (!ok) _snack('Частота канала вне диапазона устройства');
  }

  void _snack(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

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
      case 'preset':
        await _saveAsPreset(c);
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

  /// Asks for the preset name (prefilled with the channel's shown name).
  Future<void> _saveAsPreset(ReceiverChannel c) async {
    var name = widget.controller.displayName(c);
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Сохранить как пресет'),
          content: TextFormField(
            key: const ValueKey('presetName'),
            initialValue: name,
            autofocus: true,
            maxLength: 60,
            onChanged: (v) => name = v,
            decoration: InputDecoration(
              labelText: 'Название',
              helperText: '${formatMhz(c.frequencyHz)} MHz · ${c.mode.label}',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const ValueKey('presetNameSave'),
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
    if (ok != true || !mounted) return;
    final saveError = widget.controller.saveAsPreset(c.id, name: name.trim());
    _snack(
      saveError == null
          ? 'Сохранено как пресет'
          : 'Не удалось сохранить: $saveError',
    );
  }

  Future<void> _confirmDelete(ReceiverChannel c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить канал?'),
        content: Text(
          '${widget.controller.displayName(c)} · '
          '${formatMhz(c.frequencyHz)} MHz',
        ),
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
    }
  }

  /// Channel whose tile must be visible: the one the scanner is tuned to,
  /// else the active one.
  String? get _focusId => widget.scanner.active
      ? (widget.scanner.tunedChannelId ?? repo.activeId)
      : repo.activeId;

  void _scheduleReveal() {
    final id = _focusId;
    final key = '$id/${repo.indexOf(id ?? '')}/${repo.length}/$_tileWidth';
    if (key == _shownKey || _dragging) return;
    _shownKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(id));
  }

  void _reveal(String? id) {
    if (!mounted || id == null || !_scroll.hasClients) return;
    final i = repo.indexOf(id);
    if (i < 0) return;
    final p = _scroll.position;
    final left = i * (_tileWidth + ChannelsSection.tileGap);
    final right = left + _tileWidth;
    double? target;
    if (left < p.pixels) {
      target = left;
    } else if (right > p.pixels + p.viewportDimension) {
      target = right - p.viewportDimension;
    }
    if (target == null) return;
    _scroll.animateTo(
      target.clamp(p.minScrollExtent, p.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _dragStarted() {
    _dragging = true;
    _edgeTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _edgeTick(),
    );
  }

  void _dragStopped() {
    _dragging = false;
    _pointer = null;
    _edgeTimer?.cancel();
    _edgeTimer = null;
  }

  void _edgeTick() {
    final box = _rowKey.currentContext?.findRenderObject() as RenderBox?;
    final at = _pointer;
    if (!_dragging || box == null || at == null || !_scroll.hasClients) return;
    final x = box.globalToLocal(at).dx;
    final w = box.size.width;
    double delta = 0;
    if (x < _edgeZone) {
      delta = -_edgeSpeed * ((_edgeZone - x) / _edgeZone).clamp(0.3, 1.0);
    } else if (x > w - _edgeZone) {
      delta = _edgeSpeed * ((x - (w - _edgeZone)) / _edgeZone).clamp(0.3, 1.0);
    }
    if (delta == 0) return;
    final p = _scroll.position;
    final to = (p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (to != p.pixels) _scroll.jumpTo(to);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      repo,
      widget.scanner,
      widget.controller.favorites,
    ]),
    builder: (context, _) {
      final all = repo.channels;
      final scaler = MediaQuery.textScalerOf(context);
      // Fixed by text scale only — never by the number of channels.
      // Tile: 15 pt MHz + 11 pt name lines (scaled) + level bar, gaps,
      // padding and the active border (fixed).
      final rowHeight = scaler.scale(38) + 18;
      final receivingId = widget.scanner.receivingChannelId;
      final receiving = receivingId == null
          ? null
          : all.where((c) => c.id == receivingId).firstOrNull;
      return Column(
        key: const ValueKey('channelsSection'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 34,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    'КАНАЛЫ · ${all.length}',
                    key: const ValueKey('channelsHeader'),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: plex(size: 12, color: LegacyColors.muted),
                  ),
                ),
                const SizedBox(width: 6),
                if (widget.scanner.active)
                  Expanded(
                    flex: 2,
                    child: Text(
                      receiving == null
                          ? 'Скан…'
                          : 'Приём: ${widget.controller.displayName(receiving)}',
                      key: const ValueKey('channelScanStatus'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: plex(size: 11, color: LegacyColors.accent),
                    ),
                  )
                else
                  const Spacer(),
                TextButton(
                  key: const ValueKey('channelAdd'),
                  onPressed: widget.controller.add,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(48, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    '+ канал',
                    style: plex(size: 12, color: LegacyColors.accent),
                  ),
                ),
                Tooltip(
                  message: widget.scanner.canStart || widget.scanner.active
                      ? 'Последовательный приём каналов'
                      : !widget.radio.running
                      ? 'Сначала включите приёмник'
                      : 'Выберите канал с авто-шумодавом; нужно минимум два (без WFM/RAW)',
                  child: TextButton(
                    key: const ValueKey('channelScanToggle'),
                    onPressed: widget.scanner.active
                        ? () => widget.scanner.stop()
                        : widget.scanner.canStart
                        ? () => widget.scanner.start()
                        : null,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      minimumSize: const Size(48, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      widget.scanner.active ? 'Стоп скан' : 'Скан',
                      style: plex(size: 12, color: LegacyColors.accent),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            key: _rowKey,
            height: rowHeight,
            child: LayoutBuilder(
              builder: (context, box) {
                _tileWidth = ChannelsSection.tileWidthFor(box.maxWidth);
                _scheduleReveal();
                return Listener(
                  onPointerMove: (e) {
                    if (_dragging) _pointer = e.position;
                  },
                  onPointerUp: (_) => _dragStopped(),
                  onPointerCancel: (_) => _dragStopped(),
                  child: all.isEmpty
                      ? Center(
                          child: Text(
                            'Нет каналов — «+ канал» добавит текущую частоту',
                            key: const ValueKey('channelsRow'),
                            textAlign: TextAlign.center,
                            style: plex(size: 11, color: LegacyColors.muted),
                          ),
                        )
                      : SingleChildScrollView(
                          key: const ValueKey('channelsRow'),
                          controller: _scroll,
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final (i, c) in all.indexed) ...[
                                if (i > 0)
                                  const SizedBox(
                                    width: ChannelsSection.tileGap,
                                  ),
                                SizedBox(
                                  width: _tileWidth,
                                  height: rowHeight,
                                  child: _ChannelTile(
                                    key: ValueKey('channel-${c.id}'),
                                    channel: c,
                                    name: widget.controller.displayName(c),
                                    active: c.id == repo.activeId,
                                    tuned: widget.scanner.active
                                        ? c.id == widget.scanner.tunedChannelId
                                        : c.id == repo.activeId,
                                    receiving: c.id == receivingId,
                                    scanning: widget.scanner.active,
                                    radio: widget.radio,
                                    meter: widget.meter,
                                    onTap: () => _select(c),
                                    onMenu: (pos) => _menu(c, pos),
                                    onDragStarted: _dragStarted,
                                    onDragFinished: _dragStopped,
                                    onDropped: (draggedId) => widget.controller
                                        .move(draggedId, repo.indexOf(c.id)),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                );
              },
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
    required this.name,
    required this.active,
    required this.tuned,
    required this.receiving,
    required this.scanning,
    required this.radio,
    required this.meter,
    required this.onTap,
    required this.onMenu,
    required this.onDragStarted,
    required this.onDragFinished,
    required this.onDropped,
  });
  final ReceiverChannel channel;
  final String name;
  final bool active;
  final bool tuned;
  final bool receiving;
  final bool scanning;
  final RadioController radio;
  final SignalMeter meter;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onMenu;
  final VoidCallback onDragStarted;
  final VoidCallback onDragFinished;
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
    widget.onDragFinished();
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
              widget.onDragStarted();
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
    final receiving = widget.receiving;
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 3, 7, 3),
      decoration: BoxDecoration(
        color: receiving
            ? const Color(0xFF34491B)
            : active
            ? const Color(0xFF1A2114)
            : LegacyColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: target
              ? LegacyColors.primary
              : receiving || active || highlight
              ? LegacyColors.accent
              : Colors.transparent,
          width: receiving || active ? 1.5 : 1,
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
              if (widget.tuned)
                _Led(
                  radio: widget.radio,
                  receiving: receiving,
                  on: !widget.scanning || receiving,
                ),
            ],
          ),
          const SizedBox(height: 1),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.name,
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
              if (widget.scanning && c.mode.params.autoSquelch == null)
                const Tooltip(
                  message: 'Не сканируется: нет авто-шумодава',
                  child: Padding(
                    padding: EdgeInsets.only(left: 3),
                    child: Icon(
                      Icons.block,
                      size: 12,
                      color: LegacyColors.muted,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          // Level only for the channel actually being received.
          SizedBox(
            height: 4,
            child: widget.tuned
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
  const _Led({required this.radio, required this.receiving, required this.on});
  final RadioController radio;
  final bool receiving;
  final bool on;
  @override
  Widget build(BuildContext context) {
    final lit = on && radio.running;
    return Container(
      key: const ValueKey('channelLed'),
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: lit
            ? (receiving ? LegacyColors.primary : LegacyColors.accent)
            : const Color(0xFF2A3037),
        shape: BoxShape.circle,
        boxShadow: lit
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

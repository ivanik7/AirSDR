// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../favorites/favorites.dart';
import '../radio_controller.dart';
import 'centered_receiver.dart';
import 'theme.dart';

class PresetsScreen extends StatefulWidget {
  const PresetsScreen({
    super.key,
    required this.controller,
    required this.receiver,
    required this.favorites,
    required this.onApplied,
  });
  final RadioController controller;
  final CenteredReceiver receiver;
  final FavoritesRepository favorites;
  final VoidCallback onApplied;
  @override
  State<PresetsScreen> createState() => _PresetsScreenState();
}

class _PresetsScreenState extends State<PresetsScreen> {
  String category = 'Все';
  String? message;
  Future<void> edit([Favorite? existing]) async {
    var name = existing?.name ?? '';
    var mode = existing?.mode ?? widget.controller.mode;
    var band = existing?.category ?? 'FM';
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(existing == null ? 'Добавить пресет' : 'Изменить пресет'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Частота ${(widget.controller.tunedFrequency / 1000000).toStringAsFixed(3)} MHz',
                  style: plex(mono: true),
                ),
                TextFormField(
                  key: const ValueKey('favoriteName'),
                  initialValue: name,
                  onChanged: (value) => name = value,
                  maxLength: 60,
                  decoration: const InputDecoration(labelText: 'Название'),
                ),
                DropdownButton<DemodMode>(
                  value: mode,
                  items: [
                    for (final m in DemodMode.values)
                      DropdownMenuItem(value: m, child: Text(m.label)),
                  ],
                  onChanged: (m) {
                    if (m != null) update(() => mode = m);
                  },
                ),
                DropdownButton<String>(
                  value: band,
                  items: [
                    for (final b in favoriteCategories.skip(1))
                      DropdownMenuItem(value: b, child: Text(b)),
                  ],
                  onChanged: (b) {
                    if (b != null) update(() => band = b);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const ValueKey('favoriteSave'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result == true) {
      try {
        if (existing == null) {
          widget.favorites.add(
            frequencyHz: widget.controller.tunedFrequency.round(),
            name: name,
            mode: mode,
            category: band,
            minHz: (widget.controller.selectedDevice?.minFrequency ?? 1)
                .round(),
            maxHz:
                (widget.controller.selectedDevice?.maxFrequency ?? 999999999999)
                    .round(),
          );
        } else {
          widget.favorites.edit(
            existing.id,
            name: name,
            mode: mode,
            category: band,
          );
        }
        if (mounted) setState(() => message = null);
      } on ArgumentError catch (e) {
        if (mounted) {
          setState(
            () => message =
                'Не удалось сохранить: ${e.message ?? e.invalidValue}',
          );
        }
      }
    }
  }

  void apply(Favorite f) {
    try {
      widget.receiver.apply(f.frequencyHz, f.mode);
      widget.onApplied();
    } on ArgumentError {
      setState(() => message = 'Частота вне диапазона выбранного устройства');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.favorites,
    builder: (context, _) {
      final entries = widget.favorites.filtered(category);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Пресеты', style: plex(size: 22, weight: FontWeight.w600)),
                Text(
                  '${widget.favorites.entries.where((f) => f.enabled).length} сохранено · один приёмный канал',
                  style: plex(size: 12, color: LegacyColors.muted),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: legacyCard(
              child: Row(
                children: [
                  const Icon(Icons.radio, color: LegacyColors.accent, size: 17),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'КАНАЛЫ МОНИТОРИНГА · позже',
                      style: plex(size: 12, color: LegacyColors.muted),
                    ),
                  ),
                  Text(
                    '1 VFO',
                    style: plex(
                      size: 11,
                      mono: true,
                      color: LegacyColors.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 5),
              children: [
                for (final b in favoriteCategories)
                  Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: ChoiceChip(
                      key: ValueKey('category-$b'),
                      label: Text(b, style: plex(size: 12)),
                      selected: category == b,
                      onSelected: (_) => setState(() => category = b),
                    ),
                  ),
              ],
            ),
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(message!, style: plex(color: LegacyColors.danger)),
            ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 7),
              itemBuilder: (context, i) {
                final f = entries[i];
                return legacyCard(
                  child: Row(
                    children: [
                      IconButton(
                        key: ValueKey('toggle-${f.id}'),
                        tooltip: f.enabled
                            ? 'Убрать из избранного'
                            : 'Добавить в избранное',
                        onPressed: () => widget.favorites.toggle(f.id),
                        icon: Icon(
                          f.enabled ? Icons.bookmark : Icons.bookmark_border,
                          color: f.enabled
                              ? LegacyColors.accent
                              : LegacyColors.muted,
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              f.name,
                              overflow: TextOverflow.ellipsis,
                              style: plex(size: 14),
                            ),
                            Text(
                              '${(f.frequencyHz / 1000000).toStringAsFixed(3)} MHz · ${f.mode.label} · ${f.category}',
                              style: plex(
                                size: 11,
                                mono: true,
                                color: LegacyColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        key: ValueKey('favoriteMenu-${f.id}'),
                        tooltip: 'Редактировать пресет',
                        onSelected: (action) {
                          if (action == 'edit') edit(f);
                          if (action == 'delete') widget.favorites.delete(f.id);
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('Изменить'),
                          ),
                          if (!f.builtIn)
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('Удалить'),
                            ),
                        ],
                      ),
                      FilledButton(
                        key: ValueKey('apply-${f.id}'),
                        onPressed: () => apply(f),
                        child: Text(
                          'Применить',
                          style: plex(size: 11, color: LegacyColors.background),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                key: const ValueKey('addFavorite'),
                onPressed: () => edit(),
                child: const Text('Добавить текущую частоту'),
              ),
            ),
          ),
        ],
      );
    },
  );
}

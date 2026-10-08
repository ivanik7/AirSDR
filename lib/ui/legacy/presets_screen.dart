// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../bands/bands.dart';
import '../channels/channel_controller.dart' show presetCategoryFor;
import '../decoders/decoder_contract.dart';
import '../decoders/decoder_session.dart';
import '../favorites/favorites.dart';
import '../radio_controller.dart';
import 'centered_receiver.dart';
import 'step_grid.dart';
import 'theme.dart';

/// Human-readable reason for a rejected add/edit (never an empty string).
String favoriteErrorText(ArgumentError e) => switch (e.name) {
  'name' => 'введите название (1–60 символов)',
  'frequencyHz' when e.message == 'Already saved' =>
    'эта частота уже есть в списке',
  'frequencyHz' => 'частота вне диапазона устройства',
  'category' => 'неизвестная категория',
  _ => '${e.message ?? e.invalidValue ?? 'неверные данные'}',
};

/// The preset editor uses the same flat [decoderCatalog] as the Decoder
/// tab: a v3 mode choice also sets the preset's saved mode, while a data
/// decoder choice keeps the underlying mode unchanged.
List<DecoderDescriptor> _decoderChoices() => decoderCatalog;

class PresetsScreen extends StatefulWidget {
  const PresetsScreen({
    super.key,
    required this.controller,
    required this.receiver,
    required this.favorites,
    this.bands,
    required this.onApplied,
    this.decoderSession,
  });
  final RadioController controller;
  final CenteredReceiver receiver;
  final FavoritesRepository favorites;

  /// Sections of the list; without bands everything is «Вне диапазонов».
  final BandsRepository? bands;
  final VoidCallback onApplied;

  /// Shell-scoped decoder preview (decoders/decoder_session.dart). A new
  /// preset created while a data decoder is previewed carries that decoder
  /// id/settings along (same as the channel "save as preset" menu);
  /// applying a preset restores its stored decoder into the preview. Null
  /// keeps presets plain voice/audio, same as before this parameter
  /// existed.
  final DecoderSession? decoderSession;
  @override
  State<PresetsScreen> createState() => _PresetsScreenState();
}

class _PresetsScreenState extends State<PresetsScreen> {
  String? message;
  Future<void> edit([Favorite? existing]) async {
    // A new attempt supersedes the previous error.
    setState(() => message = null);
    var name = existing?.name ?? '';
    var mode = existing?.mode ?? widget.controller.mode;
    final session = widget.decoderSession;
    // One unified decoder choice drives both the preview/data-decoder
    // selection and (for a voice/demod-mode choice) the saved mode — see
    // _decoderChoices. An existing preset's choice is always resolvable
    // ([Favorite.decoderChoice]); a brand-new preset defaults to whatever
    // is currently previewed on the Decoder tab, or plain voice at the
    // dialog's starting mode.
    var decoderChoice = existing != null
        ? existing.decoderChoice
        : (session?.selectedId ?? decoderIdForMode(mode));
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
                  'Частота ${formatMhz(existing?.frequencyHz ?? widget.controller.tunedFrequency)} MHz',
                  style: plex(mono: true),
                ),
                TextFormField(
                  key: const ValueKey('favoriteName'),
                  initialValue: name,
                  onChanged: (value) => name = value,
                  maxLength: 60,
                  decoration: const InputDecoration(labelText: 'Название'),
                ),
                DropdownButton<String>(
                  key: const ValueKey('favoriteDecoder'),
                  isExpanded: true,
                  value: decoderChoice,
                  items: [
                    for (final choice in _decoderChoices())
                      DropdownMenuItem(
                        value: choice.id,
                        child: Text(
                          choice.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    update(() {
                      decoderChoice = value;
                      // Choosing an explicit voice/demod-mode option also
                      // sets the preset's underlying saved mode; choosing
                      // a data decoder leaves the current mode untouched.
                      final asMode = demodModeFromDecoderId(value);
                      if (asMode != null) mode = asMode;
                    });
                  },
                ),
                if (demodModeFromDecoderId(decoderChoice) == null &&
                    !(session?.isAvailable(decoderChoice) ?? false))
                  const Text(
                    'Декодер недоступен: настройки сохраняются для будущей версии, но приём не запускается.',
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
        // The unified choice is stored as-is: an explicit voice/demod-mode
        // pick persists its `demod:` id (so the editor can show exactly
        // what was chosen next time, via [Favorite.decoderChoice]); a
        // real data decoder persists its own id. Neither ever needs
        // settings for the voice case — [decoderCatalog]'s per-mode
        // identity has none.
        final storedId = decoderChoice;
        final isVoiceChoice = demodModeFromDecoderId(storedId) != null;
        if (existing == null) {
          final hz = widget.controller.tunedFrequency.round();
          widget.favorites.add(
            frequencyHz: hz,
            name: name,
            mode: mode,
            // Storage-only field (the list is grouped by band).
            category: presetCategoryFor(hz, mode),
            minHz: (widget.controller.selectedDevice?.minFrequency ?? 1)
                .round(),
            maxHz:
                (widget.controller.selectedDevice?.maxFrequency ?? 999999999999)
                    .round(),
            // Carries over whatever is currently previewed on the Decoder
            // tab, same as the channel "save as preset" menu.
            decoderId: storedId,
            decoderSettings: isVoiceChoice
                ? null
                : session?.settingsFor(storedId),
          );
        } else {
          widget.favorites.edit(
            existing.id,
            name: name,
            mode: mode,
            category: existing.category,
            decoderId: storedId,
            decoderSettings: isVoiceChoice
                ? null
                : storedId == existing.decoderId
                ? existing.decoderSettings
                : session?.settingsFor(storedId),
          );
        }
        if (mounted) setState(() => message = null);
      } on ArgumentError catch (e) {
        if (mounted) {
          setState(
            () => message = 'Не удалось сохранить: ${favoriteErrorText(e)}',
          );
        }
      }
    }
  }

  /// Same for built-in and user presets: confirm, then delete for good.
  Future<void> confirmDelete(Favorite f) async {
    setState(() => message = null);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить пресет?'),
        content: Text('${f.name} · ${formatMhz(f.frequencyHz)} MHz'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const ValueKey('favoriteDeleteConfirm'),
            style: FilledButton.styleFrom(backgroundColor: LegacyColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true && widget.favorites.entries.any((e) => e.id == f.id)) {
      widget.favorites.delete(f.id);
    }
  }

  void apply(Favorite f) {
    try {
      widget.receiver.apply(f.frequencyHz, f.mode);
      // Restores the preset's own decoder preview (plain voice/audio when
      // it has none) — never starts a backend decoder by itself; see
      // DecoderSession.applyStored.
      widget.decoderSession?.applyStored(
        f.decoderId,
        f.decoderSettings,
        mode: f.mode,
      );
      setState(() => message = null);
      widget.onApplied();
    } on ArgumentError {
      setState(() => message = 'Частота вне диапазона выбранного устройства');
    }
  }

  /// Section title: band name and limits, or «Вне диапазонов».
  Widget _sectionHeader(Band? band) => Padding(
    key: ValueKey('presetSection-${band?.id ?? 'none'}'),
    padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
    child: Row(
      children: [
        Flexible(
          child: Text(
            band?.name ?? 'Вне диапазонов',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: plex(size: 12, color: LegacyColors.accent),
          ),
        ),
        if (band != null) ...[
          const SizedBox(width: 8),
          Text(
            formatBandRange(band),
            maxLines: 1,
            style: plex(size: 10, mono: true, color: LegacyColors.muted),
          ),
        ],
        const SizedBox(width: 8),
        const Expanded(child: Divider(color: LegacyColors.key)),
      ],
    ),
  );

  Widget _presetCard(Favorite f) => legacyCard(
    child: Row(
      children: [
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
                '${formatMhz(f.frequencyHz)} MHz · ${f.mode.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: plex(size: 11, mono: true, color: LegacyColors.muted),
              ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          key: ValueKey('favoriteMenu-${f.id}'),
          tooltip: 'Редактировать пресет',
          onOpened: () => setState(() => message = null),
          onSelected: (action) {
            if (action == 'edit') edit(f);
            if (action == 'delete') confirmDelete(f);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Изменить')),
            PopupMenuItem(value: 'delete', child: Text('Удалить')),
          ],
        ),
        IconButton.filled(
          key: ValueKey('apply-${f.id}'),
          tooltip: 'Применить',
          onPressed: () => apply(f),
          icon: const Icon(Icons.check),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.favorites, ?widget.bands]),
    builder: (context, _) {
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
                  '${widget.favorites.entries.length} сохранено · один приёмный канал',
                  style: plex(size: 12, color: LegacyColors.muted),
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
            child: ListView(
              key: const ValueKey('presetsList'),
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
              children: [
                for (final g in groupPresetsByBand(
                  widget.favorites.entries,
                  widget.bands?.entries ?? const [],
                )) ...[
                  _sectionHeader(g.band),
                  for (final f in g.presets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: _presetCard(f),
                    ),
                ],
              ],
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

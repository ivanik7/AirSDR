// SPDX-License-Identifier: GPL-3.0-or-later
//
// Настройки → Диапазоны (task t_7b20878c): list sorted by start frequency,
// create («+»), edit (tap on a row), delete (with confirmation).
import 'package:flutter/material.dart';

import '../bands/bands.dart';
import '../decoders/decoder_contract.dart';
import '../radio_controller.dart';
import 'step_grid.dart' show formatMhz;
import 'theme.dart';

class BandsScreen extends StatelessWidget {
  const BandsScreen({super.key, required this.bands});
  final BandsRepository bands;

  static Future<void> open(BuildContext context, BandsRepository bands) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => BandsScreen(bands: bands)),
      );

  Future<void> _edit(BuildContext context, [Band? existing]) =>
      showDialog<void>(
        context: context,
        builder: (_) => BandForm(bands: bands, existing: existing),
      );

  Future<void> _confirmDelete(BuildContext context, Band b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить диапазон?'),
        content: Text('${b.name} · ${formatBandRange(b)}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const ValueKey('bandDeleteConfirm'),
            style: FilledButton.styleFrom(backgroundColor: LegacyColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true && bands.byId(b.id) != null) bands.delete(b.id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Диапазоны', style: plex(size: 20, weight: FontWeight.w600)),
    ),
    floatingActionButton: FloatingActionButton(
      key: const ValueKey('bandAdd'),
      tooltip: 'Добавить диапазон',
      onPressed: () => _edit(context),
      child: const Icon(Icons.add),
    ),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: bands,
        builder: (context, _) {
          final list = bands.entries;
          if (list.isEmpty) {
            return Center(
              child: Text(
                'Диапазонов нет',
                style: plex(size: 13, color: LegacyColors.muted),
              ),
            );
          }
          return ListView.separated(
            key: const ValueKey('bandsList'),
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 88),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 7),
            itemBuilder: (context, i) {
              final b = list[i];
              return Material(
                color: LegacyColors.card,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  key: ValueKey('band-${b.id}'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _edit(context, b),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                b.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: plex(size: 14),
                              ),
                              Text(
                                formatBandRange(b),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: plex(
                                  size: 11,
                                  mono: true,
                                  color: LegacyColors.muted,
                                ),
                              ),
                              Text(
                                '${decoderById(b.decoderChoice)?.label ?? b.mode.label} · шаг ${formatStepKhz(b.stepHz)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: plex(
                                  size: 11,
                                  color: LegacyColors.accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          key: ValueKey('bandDelete-${b.id}'),
                          tooltip: 'Удалить диапазон',
                          onPressed: () => _confirmDelete(context, b),
                          icon: const Icon(
                            Icons.delete_outline,
                            color: LegacyColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    ),
  );
}

/// Create/edit dialog. Stays open with an error text until the band is valid.
class BandForm extends StatefulWidget {
  const BandForm({super.key, required this.bands, this.existing});
  final BandsRepository bands;
  final Band? existing;
  @override
  State<BandForm> createState() => _BandFormState();
}

class _BandFormState extends State<BandForm> {
  late final TextEditingController name;
  late final TextEditingController start;
  late final TextEditingController end;
  late DemodMode mode;

  /// Choice from the one decoder list (same ids as the Decoder tab).
  late String decoder;
  late int step;
  String? error;

  @override
  void initState() {
    super.initState();
    final b = widget.existing;
    name = TextEditingController(text: b?.name ?? '');
    start = TextEditingController(text: b == null ? '' : formatMhz(b.startHz));
    end = TextEditingController(text: b == null ? '' : formatMhz(b.endHz));
    mode = b?.mode ?? DemodMode.nfm;
    decoder = b?.decoderChoice ?? decoderIdForMode(mode);
    step = b?.stepHz ?? 12500;
  }

  @override
  void dispose() {
    name.dispose();
    start.dispose();
    end.dispose();
    super.dispose();
  }

  void _save() {
    final s = parseMhzToHz(start.text);
    final e = parseMhzToHz(end.text);
    if (s == null || e == null) {
      setState(
        () => error =
            'введите ${s == null ? 'начало' : 'конец'} в МГц, '
            'например 144.0',
      );
      return;
    }
    try {
      final b = widget.existing;
      if (b == null) {
        widget.bands.add(
          name: name.text,
          startHz: s,
          endHz: e,
          mode: mode,
          stepHz: step,
          decoderId: decoder,
        );
      } else {
        widget.bands.edit(
          b.id,
          name: name.text,
          startHz: s,
          endHz: e,
          mode: mode,
          stepHz: step,
          decoderId: decoder,
        );
      }
      Navigator.pop(context);
    } on BandValidationException catch (err) {
      setState(() => error = err.message);
    }
  }

  InputDecoration _field(String label, [String? suffix]) =>
      InputDecoration(labelText: label, suffixText: suffix, isDense: true);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.existing == null ? 'Новый диапазон' : 'Изменить диапазон',
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('bandName'),
            controller: name,
            maxLength: bandMaxNameLength,
            decoration: _field('Название'),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('bandStart'),
                  controller: start,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: _field('Начало', 'МГц'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const ValueKey('bandEnd'),
                  controller: end,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: _field('Конец', 'МГц'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                // The same flat decoder list as the Decoder tab: a voice
                // choice is the band's mode, a data decoder keeps the mode
                // and is selected on entering the band.
                child: DropdownButton<String>(
                  key: const ValueKey('bandMode'),
                  isExpanded: true,
                  value: decoder,
                  items: [
                    for (final d in decoderCatalog)
                      DropdownMenuItem(
                        key: ValueKey('bandDecoder-${d.id}'),
                        value: d.id,
                        child: Text(d.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == null) return;
                    setState(() {
                      decoder = id;
                      mode = demodModeFromDecoderId(id) ?? mode;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<int>(
                  key: const ValueKey('bandStep'),
                  isExpanded: true,
                  value: step,
                  items: [
                    for (final s in receiverSteps)
                      DropdownMenuItem(
                        value: s,
                        child: Text(
                          formatStepKhz(s),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (s) {
                    if (s != null) setState(() => step = s);
                  },
                ),
              ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error!,
                key: const ValueKey('bandError'),
                style: plex(size: 12, color: LegacyColors.danger),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        key: const ValueKey('bandSave'),
        onPressed: _save,
        child: const Text('Сохранить'),
      ),
    ],
  );
}

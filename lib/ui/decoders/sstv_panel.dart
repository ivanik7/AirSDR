// SPDX-License-Identifier: GPL-3.0-or-later
//
// SSTV decoder panel: live picture assembled from real native line events,
// detected mode and status, the bounded session gallery with tap-to-enlarge
// and saving, and the OpenWebRX+ settings (underlying demod, VIS auto).
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../legacy/theme.dart';
import 'decoder_session.dart';
import 'sstv_image.dart';
import 'sstv_save.dart';

class SstvDecoderPanel extends StatelessWidget {
  SstvDecoderPanel({super.key, required this.session, SstvImageSaver? saver})
    : saver = saver ?? PlatformSstvImageSaver();

  final DecoderSession session;
  final SstvImageSaver saver;

  String _status() {
    if (!session.isAvailable('sstv')) {
      return 'Недоступен в текущей нативной сборке';
    }
    final radio = session.radio;
    if (!radio.running) return radio.lastError ?? 'Приём остановлен';
    if (session.failureReason != null) return session.failureReason!;
    if (!session.active) return 'Декодер не запущен';
    final frame = session.sstv.current;
    if (frame == null) return 'Ожидание VIS-заголовка…';
    return 'Приём кадра ${frame.mode}';
  }

  @override
  Widget build(BuildContext context) {
    final sstv = session.sstv;
    final frame = sstv.current;
    final available = session.isAvailable('sstv');
    final editable = session.canEditSettings('sstv');
    final settings = session.settingsFor('sstv');
    final radio = session.radio;
    final shown = frame ?? (sstv.gallery.isEmpty ? null : sstv.gallery.first);
    return Column(
      key: const ValueKey('decoderPanel-sstv'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SSTV · изображение', style: plex(size: 14)),
              const SizedBox(height: 6),
              Text(
                _status(),
                key: const ValueKey('sstvStatus'),
                style: plex(
                  size: 12,
                  color: session.active
                      ? LegacyColors.accent
                      : LegacyColors.muted,
                ),
              ),
              if (session.active)
                Text(
                  '${(radio.tunedFrequency / 1e6).toStringAsFixed(4)} МГц · '
                  '${radio.mode.label} · 24 кГц · '
                  'Потеряно событий: ${session.droppedEvents}',
                  key: const ValueKey('sstvRate'),
                  style: plex(size: 11, color: LegacyColors.muted),
                ),
              if (!available) ...[
                const SizedBox(height: 6),
                Text(
                  'Декодер недоступен в текущей нативной сборке — выбор здесь '
                  'только предпросмотр панели, запуск не выполняется.',
                  key: const ValueKey('decoderUnavailable-sstv'),
                  style: plex(size: 11, color: LegacyColors.danger),
                ),
              ],
              Text(
                'Голос продолжает звучать во время декодирования. '
                'Частота задаётся обычной настройкой приёмника (VFO).',
                style: plex(size: 11, color: LegacyColors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        KeyedSubtree(
          key: const ValueKey('decoderResult-sstv'),
          child: shown == null
              ? AspectRatio(
                  aspectRatio: 4 / 3,
                  child: legacyCard(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.image_not_supported_outlined,
                            size: 42,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            sstv.lastIssue ?? 'Изображение не получено',
                            key: const ValueKey('sstvEmpty'),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    legacyCard(
                      child: SstvFrameView(
                        key: const ValueKey('sstvLive'),
                        frame: shown,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      sstvFrameSummary(shown),
                      key: const ValueKey('sstvLiveInfo'),
                      style: plex(size: 12),
                    ),
                    if (sstv.lastIssue != null)
                      Text(
                        sstv.lastIssue!,
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
                'Галерея сеанса · ${sstv.gallery.length}/$kSstvGalleryCap',
                style: plex(size: 14),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('sstvClear'),
              onPressed: sstv.gallery.isEmpty ? null : session.clearSstvGallery,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Очистить'),
            ),
          ],
        ),
        if (sstv.gallery.isEmpty)
          Text(
            'Принятые кадры появятся здесь (хранятся до закрытия приложения).',
            style: plex(size: 11, color: LegacyColors.muted),
          )
        else
          SizedBox(
            height: 104,
            child: ListView.separated(
              key: const ValueKey('sstvGallery'),
              scrollDirection: Axis.horizontal,
              itemCount: sstv.gallery.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final item = sstv.gallery[index];
                return InkWell(
                  key: ValueKey('sstvThumb-${item.frameId}'),
                  onTap: () => showSstvFrameDialog(context, item, saver),
                  child: SizedBox(
                    width: 104,
                    child: Column(
                      children: [
                        Expanded(child: SstvFrameView(frame: item)),
                        Text(
                          item.status == SstvFrameStatus.complete
                              ? item.mode
                              : '${item.mode} · частично',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: plex(size: 10),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 8),
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Параметры', style: plex(size: 14)),
              const SizedBox(height: 6),
              Text(
                'Демодулятор',
                style: plex(size: 12, color: LegacyColors.muted),
              ),
              const SizedBox(height: 4),
              SegmentedButton<String>(
                key: const ValueKey('decoderSetting-sstv-underlying'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'usb', label: Text('USB')),
                  ButtonSegment(value: 'lsb', label: Text('LSB')),
                  ButtonSegment(value: 'nfm', label: Text('NFM')),
                ],
                selected: {settings['underlying']! as String},
                onSelectionChanged: editable
                    ? (s) => session.setSetting('sstv', 'underlying', s.first)
                    : null,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Режим SSTV',
                      style: plex(size: 12, color: LegacyColors.muted),
                    ),
                  ),
                  DropdownButton<Object>(
                    key: const ValueKey('decoderSetting-sstv-mode'),
                    value: settings['mode'],
                    items: [
                      DropdownMenuItem(
                        value: 'auto',
                        child: Text('Авто (VIS)', style: plex(size: 12)),
                      ),
                    ],
                    onChanged: editable
                        ? (v) {
                            if (v != null) {
                              session.setSetting('sstv', 'mode', v);
                            }
                          }
                        : null,
                  ),
                ],
              ),
              Text(
                'Принудительный выбор режима недоступен: в OpenWebRX+ '
                '(csdr-plus) режим определяется только по VIS. '
                'Поддерживается ${kSstvModes.length} режимов: Robot, Martin, '
                'Scottie, Wraase SC2, PD.',
                key: const ValueKey('sstvForcedModeNote'),
                style: plex(size: 11, color: LegacyColors.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String sstvFrameSummary(SstvFrame f) {
  final time = f.timestampUtc.toIso8601String().substring(11, 19);
  final status = switch (f.status) {
    SstvFrameStatus.receiving => 'приём',
    SstvFrameStatus.complete => 'полный',
    SstvFrameStatus.partial => 'частичный: ${sstvReasonLabel(f.reason)}',
  };
  final padded = f.paddedLines > 0 ? ' · пропущено ${f.paddedLines}' : '';
  return '${f.mode} · ${f.width}×${f.height} · '
      'строк ${f.receivedLines}/${f.height}$padded · $status · '
      '$time UTC · ${(f.frequencyHz / 1e6).toStringAsFixed(4)} МГц '
      '${f.underlying.toUpperCase()}';
}

Future<void> showSstvFrameDialog(
  BuildContext context,
  SstvFrame frame,
  SstvImageSaver saver,
) => showDialog<void>(
  context: context,
  builder: (context) => _SstvFrameDialog(frame: frame, saver: saver),
);

class _SstvFrameDialog extends StatefulWidget {
  const _SstvFrameDialog({required this.frame, required this.saver});
  final SstvFrame frame;
  final SstvImageSaver saver;

  @override
  State<_SstvFrameDialog> createState() => _SstvFrameDialogState();
}

class _SstvFrameDialogState extends State<_SstvFrameDialog> {
  String? _result;
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    String result;
    try {
      result = 'Сохранено: ${await widget.saver.save(widget.frame)}';
    } catch (e) {
      result = 'Не удалось сохранить: $e';
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    return Dialog(
      key: const ValueKey('sstvDialog'),
      insetPadding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InteractiveViewer(
              maxScale: 6,
              child: SstvFrameView(
                key: const ValueKey('sstvEnlarged'),
                frame: frame,
              ),
            ),
            const SizedBox(height: 8),
            Text(sstvFrameSummary(frame), style: plex(size: 12)),
            if (frame.status != SstvFrameStatus.complete)
              Text(
                'Кадр принят не полностью: сохраняются только принятые строки.',
                style: plex(size: 11, color: LegacyColors.danger),
              ),
            if (_result != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SelectableText(
                  _result!,
                  key: const ValueKey('sstvSaveResult'),
                  style: plex(size: 11),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Закрыть'),
                ),
                FilledButton.icon(
                  key: const ValueKey('sstvSave'),
                  onPressed: widget.saver.supported && !_saving ? _save : null,
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('Сохранить PNG'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows [frame]'s RGBA rows at its native aspect ratio; redraws whenever
/// a new row arrives (frame.revision). Rows not yet received are
/// transparent, so an incomplete picture never looks finished.
class SstvFrameView extends StatefulWidget {
  const SstvFrameView({super.key, required this.frame});
  final SstvFrame frame;

  @override
  State<SstvFrameView> createState() => _SstvFrameViewState();
}

class _SstvFrameViewState extends State<SstvFrameView> {
  ui.Image? _image;
  SstvFrame? _decodedFrame;
  int _decodedRevision = -1;
  bool _decoding = false;

  @override
  void didUpdateWidget(SstvFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _decode();
  }

  @override
  void initState() {
    super.initState();
    _decode();
  }

  void _decode() {
    final frame = widget.frame;
    if (_decoding ||
        (identical(frame, _decodedFrame) &&
            frame.revision == _decodedRevision)) {
      return;
    }
    _decoding = true;
    final revision = frame.revision;
    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (image) {
        _decoding = false;
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
          _decodedFrame = frame;
          _decodedRevision = revision;
        });
        // A row may have arrived while decoding.
        if (!identical(widget.frame, frame) ||
            widget.frame.revision != revision) {
          scheduleMicrotask(_decode);
        }
      },
    );
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: widget.frame.width / widget.frame.height,
    child: Container(
      color: Colors.black12,
      child: _image == null
          ? null
          : RawImage(
              image: _image,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.none,
            ),
    ),
  );
}

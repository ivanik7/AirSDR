// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../channels/channel_controller.dart';
import '../channels/channel_scanner.dart';
import '../channels/signal_meter.dart';

import '../favorites/favorites.dart';
import '../radio_controller.dart';
import '../sdr_ui_state.dart';

import '../spectrum_waterfall.dart';
import 'centered_receiver.dart';
import 'channels_section.dart';
import 'step_grid.dart';
import 'theme.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({
    super.key,
    required this.controller,
    required this.receiver,
    required this.spectrum,
    required this.favorites,
    required this.channels,
    required this.scanner,
    required this.meter,
  });
  final RadioController controller;
  final CenteredReceiver receiver;
  final SdrUiState spectrum;
  final FavoritesRepository favorites;
  final ChannelController channels;
  final ChannelScanner scanner;
  final SignalMeter meter;
  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  String? feedback;
  void _finishDrag() {
    widget.receiver.endDrag();
    setState(() {});
  }

  void key(String label) {
    final ok = widget.receiver.pressKey(label);
    setState(() => feedback = ok ? null : 'Неверная частота');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final r = widget.controller;
      final f = widget.receiver;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 8, 0),
            child: _FixedFrequencyRow(
              key: const ValueKey('legacyFrequencyField'),
              text: f.entry.isEmpty
                  ? formatMhz(widget.spectrum.heldFrequency ?? r.tunedFrequency)
                  : f.entry,
              entering: f.entry.isNotEmpty,
              trailing: f.entry.isNotEmpty
                  ? IconButton(
                      tooltip: 'Очистить ввод',
                      onPressed: () => key('CLR'),
                      icon: const Icon(Icons.close, size: 17),
                    )
                  : IconButton(
                      // Real mute, independent of the fixed full app volume; starts muted.
                      key: const ValueKey('legacyMute'),
                      tooltip: widget.scanner.userMuted
                          ? 'Включить звук'
                          : 'Выключить звук',
                      onPressed: () => widget.scanner.active
                          ? widget.scanner.setUserMuted(
                              !widget.scanner.userMuted,
                            )
                          : r.setMuted(!r.muted),
                      icon: Icon(
                        widget.scanner.userMuted
                            ? Icons.volume_off
                            : Icons.volume_up,
                        size: 18,
                      ),
                    ),
            ),
          ),
          // Status: never wider than the screen (cover display is ~344 dp).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              key: const ValueKey('legacyStatus'),
              children: [
                Text(
                  '${r.mode.label} · BW ${(r.bandwidth / 1000).toStringAsFixed(1)}k',
                  maxLines: 1,
                  style: plex(mono: true, size: 12, color: LegacyColors.accent),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r.running
                        ? compactStatsLine(r)
                        : linkStatusText(r.linkState),
                    key: const ValueKey('legacyStats'),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: plex(
                      mono: true,
                      size: 10,
                      color: LegacyColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: PopupMenuButton<DemodMode>(
                    key: const ValueKey('legacyModeSelect'),
                    tooltip: 'Модуляция',
                    initialValue: r.mode,
                    onSelected: (mode) => setState(() => f.changeMode(mode)),
                    itemBuilder: (context) => [
                      for (final mode in DemodMode.values)
                        PopupMenuItem(
                          key: ValueKey('legacyMode-${mode.label}'),
                          value: mode,
                          child: Text(mode.label),
                        ),
                    ],
                    child: Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: LegacyColors.card,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                r.mode.label,
                                style: plex(
                                  size: 14,
                                  color: LegacyColors.accent,
                                ),
                              ),
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
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 160,
                  child: TextButton(
                    key: const ValueKey('legacyStep'),
                    onPressed: () => setState(f.cycleStep),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'ШАГ ${(f.stepHz / 1000).toStringAsFixed(2)} кГц',
                        style: plex(size: 11, color: LegacyColors.accent),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: GestureDetector(
                key: const ValueKey('legacySpectrumDrag'),
                onHorizontalDragStart: (_) => f.beginDrag(),
                onHorizontalDragUpdate: (d) {
                  final width = MediaQuery.sizeOf(context).width - 24;
                  f.dragBy(-d.delta.dx * r.sampleRate / width);
                },
                onHorizontalDragEnd: (_) => _finishDrag(),
                onHorizontalDragCancel: _finishDrag,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Container(
                    color: const Color(0xFF0A0C0A),
                    child: Stack(
                      children: [
                        LayoutBuilder(
                          builder: (context, box) {
                            final cols =
                                (box.maxWidth *
                                        MediaQuery.devicePixelRatioOf(context))
                                    .round()
                                    .clamp(32, 1024);
                            widget.spectrum.setLayout(
                              columns: cols,
                              historyRows: 64,
                            );
                            final plot = (box.maxHeight * 0.48).clamp(
                              0.0,
                              66.0,
                            );
                            final scale = (box.maxHeight - plot).clamp(
                              0.0,
                              20.0,
                            );
                            return Column(
                              children: [
                                SizedBox(
                                  height: plot,
                                  width: box.maxWidth,
                                  child: CustomPaint(
                                    painter: SpectrumPainter(
                                      state: widget.spectrum,
                                      plotLineColor: LegacyColors.accent,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  height: scale,
                                  width: box.maxWidth,
                                  child: CustomPaint(
                                    painter: FrequencyScalePainter(
                                      state: widget.spectrum,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  height: (box.maxHeight - plot - scale).clamp(
                                    0.0,
                                    double.infinity,
                                  ),
                                  width: box.maxWidth,
                                  child: CustomPaint(
                                    painter: WaterfallPainter(
                                      state: widget.spectrum,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        // No stale FFT is represented as a current measurement while stopped.
                        if (!r.running)
                          const Positioned.fill(
                            child: ColoredBox(color: Color(0xB80A0C0A)),
                          ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: LayoutBuilder(
                              builder: (context, box) => Stack(
                                children: [
                                  Positioned(
                                    left: widget.spectrum.displayViewport
                                        .freqToX(
                                          widget.spectrum.heldFrequency ??
                                              r.tunedFrequency,
                                          box.maxWidth,
                                        )
                                        .clamp(0.0, box.maxWidth - 2),
                                    top: 0,
                                    bottom: 0,
                                    child: Container(
                                      width: 2,
                                      color: LegacyColors.accent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            // Same side margins as the spectrum panel above.
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ChannelsSection(
              controller: widget.channels,
              scanner: widget.scanner,
              radio: r,
              meter: widget.meter,
            ),
          ),
          const SizedBox(height: 2),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
            ['.', '0', 'OK'],
          ]) ...[
            Row(
              children: [
                for (final label in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 3,
                        vertical: 2,
                      ),
                      child: SizedBox(
                        height: 38,
                        child: Material(
                          color: label == 'OK'
                              ? LegacyColors.accent
                              : LegacyColors.key,
                          borderRadius: BorderRadius.circular(9),
                          child: InkWell(
                            key: ValueKey('key-$label'),
                            onTap: () => key(label),
                            child: Center(
                              child: Text(
                                label,
                                style: plex(
                                  mono: true,
                                  size: 17,
                                  color: label == 'OK'
                                      ? LegacyColors.background
                                      : LegacyColors.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (feedback != null)
            Text(feedback!, style: plex(size: 11, color: LegacyColors.danger)),
        ],
      );
    },
  );
}

/// Frequency readout with a geometry that never depends on the text: the
/// font size is chosen once for the available width so that the longest
/// possible value (11 monospace characters — the keypad entry limit and
/// more than any "MHz" readout) fits, and the height follows that size.
/// Changing the value, typing digits or swapping mute ↔ clear does not move
/// anything on the screen.
class _FixedFrequencyRow extends StatelessWidget {
  const _FixedFrequencyRow({
    super.key,
    required this.text,
    required this.entering,
    required this.trailing,
  });
  final String text;
  final bool entering;
  final Widget trailing;

  static const maxChars = 11;
  static const maxFontSize = 49.0;
  static const trailingWidth = 48.0;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final unit = Text(' MHz', style: plex(size: 12, color: LegacyColors.muted));
    return LayoutBuilder(
      builder: (context, box) {
        final unitPainter = TextPainter(
          text: TextSpan(text: ' MHz', style: plex(size: 12)),
          textScaler: scaler,
          textDirection: TextDirection.ltr,
        )..layout();
        final available = (box.maxWidth - unitPainter.width - trailingWidth - 1)
            .clamp(1.0, double.infinity);
        final sample = TextPainter(
          text: TextSpan(
            text: '8' * maxChars,
            style: plex(size: maxFontSize, mono: true),
          ),
          textScaler: scaler,
          textDirection: TextDirection.ltr,
        )..layout();
        final size = sample.width <= available
            ? maxFontSize
            : (maxFontSize * available / sample.width).floorToDouble();
        final style = plex(
          size: size,
          mono: true,
          color: entering ? LegacyColors.accent : LegacyColors.primary,
        );
        final probe = TextPainter(
          text: TextSpan(text: '8', style: style),
          textScaler: scaler,
          textDirection: TextDirection.ltr,
        )..layout();
        final height = probe.height.ceilToDouble();
        probe.dispose();
        unitPainter.dispose();
        sample.dispose();
        return SizedBox(
          height: height < 48 ? 48 : height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  text,
                  key: const ValueKey('legacyFrequency'),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: style,
                ),
              ),
              Padding(padding: const EdgeInsets.only(bottom: 8), child: unit),
              SizedBox(
                width: trailingWidth,
                height: 48,
                child: Center(child: trailing),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Status line text while not receiving (cover display: keep it short).
String linkStatusText(DeviceLinkState s) => switch (s) {
  DeviceLinkState.idle => 'приём остановлен',
  DeviceLinkState.waiting => 'ожидание USB SDR',
  DeviceLinkState.connecting => 'подключение…',
  DeviceLinkState.receiving => 'приём',
  DeviceLinkState.permissionDenied => 'нет разрешения USB',
  DeviceLinkState.disconnected => 'устройство отключено, ожидание',
  DeviceLinkState.stoppedByUser => 'приём остановлен',
  DeviceLinkState.failed => 'ошибка подключения',
};

/// Short receive-screen stats: "2.40 MS/s · USB drops 99 · audio drops 0".
/// The full list lives in the Settings status sheet; this line is always ellipsized.
String compactStatsLine(RadioController radio) {
  final st = radio.stats;
  return [
    '${(radio.sampleRate / 1e6).toStringAsFixed(2)} MS/s',
    if (st['droppedBuffers'] is num) 'USB drops ${st['droppedBuffers']}',
    if (st['audioDropped'] is num) 'audio drops ${st['audioDropped']}',
  ].join(' · ');
}

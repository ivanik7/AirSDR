// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../channels/channel_controller.dart';
import '../channels/signal_meter.dart';
import '../device_dropdown.dart';
import '../favorites/favorites.dart';
import '../radio_controller.dart';
import '../sdr_ui_state.dart';
import '../source_settings.dart';
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
    required this.meter,
  });
  final RadioController controller;
  final CenteredReceiver receiver;
  final SdrUiState spectrum;
  final FavoritesRepository favorites;
  final ChannelController channels;
  final SignalMeter meter;
  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  String? feedback;
  double _rulerDrag = 0;
  void _finishDrag() {
    widget.receiver.endDrag();
    _rulerDrag = 0;
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
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        children: [
          Row(
            children: [
              IconButton.filled(
                key: const ValueKey('legacyPlayStop'),
                tooltip: r.running ? 'Стоп' : 'Старт',
                onPressed: () => r.running ? r.stop() : f.start(),
                icon: Icon(r.running ? Icons.stop : Icons.play_arrow),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: DropdownButton<SdrDeviceInfo>(
                  key: const ValueKey('legacyDevice'),
                  isExpanded: true,
                  value: dropdownDeviceValue(r),
                  hint: const Text('Нет устройства'),
                  items: [
                    for (final d in r.devices)
                      DropdownMenuItem(
                        value: d,
                        child: Text(d.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: r.running
                      ? null
                      : (d) {
                          if (d != null) r.selectDevice(d);
                        },
                ),
              ),
              IconButton(
                tooltip: 'Обновить USB',
                onPressed: r.running ? null : r.refreshDevices,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Настройки USB',
                onPressed: () => showSourceSettingsSheet(context, r),
                icon: const Icon(Icons.tune),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    f.entry.isEmpty ? formatMhz(r.tunedFrequency) : f.entry,
                    key: const ValueKey('legacyFrequency'),
                    style: plex(
                      size: 49,
                      mono: true,
                      color: f.entry.isEmpty
                          ? LegacyColors.primary
                          : LegacyColors.accent,
                    ),
                  ),
                ),
              ),
              Text(' MHz', style: plex(size: 14, color: LegacyColors.muted)),
              IconButton(
                tooltip: 'Очистить ввод',
                onPressed: () => key('CLR'),
                icon: const Icon(Icons.close, size: 17),
              ),
              IconButton(
                // Real mute (separate from the volume slider in Settings); starts muted.
                key: const ValueKey('legacyMute'),
                tooltip: r.muted ? 'Включить звук' : 'Выключить звук',
                onPressed: () => r.setMuted(!r.muted),
                icon: Icon(
                  r.muted ? Icons.volume_off : Icons.volume_up,
                  size: 18,
                ),
              ),
            ],
          ),
          // Status: never wider than the screen (cover display is ~344 dp).
          Row(
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
                  r.running ? compactStatsLine(r) : linkStatusText(r.linkState),
                  key: const ValueKey('legacyStats'),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: plex(mono: true, size: 10, color: LegacyColors.muted),
                ),
              ),
              if (!r.running &&
                  (r.linkState == DeviceLinkState.permissionDenied ||
                      r.linkState == DeviceLinkState.failed))
                IconButton(
                  key: const ValueKey('legacyRetryUsb'),
                  tooltip: 'Повторить подключение USB',
                  visualDensity: VisualDensity.compact,
                  onPressed: r.retryDevice,
                  icon: const Icon(Icons.usb, size: 18),
                ),
            ],
          ),
          if (r.lastError != null)
            Text(
              r.lastError!,
              style: plex(size: 12, color: LegacyColors.danger),
            ),
          const SizedBox(height: 8),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final mode in DemodMode.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      key: ValueKey('legacyMode-${mode.label}'),
                      selected: mode == r.mode,
                      label: Text(mode.label, style: plex(size: 11)),
                      onSelected: (_) {
                        f.changeMode(mode);
                        setState(() {});
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            key: const ValueKey('legacySpectrumDrag'),
            onHorizontalDragStart: (_) => f.beginDrag(),
            onHorizontalDragUpdate: (d) {
              final width = MediaQuery.sizeOf(context).width - 32;
              f.dragBy(-d.delta.dx * r.sampleRate / width);
            },
            onHorizontalDragEnd: (_) => _finishDrag(),
            onHorizontalDragCancel: _finishDrag,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: Container(
                color: const Color(0xFF0A0C0A),
                height: 128,
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
                        return Column(
                          children: [
                            SizedBox(
                              height: 66,
                              width: box.maxWidth,
                              child: CustomPaint(
                                painter: SpectrumPainter(
                                  state: widget.spectrum,
                                  plotLineColor: LegacyColors.accent,
                                ),
                              ),
                            ),
                            SizedBox(
                              height: 20,
                              width: box.maxWidth,
                              child: CustomPaint(
                                painter: FrequencyScalePainter(
                                  state: widget.spectrum,
                                ),
                              ),
                            ),
                            SizedBox(
                              height: 42,
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
                                    .freqToX(r.tunedFrequency, box.maxWidth)
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
          const SizedBox(height: 9),
          SizedBox(
            height: 44,
            child: Row(
              children: [
                _square(Icons.chevron_left, const ValueKey('nudgeLeft'), () {
                  f.nudge(-1);
                  setState(() {});
                }),
                const SizedBox(width: 9),
                Expanded(
                  child: GestureDetector(
                    onHorizontalDragStart: (_) {
                      _rulerDrag = 0;
                      f.beginDrag();
                    },
                    onHorizontalDragUpdate: (d) {
                      _rulerDrag += d.delta.dx;
                      if (_rulerDrag.abs() >= 12) {
                        final steps = (_rulerDrag.abs() / 12).floor().clamp(
                          1,
                          20,
                        );
                        final direction = _rulerDrag < 0 ? 1 : -1;
                        // One ruler tick = one grid node.
                        f.dragBy((steps * f.stepHz * direction).toDouble());
                        _rulerDrag -= _rulerDrag.sign * steps * 12;
                        setState(() {});
                      }
                    },
                    onHorizontalDragEnd: (_) => _finishDrag(),
                    onHorizontalDragCancel: _finishDrag,
                    child: SizedBox(
                      height: 44,
                      child: Container(
                        decoration: BoxDecoration(
                          color: LegacyColors.card,
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: CustomPaint(
                          key: const ValueKey('tuningRuler'),
                          painter: _RulerPainter(),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                _square(Icons.chevron_right, const ValueKey('nudgeRight'), () {
                  f.nudge(1);
                  setState(() {});
                }),
              ],
            ),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => setState(f.cycleStep),
            child: Text(
              'ШАГ ${(f.stepHz / 1000).toStringAsFixed(2)} кГц',
              style: plex(size: 11, color: LegacyColors.muted),
            ),
          ),
          ChannelsSection(
            controller: widget.channels,
            radio: r,
            meter: widget.meter,
          ),
          const SizedBox(height: 11),
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
                      padding: const EdgeInsets.only(right: 7, bottom: 7),
                      child: SizedBox(
                        height: 48,
                        child: Material(
                          color: label == 'OK'
                              ? LegacyColors.accent
                              : LegacyColors.key,
                          borderRadius: BorderRadius.circular(13),
                          child: InkWell(
                            key: ValueKey('key-$label'),
                            onTap: () => key(label),
                            child: Center(
                              child: Text(
                                label,
                                style: plex(
                                  mono: true,
                                  size: 21,
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
            Text(feedback!, style: plex(color: LegacyColors.danger)),
        ],
      );
    },
  );
  // Icons, not ◀/▶ glyphs: Android renders those as colour emoji tiles.
  Widget _square(IconData icon, Key key, VoidCallback onTap) => SizedBox(
    width: 44,
    height: 44,
    child: Material(
      color: LegacyColors.key,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        key: key,
        onTap: onTap,
        child: Center(child: Icon(icon, size: 22, color: LegacyColors.primary)),
      ),
    ),
  );
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
/// The full list lives in Settings; this line is always ellipsized.
String compactStatsLine(RadioController radio) {
  final st = radio.stats;
  return [
    '${(radio.sampleRate / 1e6).toStringAsFixed(2)} MS/s',
    if (st['droppedBuffers'] is num) 'USB drops ${st['droppedBuffers']}',
    if (st['audioDropped'] is num) 'audio drops ${st['audioDropped']}',
  ].join(' · ');
}

class _RulerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF23282E)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 12) {
      canvas.drawLine(Offset(x, 6), Offset(x, size.height - 6), p);
    }
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: 2,
        height: size.height,
      ),
      Paint()..color = LegacyColors.accent,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

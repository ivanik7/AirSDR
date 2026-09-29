// SPDX-License-Identifier: GPL-3.0-or-later
//
// Main screen. Minimal Flutter counterpart of sdrpp/core/src/gui/main_window.cpp
// (top bar: play/stop, volume, FrequencySelect, tuning mode; centre: waterfall;
// right: zoom/max/min) + the source menu (gui/menus/source.cpp: device selection
// disabled while running, sample rate, gain) + the radio module menu
// (decoder_modules/radio: mode, bandwidth, squelch). Layout per docs/03 §4.6.
//
// Portrait: controls stacked above the spectrum/waterfall.
// Landscape: spectrum/waterfall on the left, scrollable control panel on the right.

import 'package:flutter/material.dart';

import 'auto_levels.dart';
import 'colormaps.dart';
import 'device_dropdown.dart';
import 'frequency_select.dart';
import 'hrfreq.dart';
import 'radio_controller.dart';
import 'sdr_ui_state.dart';
import 'source_settings.dart';
import 'spectrum_waterfall.dart';
import 'tuner.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, required this.controller});

  /// The radio; not disposed by the screen.
  final RadioController controller;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late SdrUiState _ui;
  final GlobalKey<ScaffoldMessengerState> _messenger = GlobalKey<ScaffoldMessengerState>();
  String? _shownError;

  @override
  void initState() {
    super.initState();
    _ui = SdrUiState(widget.controller);
    _ui.loadSettings();
    widget.controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(MainScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      _ui.dispose();
      _ui = SdrUiState(widget.controller);
      _ui.loadSettings();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _ui.dispose();
    super.dispose();
  }

  /// Error snackbar: shown once per new [RadioController.lastError].
  void _onController() {
    final err = widget.controller.lastError;
    if (err == _shownError) return;
    _shownError = err;
    if (err == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final m = _messenger.currentState;
      if (m == null || !mounted) return;
      m.hideCurrentSnackBar();
      m.showSnackBar(SnackBar(
        key: const ValueKey<String>('errorSnack'),
        content: Text(err),
        backgroundColor: Colors.red.shade900,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: 'OK', textColor: Colors.white, onPressed: widget.controller.clearError),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(key: _messenger, child: _scaffold(context));
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _ui,
          builder: (context, _) => OrientationBuilder(builder: (context, orientation) {
            final landscape = orientation == Orientation.landscape ||
                MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height * 1.2;
            return landscape ? _landscape(context) : _portrait(context);
          }),
        ),
      ),
    );
  }

  Widget _portrait(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TopBar(ui: _ui),
        _FrequencyRow(ui: _ui),
        _ModeSelector(ui: _ui),
        _ControlsPanel(ui: _ui, compact: true),
        Expanded(child: _Display(ui: _ui)),
      ],
    );
  }

  Widget _landscape(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FrequencyRow(ui: _ui),
              Expanded(child: _Display(ui: _ui)),
            ],
          ),
        ),
        SizedBox(
          width: 300,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(ui: _ui),
                _ModeSelector(ui: _ui),
                _ControlsPanel(ui: _ui, compact: false),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---- Top bar: device + start/stop ------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({required this.ui});
  final SdrUiState ui;

  @override
  Widget build(BuildContext context) {
    final r = ui.radio;
    final devices = r.devices;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          IconButton.filled(
            key: const ValueKey<String>('playStop'),
            tooltip: r.running ? 'Stop' : 'Start',
            icon: Icon(r.running ? Icons.stop : Icons.play_arrow),
            onPressed: () => r.running ? r.stop() : r.start(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<SdrDeviceInfo>(
              key: const ValueKey<String>('deviceDropdown'),
              isExpanded: true,
              value: dropdownDeviceValue(r),
              hint: const Text('No device'),
              // Source selection is disabled while running (gui/menus/source.cpp).
              onChanged: r.running ? null : (d) => d == null ? null : r.selectDevice(d),
              items: [
                for (final d in devices)
                  DropdownMenuItem<SdrDeviceInfo>(value: d, child: Text(d.name, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Rescan devices',
            icon: const Icon(Icons.refresh),
            onPressed: r.running ? null : r.refreshDevices,
          ),
          IconButton(
            key: const ValueKey<String>('sourceSettings'),
            tooltip: 'Device settings',
            icon: const Icon(Icons.tune),
            onPressed: () => showSourceSettingsSheet(context, r),
          ),
          PopupMenuButton<String>(
            tooltip: 'Display',
            icon: const Icon(Icons.more_vert),
            itemBuilder: (context) => [
              for (final m in sdrppColorMaps)
                CheckedPopupMenuItem<String>(value: 'cm:${m.id}', checked: ui.waterfall.colorMap.id == m.id, child: Text(m.name)),
              const PopupMenuDivider(),
              CheckedPopupMenuItem<String>(value: 'hold', checked: ui.waterfall.fftHold, child: const Text('FFT hold')),
              CheckedPopupMenuItem<String>(value: 'smooth', checked: ui.waterfall.fftSmoothing, child: const Text('FFT smoothing')),
            ],
            onSelected: (v) {
              if (v.startsWith('cm:')) {
                ui.setColorMap(colorMapByName(v.substring(3)));
              } else if (v == 'hold') {
                ui.waterfall.fftHold = !ui.waterfall.fftHold;
                ui.waterfall.resetHold();
              } else if (v == 'smooth') {
                ui.waterfall.fftSmoothing = !ui.waterfall.fftSmoothing;
              }
            },
          ),
        ],
      ),
    );
  }
}

// ---- Frequency ---------------------------------------------------------------

class _FrequencyRow extends StatelessWidget {
  const _FrequencyRow({required this.ui});
  final SdrUiState ui;

  @override
  Widget build(BuildContext context) {
    final dev = ui.radio.selectedDevice;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey<String>('stepDown'),
            tooltip: '−${hrfreqToString(ui.vfo.snapInterval)}',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => ui.step(-1),
          ),
          Expanded(
            child: FrequencySelect(
              frequency: ui.tunedFrequency.round(),
              minFreq: 0,
              maxFreq: (dev?.maxFrequency ?? 999999999999).round(),
              onChanged: (f) => ui.tuneTo(f.toDouble()),
            ),
          ),
          IconButton(
            key: const ValueKey<String>('stepUp'),
            tooltip: '+${hrfreqToString(ui.vfo.snapInterval)}',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => ui.step(1),
          ),
          PopupMenuButton<TuningMode>(
            tooltip: 'Tuning mode',
            initialValue: ui.tuningMode,
            onSelected: ui.setTuningMode,
            itemBuilder: (context) => [
              for (final m in const [TuningMode.normal, TuningMode.center])
                PopupMenuItem<TuningMode>(value: m, child: Text(m.label)),
            ],
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(ui.tuningMode.label, style: Theme.of(context).textTheme.labelSmall),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Mode --------------------------------------------------------------------

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.ui});
  final SdrUiState ui;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: SegmentedButton<DemodMode>(
        key: const ValueKey<String>('modeSelector'),
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        segments: [
          for (final m in DemodMode.values) ButtonSegment<DemodMode>(value: m, label: Text(m.label)),
        ],
        selected: {ui.radio.mode},
        onSelectionChanged: (s) => ui.radio.setMode(s.first),
      ),
    );
  }
}

// ---- Sliders -----------------------------------------------------------------

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    super.key,
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.trailing,
  });

  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          SizedBox(width: 44, child: Text(label, style: style)),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: (max > min) ? onChanged : null,
            ),
          ),
          SizedBox(width: 64, child: Text(valueText, style: style, textAlign: TextAlign.right)),
          ?trailing,
        ],
      ),
    );
  }
}

class _ControlsPanel extends StatelessWidget {
  const _ControlsPanel({required this.ui, required this.compact});
  final SdrUiState ui;

  /// Portrait: only bandwidth/gain visible, the rest in an ExpansionTile.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final r = ui.radio;
    final p = r.mode.params;
    final dev = r.selectedDevice;
    final g = dev?.gain;
    final sliders = <Widget>[
      _LabeledSlider(
        key: const ValueKey<String>('bandwidthSlider'),
        label: 'BW',
        valueText: hrfreqToString(r.bandwidth),
        value: r.bandwidth,
        min: p.minBandwidth,
        max: p.maxBandwidth,
        onChanged: p.bandwidthLocked ? null : (v) => r.setBandwidth(_roundBw(v)),
      ),
      _LabeledSlider(
        key: const ValueKey<String>('gainSlider'),
        label: 'Gain',
        valueText: r.agc ? 'AGC' : '${r.gain.toStringAsFixed(1)} ${g?.unit ?? 'dB'}',
        value: r.gain,
        min: g?.min ?? 0,
        max: g?.max ?? 1,
        divisions: (g != null && g.step > 0) ? ((g.max - g.min) / g.step).round() : null,
        onChanged: (g == null || r.agc) ? null : r.setGain,
        trailing: (dev?.hasAgc ?? false)
            ? Tooltip(
                message: 'AGC',
                child: Checkbox(key: const ValueKey<String>('agc'), value: r.agc, onChanged: (v) => r.setAgc(v ?? false)),
              )
            : null,
      ),
      _LabeledSlider(
        key: const ValueKey<String>('volumeSlider'),
        label: 'Vol',
        valueText: '${(r.volume * 100).round()}%',
        value: r.volume,
        min: 0,
        max: 1,
        onChanged: r.setVolume,
      ),
      _LabeledSlider(
        key: const ValueKey<String>('squelchSlider'),
        label: 'SQL',
        valueText: r.squelchEnabled ? '${r.squelchLevel.toStringAsFixed(0)} dB' : 'off',
        value: r.squelchLevel,
        min: -100,
        max: 0,
        onChanged: (p.squelchAllowed && r.squelchEnabled) ? r.setSquelchLevel : null,
        trailing: Checkbox(
          key: const ValueKey<String>('squelchEnable'),
          value: r.squelchEnabled && p.squelchAllowed,
          onChanged: p.squelchAllowed ? (v) => r.setSquelchEnabled(v ?? false) : null,
        ),
      ),
      if (!compact) ...[
        _LabeledSlider(
          label: 'Zoom',
          valueText: hrfreqToString(ui.viewport.viewBandwidth),
          value: ui.zoomSlider,
          min: 0,
          max: 1,
          onChanged: ui.setZoomSlider,
        ),
        ..._levelControls(ui),
      ],
      if (dev != null)
        _SampleRateRow(ui: ui),
    ];
    if (!compact) {
      return Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Column(children: sliders));
    }
    // Portrait: bandwidth + gain always visible, the rest folded.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          sliders[0],
          sliders[1],
          ExpansionTile(
            key: const ValueKey<String>('moreControls'),
            dense: true,
            visualDensity: VisualDensity.compact,
            tilePadding: EdgeInsets.zero,
            title: Text('Volume ${(r.volume * 100).round()}% · SQL ${r.squelchEnabled ? '${r.squelchLevel.round()} dB' : 'off'}',
                style: Theme.of(context).textTheme.labelSmall),
            children: [
              ...sliders.sublist(2),
              ..._levelControls(ui),
            ],
          ),
        ],
      ),
    );
  }

  /// Max/Min sliders (main_window.cpp:633-663) + automatic mode. In Auto the
  /// sliders show the automatic levels and are disabled; turning Auto off
  /// keeps the current levels for manual adjustment.
  static List<Widget> _levelControls(SdrUiState ui) {
    final auto = ui.autoLevels;
    return <Widget>[
      _LabeledSlider(
        key: const ValueKey<String>('fftMaxSlider'),
        label: 'Max',
        valueText: '${ui.fftMax.round()} dB',
        value: ui.fftMax,
        min: -150,
        max: 0,
        onChanged: auto ? null : (v) => ui.setLevels(ui.fftMin, v),
        trailing: Tooltip(
          message: 'Авто Max/Min: шум и пики за последние '
              '${AutoLevelTuning.window.inSeconds} с',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                key: const ValueKey<String>('autoLevels'),
                value: auto,
                onChanged: (v) => ui.setAutoLevels(v ?? false),
              ),
              const Text('Авто'),
            ],
          ),
        ),
      ),
      _LabeledSlider(
        key: const ValueKey<String>('fftMinSlider'),
        label: 'Min',
        valueText: '${ui.fftMin.round()} dB',
        value: ui.fftMin,
        min: -160,
        max: -10,
        onChanged: auto ? null : (v) => ui.setLevels(v, ui.fftMax),
      ),
    ];
  }

  static double _roundBw(double v) => v >= 10000 ? (v / 100).roundToDouble() * 100 : v.roundToDouble();
}

class _SampleRateRow extends StatelessWidget {
  const _SampleRateRow({required this.ui});
  final SdrUiState ui;

  @override
  Widget build(BuildContext context) {
    final r = ui.radio;
    final rates = r.selectedDevice!.sampleRates;
    final style = Theme.of(context).textTheme.labelSmall;
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          SizedBox(width: 44, child: Text('SR', style: style)),
          Expanded(
            child: DropdownButton<double>(
              key: const ValueKey<String>('sampleRate'),
              isExpanded: true,
              isDense: true,
              value: rates.contains(r.sampleRate) ? r.sampleRate : null,
              onChanged: r.running ? null : (v) => v == null ? null : r.setSampleRate(v),
              items: [
                for (final s in rates) DropdownMenuItem<double>(value: s, child: Text(hrfreqToString(s), style: style)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Display -----------------------------------------------------------------

class _Display extends StatelessWidget {
  const _Display({required this.ui});
  final SdrUiState ui;

  @override
  Widget build(BuildContext context) {
    final err = ui.radio.lastError;
    final small = Theme.of(context).textTheme.labelSmall;
    return Stack(
      fit: StackFit.expand,
      children: [
        SpectrumWaterfallView(state: ui),
        if (err != null)
          Positioned(
            left: 8,
            top: 8,
            right: 8,
            child: Align(
              alignment: Alignment.topLeft,
              child: Material(
                color: Colors.red.shade900.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(4),
                child: InkWell(
                  onTap: ui.radio.clearError,
                  child: Padding(padding: const EdgeInsets.all(6), child: Text(err, style: small)),
                ),
              ),
            ),
          ),
        if (ui.radio.running)
          Positioned(
            left: 4,
            bottom: 2,
            child: IgnorePointer(
              child: Text(statsLine(ui.radio),
                  key: const ValueKey<String>('statusLine'),
                  style: small?.copyWith(color: Colors.white70, shadows: const [Shadow(blurRadius: 2)])),
            ),
          ),
      ],
    );
  }
}

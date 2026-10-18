// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../native/native_radio_controller.dart';
import '../auto_levels.dart';
import '../bands/bands.dart';
import '../device_dropdown.dart';
import '../radio_controller.dart';
import '../sdr_ui_state.dart';
import '../source_settings.dart';
import 'bands_screen.dart';
import 'centered_receiver.dart';
import 'step_grid.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    required this.receiver,
    this.spectrum,
    this.bands,
  });
  final RadioController controller;
  final CenteredReceiver receiver;

  /// Waterfall levels (Max/Min + Auto); the section is hidden without it.
  final SdrUiState? spectrum;

  /// Frequency bands (Settings → Bands); the row is hidden without it.
  final BandsRepository? bands;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  bool _networkDraft = false;
  String? _hostError, _portError;

  @override
  void initState() {
    super.initState();
    final native = widget.controller;
    _networkDraft = native is NativeRadioController && native.networkSelected;
    _host = TextEditingController(
      text: native is NativeRadioController
          ? native.savedNetworkHost
          : '127.0.0.1',
    );
    _port = TextEditingController(
      text: native is NativeRadioController
          ? '${native.savedNetworkPort}'
          : '1234',
    );
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<bool> _applyEndpoint(NativeRadioController native) async {
    final host = _host.text.trim();
    final portText = _port.text.trim();
    final port = RegExp(r'^[0-9]+$').hasMatch(portText)
        ? int.tryParse(portText)
        : null;
    setState(() {
      _hostError =
          host.isEmpty ||
              host.contains(RegExp(r'\s')) ||
              utf8.encode(host).length > 255
          ? 'Enter a host or IP address'
          : null;
      _portError = port == null || port < 1 || port > 65535
          ? 'Enter a port from 1 to 65535'
          : null;
    });
    if (_hostError != null || _portError != null) return false;
    if (!native.networkSelected ||
        native.networkSource?.host != host ||
        native.networkSource?.port != port) {
      await native.selectNetworkSource(host, port!);
    }
    return true;
  }

  Future<void> _selectSource(NativeRadioController native, bool network) async {
    if (native.running) return;
    setState(() {
      _networkDraft = network;
      _hostError = null;
      _portError = null;
    });
    if (network) {
      await _applyEndpoint(native);
    } else {
      await native.selectUsbSource();
    }
  }

  Future<void> _toggleReception(RadioController radio) async {
    if (radio.running) {
      await radio.stop();
    } else {
      if (_networkDraft &&
          radio is NativeRadioController &&
          !await _applyEndpoint(radio)) {
        return;
      }
      await widget.receiver.start();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, ?widget.spectrum]),
    builder: (context, _) {
      final r = widget.controller;
      final native = r is NativeRadioController ? r : null;
      final network = native != null && _networkDraft;
      final d = r.selectedDevice;
      final g = d?.gain;
      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          14,
          12,
          14,
          18 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        children: [
          Text(
            'Receiver settings',
            style: plex(size: 22, weight: FontWeight.w600),
          ),
          Text(
            d?.name ?? 'No device selected',
            style: plex(size: 12, color: LegacyColors.muted),
          ),
          const SizedBox(height: 14),
          _section('SDR CONNECTION'),
          if (native != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: legacyCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Source', style: plex(size: 14)),
                    Text(
                      'Choose local USB or an rtl_tcp server',
                      style: plex(size: 11, color: LegacyColors.muted),
                    ),
                    DropdownButton<bool>(
                      key: const ValueKey('networkSource'),
                      isExpanded: true,
                      value: network,
                      items: const [
                        DropdownMenuItem(
                          value: false,
                          child: Text('Local USB SDR'),
                        ),
                        DropdownMenuItem(
                          value: true,
                          child: Text('Network (rtl_tcp)'),
                        ),
                      ],
                      onChanged: r.running
                          ? null
                          : (v) {
                              if (v != null) _selectSource(native, v);
                            },
                    ),
                  ],
                ),
              ),
            ),
          if (network) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: legacyCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const ValueKey('networkHostField'),
                      controller: _host,
                      enabled: !r.running,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'Host or IP address',
                        hintText: '127.0.0.1',
                        errorText: _hostError,
                      ),
                      onChanged: (_) {
                        if (_hostError != null) {
                          setState(() => _hostError = null);
                        }
                      },
                    ),
                    TextField(
                      key: const ValueKey('networkPortField'),
                      controller: _port,
                      enabled: !r.running,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: 'TCP port',
                        hintText: '1234',
                        errorText: _portError,
                      ),
                      onChanged: (_) {
                        if (_portError != null) {
                          setState(() => _portError = null);
                        }
                      },
                      onSubmitted: (_) {
                        if (!r.running) {
                          _applyEndpoint(native);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const ValueKey('networkApply'),
                        onPressed: r.running
                            ? null
                            : () => _applyEndpoint(native),
                        child: const Text('Apply endpoint'),
                      ),
                    ),
                    Text(
                      r.running
                          ? 'Stop reception to change the server'
                          : 'Apply to save; Start connects to this endpoint.',
                      style: plex(size: 11, color: LegacyColors.muted),
                    ),
                  ],
                ),
              ),
            ),
            _row('Connection', switch (r.linkState) {
              DeviceLinkState.connecting => 'Connecting to rtl_tcp…',
              DeviceLinkState.receiving => 'Connected to rtl_tcp',
              DeviceLinkState.failed =>
                'Connection failed · check the server and retry',
              DeviceLinkState.disconnected =>
                'Disconnected · check the server and retry',
              DeviceLinkState.stoppedByUser =>
                'Stopped · tap Start to reconnect',
              _ => 'Disconnected · tap Start to connect',
            }),
          ],
          if (!network)
            _row(
              'Select device',
              'Auto-connect when an SDR is detected',
              trailing: SizedBox(
                width: 150,
                child: DropdownButton<SdrDeviceInfo>(
                  key: const ValueKey('legacyDevice'),
                  isExpanded: true,
                  value: dropdownDeviceValue(r),
                  hint: const Text('Not found'),
                  items: [
                    for (final device in r.devices)
                      DropdownMenuItem(
                        value: device,
                        child: Text(
                          device.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: r.running
                      ? null
                      : (device) {
                          if (device != null) r.selectDevice(device);
                        },
                ),
              ),
            ),
          _row(
            'Reception',
            r.running
                ? 'Active · ${formatMhz(r.tunedFrequency)} MHz'
                : 'Stopped',
            trailing: FilledButton.icon(
              key: const ValueKey('legacyStartStop'),
              onPressed: () => _toggleReception(r),
              icon: Icon(r.running ? Icons.stop : Icons.play_arrow),
              label: Text(r.running ? 'Stop' : 'Start'),
            ),
          ),
          if (!network)
            _row(
              'Device',
              d?.name ?? 'Not found',
              trailing: IconButton(
                tooltip: 'Refresh devices',
                onPressed: r.running ? null : r.refreshDevices,
                icon: const Icon(Icons.refresh),
              ),
            ),
          if (!network)
            _row(
              'Device settings',
              'Source-specific options',
              trailing: TextButton(
                onPressed: () => showSourceSettingsSheet(context, r),
                child: const Text('Open'),
              ),
            ),
          if (d != null)
            _row(
              'Sample rate',
              'Spectrum span',
              trailing: DropdownButton<double>(
                value: d.sampleRates.contains(r.sampleRate)
                    ? r.sampleRate
                    : null,
                onChanged: r.running
                    ? null
                    : (v) {
                        if (v != null) r.setSampleRate(v);
                      },
                items: [
                  for (final rate in d.sampleRates)
                    DropdownMenuItem(
                      value: rate,
                      child: Text(
                        '${(rate / 1000000).toStringAsFixed(2)} MHz',
                        style: plex(size: 12),
                      ),
                    ),
                ],
              ),
            ),
          if (!r.running &&
              (r.linkState == DeviceLinkState.permissionDenied ||
                  r.linkState == DeviceLinkState.failed ||
                  r.linkState == DeviceLinkState.disconnected))
            _row(
              network ? 'Network connection' : 'USB connection',
              network
                  ? 'Check host, port and server, then retry'
                  : 'No access to the device',
              trailing: TextButton(
                key: ValueKey(network ? 'networkRetry' : 'legacyRetryUsb'),
                onPressed: network
                    ? () async {
                        if (await _applyEndpoint(native)) {
                          await r.retryDevice();
                        }
                      }
                    : r.retryDevice,
                child: const Text('Retry'),
              ),
            ),
          if (r.lastError != null)
            _row(
              'Error',
              r.lastError!,
              trailing: IconButton(
                onPressed: r.clearError,
                icon: const Icon(Icons.close),
              ),
            ),
          _row(
            'Status',
            'Reception diagnostics',
            trailing: TextButton(
              key: const ValueKey('legacyShowStatus'),
              onPressed: () => _showStatus(context),
              child: const Text('Show'),
            ),
          ),
          _section('RECEIVER OPTIONS'),
          if (widget.bands case final b?)
            ListenableBuilder(
              listenable: b,
              builder: (context, _) => _row(
                'Bands',
                '${b.entries.length} · mode and frequency step',
                trailing: TextButton(
                  key: const ValueKey('settingsBands'),
                  onPressed: () => BandsScreen.open(context, b),
                  child: const Text('Open'),
                ),
              ),
            ),
          if (!network)
            _row(
              'Receiver AGC',
              'Automatic gain',
              trailing: Switch(
                value: r.agc,
                onChanged: d?.hasAgc == true ? r.setAgc : null,
              ),
            ),
          _slider(
            'RF gain',
            r.gain,
            g?.min ?? 0,
            g?.max ?? 1,
            g == null || r.agc ? null : r.setGain,
            '${r.gain.toStringAsFixed(1)} ${g?.unit ?? 'dB'}',
          ),
          if (widget.spectrum case final s?) ..._waterfallLevels(s),
        ],
      );
    },
  );

  void _showStatus(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (context, scrollController) => SafeArea(
          top: false,
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) => ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Status', style: plex(size: 20))),
                    IconButton(
                      key: const ValueKey('legacyCloseStatus'),
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                for (final entry in widget.controller.stats.entries)
                  _row(entry.key, '${entry.value}'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Waterfall/spectrum levels: Auto (auto_levels.dart) or manual Max/Min.
  /// Manual controls are absent while Auto is active.
  List<Widget> _waterfallLevels(SdrUiState s) {
    final auto = s.autoLevels;
    final floor = s.autoNoiseFloor;
    return [
      _section('WATERFALL'),
      _row(
        'Waterfall speed',
        'FFT row height · independent of window size',
        trailing: DropdownButton<int>(
          key: const ValueKey('waterfallSpeed'),
          value: s.waterfallRowHeight,
          items: const [
            DropdownMenuItem(value: 1, child: Text('Slow')),
            DropdownMenuItem(value: 2, child: Text('Normal')),
            DropdownMenuItem(value: 4, child: Text('Fast')),
          ],
          onChanged: (height) {
            if (height != null) s.setWaterfallRowHeight(height);
          },
        ),
      ),
      _row(
        'Auto contrast',
        auto
            ? (floor == null
                  ? 'Noise and peaks over ${AutoLevelTuning.window.inSeconds} s · waiting for spectrum'
                  : 'Noise ${floor.round()} dB · peak ${s.autoPeak!.round()} dB '
                        'over ${AutoLevelTuning.window.inSeconds} s')
            : 'Off · levels set manually',
        trailing: Switch(
          key: const ValueKey('legacyAutoLevels'),
          value: auto,
          onChanged: s.setAutoLevels,
        ),
      ),
      if (!auto) ...[
        _slider(
          'Max',
          s.fftMax,
          -150,
          0,
          (v) => s.setLevels(s.fftMin, v),
          '${s.fftMax.round()} dB',
          key: const ValueKey('legacyFftMax'),
        ),
        _slider(
          'Min',
          s.fftMin,
          -160,
          -10,
          (v) => s.setLevels(v, s.fftMax),
          '${s.fftMin.round()} dB',
          key: const ValueKey('legacyFftMin'),
        ),
      ],
    ];
  }

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 15, 4, 8),
    child: Row(
      children: [
        Text(text, style: plex(size: 11, color: LegacyColors.accent)),
        const SizedBox(width: 9),
        const Expanded(child: Divider(color: LegacyColors.key)),
      ],
    ),
  );
  Widget _row(String label, String sub, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: legacyCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: plex(size: 14)),
                Text(
                  sub,
                  style: plex(size: 11, color: LegacyColors.muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double>? change,
    String formatted, {
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: legacyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: plex(size: 14))),
              Text(
                formatted,
                style: plex(mono: true, size: 12, color: LegacyColors.accent),
              ),
            ],
          ),
          Slider(
            key: key,
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: max > min ? change : null,
          ),
        ],
      ),
    ),
  );
}

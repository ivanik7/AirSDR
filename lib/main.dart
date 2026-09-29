// SPDX-License-Identifier: GPL-3.0-or-later
//
// sdr_flutter entry point: the real SDR stack (docs/10-architecture.md).
//
//   UI isolate:  SdrRadioController — devices from UsbDeviceProvider (RTL-SDR / HackRF via the
//                Android USB plugin) and SynthDeviceProvider (built-in test signal)
//   DSP isolate: DspEngine (SDR++ signal path + radio + audio), sources from SourceRegistry
//                + registerDeviceSources ('usb' → rtl_sdr_source / hackrf_source).
//
// DemoRadioController (lib/ui/demo_radio_controller.dart) is only used by UI tests.

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'runtime/device_sources.dart';
import 'runtime/background_reception.dart';
import 'runtime/dsp_engine.dart';
import 'runtime/sdr_radio_controller.dart';
import 'ui/legacy/app_shell.dart';
import 'ui/legacy/theme.dart';
import 'ui/radio_controller.dart';
import 'usb/usb_device_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? configDir;
  try {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    configDir = dir.path;
  } catch (_) {
    configDir = null; // in-memory config
  }
  runApp(SdrApp(controller: createRadioController(configDir: configDir)));
}

/// The production controller: USB devices + synthetic generator (+ optional IQ files),
/// config persisted under [configDir] (null = in memory).
SdrRadioController createRadioController({
  String? configDir,
  List<Map<String, Object?>> files = const <Map<String, Object?>>[],
  UsbDeviceProvider? usb,
  String audio = 'auto',
}) {
  return SdrRadioController(
    providers: <DeviceProvider>[
      usb ?? UsbDeviceProvider(),
      SynthDeviceProvider(),
      if (files.isNotEmpty) FileDeviceProvider(files),
    ],
    options: DspEngineOptions(configDir: configDir, audio: audio),
    registerSources: registerDeviceSources,
  );
}

class SdrApp extends StatefulWidget {
  const SdrApp({super.key, required this.controller});

  final RadioController controller;

  @override
  State<SdrApp> createState() => _SdrAppState();
}

class _SdrAppState extends State<SdrApp> with WidgetsBindingObserver {
  final ValueNotifier<int> _openReceive = ValueNotifier<int>(0);
  late BackgroundReception _background;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _background = BackgroundReception(
      widget.controller,
      onOpenReceive: () => _openReceive.value++,
    );
  }

  @override
  void didUpdateWidget(SdrApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _background.dispose();
      _background = BackgroundReception(
        widget.controller,
        onOpenReceive: () => _openReceive.value++,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.controller case final SdrRadioController real) {
      if (state == AppLifecycleState.resumed) real.setFftVisible(true);
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        real.setFftVisible(false);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _background.dispose();
    _openReceive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AirSDR',
      debugShowCheckedModeBanner: false,
      theme: legacyTheme(),
      home: LegacyAppShell(
        controller: widget.controller,
        openReceive: _openReceive,
      ),
    );
  }
}

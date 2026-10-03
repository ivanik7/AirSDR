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
//
// Desktop Linux (L1 dev/test target) uses the native core instead:
// HostIqRadioController (libsdrcore.so + host USB layer), or the honest
// NativeRequiredRadioController when the library cannot be loaded. The Dart
// receive engine is not used on Linux.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'native/sdr_core.dart';
import 'platform/linux/host_iq_radio_controller.dart';
import 'platform/linux/native_required_radio_controller.dart';
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
  final RadioController controller = Platform.isLinux
      ? createLinuxRadioController(configDir: configDir)
      : createRadioController(configDir: configDir);
  runApp(SdrApp(controller: controller));
}

/// Linux desktop: native host engine, or an honest "native required" state.
RadioController createLinuxRadioController({String? configDir}) {
  final SdrCore core;
  try {
    core = SdrCore.open();
  } catch (e) {
    return NativeRequiredRadioController(reason: '$e');
  }
  if (!core.hasHostUsb) {
    return NativeRequiredRadioController(
      reason: 'library has no sdr_host_usb_list/sdr_host_open_usb',
    );
  }
  return HostIqRadioController(core: core, configDir: configDir);
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
  static const _systemBars = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: LegacyColors.background,
    systemNavigationBarDividerColor: LegacyColors.background,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  );
  final ValueNotifier<int> _openReceive = ValueNotifier<int>(0);
  late BackgroundReception _background;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(_systemBars);
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
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setSystemUIOverlayStyle(_systemBars);
    }
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
      // Android 15+ draws the 3-button navbar over app content; opt out of
      // the system's light contrast scrim and supply a dark canvas beneath it.
      // Gesture navigation remains edge-to-edge with a light handle.
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: _systemBars,
        child: ColoredBox(color: LegacyColors.background, child: child!),
      ),
      home: LegacyAppShell(
        controller: widget.controller,
        openReceive: _openReceive,
      ),
    );
  }
}

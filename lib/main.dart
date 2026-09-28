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

class SdrApp extends StatelessWidget {
  const SdrApp({super.key, required this.controller});

  final RadioController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SDR Flutter',
      debugShowCheckedModeBanner: false,
      theme: legacyTheme(),
      home: LegacyAppShell(controller: controller),
    );
  }
}

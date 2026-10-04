// SPDX-License-Identifier: GPL-3.0-or-later
//
// sdr_flutter entry point: the real SDR stack (docs/10-architecture.md).
//
//   Dart fallback: SdrRadioController — devices from UsbDeviceProvider (RTL-SDR / HackRF via the
//                Android USB plugin) and SynthDeviceProvider (built-in test signal)
//   DSP isolate: DspEngine (SDR++ signal path + radio + audio), sources from SourceRegistry
//                + registerDeviceSources ('usb' → rtl_sdr_source / hackrf_source).
//
// DemoRadioController (lib/ui/demo_radio_controller.dart) is only used by UI tests.
//
// N2 defaults to ABI 3 native receive/DSP/audio on Linux and Android API 26+.
// The Dart engine remains selectable until N5, and is the Android fallback on
// API 24/25 or when the v3 core is unavailable. Linux reports a missing core.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'native/sdr_core.dart';
import 'native/native_radio_api.dart';
import 'native/native_radio_controller.dart';
import 'native/native_service_lifecycle.dart';
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
      : Platform.isAndroid
      ? await createAndroidRadioController(configDir: configDir)
      : createRadioController(configDir: configDir);
  runApp(SdrApp(controller: controller));
}

/// Receive engine requested for this run: `native` (default) or `dart`.
/// The environment wins over the compile-time define so Linux QA can switch
/// engines without rebuilding.
String requestedEngine({Map<String, String>? environment}) {
  const defined = String.fromEnvironment('SDR_ENGINE', defaultValue: 'native');
  final env = (environment ?? Platform.environment)['SDR_ENGINE'];
  final value = (env == null || env.isEmpty ? defined : env).toLowerCase();
  return value == 'dart' ? 'dart' : 'native';
}

/// AAudio is available from Android 8. Keep the working Dart receiver on older
/// devices and when the complete v3 library/service contract is unavailable.
bool androidNativeAvailable({required int sdkInt, required int abi}) =>
    sdkInt >= 26 && abi == nativeRadioAbi;

Future<RadioController> createAndroidRadioController({
  String? configDir,
}) async {
  if (requestedEngine() == 'dart') {
    return createRadioController(configDir: configDir);
  }
  try {
    const channel = MethodChannel('sdr/background');
    final sdk = await channel.invokeMethod<int>('sdkInt');
    final library = openSdrCoreLibrary();
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
      'sdr_version',
    )();
    if (!androidNativeAvailable(sdkInt: sdk ?? 0, abi: version)) {
      debugPrint(
        'Native receiver unavailable (Android SDK $sdk, ABI $version); using Dart',
      );
      return createRadioController(configDir: configDir);
    }
    final api = FfiNativeRadioApi(library);
    final service = NativeServiceLifecycle(channel: channel);
    late NativeRadioController controller;
    controller = NativeRadioController(
      api: api,
      source: AndroidNativeDeviceSource(UsbDeviceProvider()),
      audioSink: 'aaudio',
      configDir: configDir,
      beforeStart: () => service.promote(controller),
      afterStop: service.release,
    );
    return controller;
  } catch (e) {
    debugPrint('Native receiver unavailable ($e); using Dart');
    return createRadioController(configDir: configDir);
  }
}

/// Linux desktop: native host engine, or an honest "native required" state.
RadioController createLinuxRadioController({String? configDir}) {
  // Keep the ABI 2/Dart path explicitly selectable until N5 removes it.
  if (requestedEngine() == 'native') {
    try {
      final library = openSdrCoreLibrary();
      final version = library.lookupFunction<Uint32 Function(), int Function()>(
        'sdr_version',
      )();
      if (version != nativeRadioAbi) {
        return NativeRequiredRadioController(
          reason:
              'SDR_ENGINE=native needs sdrcore ABI $nativeRadioAbi, '
              'library reports $version',
        );
      }
      final api = FfiNativeRadioApi(library);
      // ADR default on Linux is the headless "null" sink; desktop users pick
      // "alsa" or "alsa:<pcm>" (or "wav:<path>" for QA) via SDR_AUDIO_SINK.
      final sink = Platform.environment['SDR_AUDIO_SINK'];
      return NativeRadioController(
        api: api,
        source: HostNativeDeviceSource(api),
        audioSink: sink == null || sink.isEmpty ? 'null' : sink,
        configDir: configDir,
      );
    } catch (e) {
      return NativeRequiredRadioController(reason: '$e');
    }
  }
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

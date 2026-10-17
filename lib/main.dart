// SPDX-License-Identifier: GPL-3.0-or-later
//
// ABI v3 is the only production receiver. No Dart USB, IQ, DSP or audio path.
// DemoRadioController (lib/ui/demo_radio_controller.dart) is only used by UI tests.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'native/android_native_device_source.dart';
import 'native/native_decoder_api.dart';
import 'native/native_radio_api.dart';
import 'native/native_radio_controller.dart';
import 'native/native_service_lifecycle.dart';
import 'native/sdr_core.dart';
import 'platform/linux/native_required_radio_controller.dart';
import 'runtime/background_reception.dart';
import 'ui/legacy/app_shell.dart';
import 'ui/legacy/theme.dart';
import 'ui/radio_controller.dart';

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
  final RadioController controller = isDesktopPlatform(Platform.operatingSystem)
      ? createDesktopRadioController(configDir: configDir)
      : Platform.isAndroid
      ? await createAndroidRadioController(configDir: configDir)
      : NativeRequiredRadioController(
          reason: 'Native receiver requires Android or a supported desktop',
        );
  runApp(SdrApp(controller: controller));
}

/// AAudio requires Android API 26; Gradle minSdk enforces this at installation.
bool androidNativeAvailable({required int sdkInt, required int abi}) =>
    sdkInt >= 26 && abi == nativeRadioAbi;

Future<RadioController> createAndroidRadioController({
  String? configDir,
}) async {
  try {
    const channel = MethodChannel('sdr/background');
    final sdk = await channel.invokeMethod<int>('sdkInt');
    final library = openSdrCoreLibrary();
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
      'sdr_version',
    )();
    if (!androidNativeAvailable(sdkInt: sdk ?? 0, abi: version)) {
      return NativeRequiredRadioController(
        reason:
            'Native receiver requires Android API 26+ and sdrcore ABI $nativeRadioAbi '
            '(found SDK $sdk, ABI $version)',
      );
    }
    final api = FfiNativeRadioApi(library);
    final service = NativeServiceLifecycle(channel: channel);
    late NativeRadioController controller;
    controller = NativeRadioController(
      api: api,
      decoderApi: FfiNativeDecoderApi.tryOpen(library),
      source: AndroidNativeDeviceSource(),
      audioSink: 'aaudio',
      configDir: configDir,
      beforeStart: () => service.promote(controller),
      afterStop: service.release,
    );
    return controller;
  } catch (e) {
    return NativeRequiredRadioController(
      reason: 'Native receiver unavailable: $e',
    );
  }
}

bool isDesktopPlatform(String operatingSystem) =>
    operatingSystem == 'linux' ||
    operatingSystem == 'macos' ||
    operatingSystem == 'windows';

String defaultDesktopAudioSink(String operatingSystem, {String? override}) =>
    override != null && override.isNotEmpty
    ? override
    : operatingSystem == 'linux'
    ? 'null'
    : 'miniaudio';

/// Desktop: native host engine, or an honest "native required" state.
RadioController createDesktopRadioController({String? configDir}) {
  try {
    final library = openSdrCoreLibrary();
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
      'sdr_version',
    )();
    if (version != nativeRadioAbi) {
      return NativeRequiredRadioController(
        reason:
            'Native receiver needs sdrcore ABI $nativeRadioAbi, '
            'library reports $version',
      );
    }
    final api = FfiNativeRadioApi(library);
    // Keep Linux's null default; CoreAudio/WASAPI use miniaudio. All desktops
    // allow SDR_AUDIO_SINK overrides (including WAV for offline QA).
    final sink = Platform.environment['SDR_AUDIO_SINK'];
    return NativeRadioController(
      api: api,
      decoderApi: FfiNativeDecoderApi.tryOpen(library),
      source: HostNativeDeviceSource(api),
      audioSink: defaultDesktopAudioSink(
        Platform.operatingSystem,
        override: sink,
      ),
      configDir: configDir,
    );
  } catch (e) {
    return NativeRequiredRadioController(reason: '$e');
  }
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
  // Label of the one selected decoder, published by the shell.
  final ValueNotifier<String?> _decoderLabel = ValueNotifier<String?>(null);
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
      decoderLabel: _decoderLabel,
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
        decoderLabel: _decoderLabel,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setSystemUIOverlayStyle(_systemBars);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _background.dispose();
    _openReceive.dispose();
    _decoderLabel.dispose();
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
        decoderLabel: _decoderLabel,
      ),
    );
  }
}

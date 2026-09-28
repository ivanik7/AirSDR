// Dart port of the SDR++ RTL-SDR source module.
//
// Source: ~/prj/sdrpp/source_modules/rtl_sdr_source/src/main.cpp (607 lines,
// SDR++ by Ryzerth, GPL-3.0). Section map (C++ line numbers):
//   sampleRates / sampleRatesTxt / directSamplingModesTxt ..... 27-55
//   constructor / destructor ................................. 59-101
//   refresh (Android branch: one device per fd) .............. 117-159
//   selectFirst / selectByName / selectById .................. 161-258
//   menuSelected / menuDeselected ............................ 275-284
//   start ..................................................... 286-330
//   stop ...................................................... 332-342
//   tune (retry loop) ......................................... 344-359
//   menuHandler -> settings / applySetting ................... 361-524
//   worker / asyncHandler (u8 -> float) ...................... 526-539
//   updateGainTxt ............................................. 541-543
//   _INIT_ (config defaults) .................................. 587-594
//
// Differences from C++ (forced by the Dart runtime, see docs/10-architecture.md):
//  * Runs on the DSP isolate. The Android usbfs fd comes from the UI isolate in
//    [UsbSourceParams] (C++: backend::getDeviceFD); each rtlsdr_open_sys_dev()
//    becomes `RtlSdrDev.open(opener(params))` (UsbfsDeviceHandle.wrap(fd)).
//  * The worker thread (rtlsdr_reset_buffer + blocking rtlsdr_read_async)
//    becomes the un-awaited readAsync() future; stop() awaits it (= join).
//  * stream.writeBuf/swap -> a Float32List handed to the [SourceSink];
//    stream.stopWriter -> the sink is dropped before cancel.
//  * ImGui menu -> declarative [settings] + [applySetting]. Widgets that SDR++
//    disables (device/sample-rate combo while running, gain slider with tuner
//    AGC) ignore applySetting in that state.
//  * ConfigManager -> [SourceModuleConfig] (per device name, which includes
//    the USB serial); the owner persists it through [onConfigChanged].
//  * Device loss (hot-unplug) is reported through [onError] and the module
//    stops itself cleanly (SDR++ just keeps a dead worker).
//  * The desktop device name "Vendor Product [Serial]##i" loses the ImGui
//    "##i" id suffix; on Android SDR++ uses the fixed "RTL-SDR Dongle USB",
//    here the desktop format is used so settings are kept per dongle serial.
//  * `freq` is uninitialised in C++; here it starts at 100 MHz (SourceManager
//    tunes right after start anyway).
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import '../../../drivers/rtlsdr/librtlsdr.dart';
import '../../../usb/usb_transport.dart';
import '../../signal_path/source_handler.dart';
import 'rtl_sdr_convert.dart';
import 'usb_source.dart';

const List<double> rtlSdrSampleRates = [
  250000,
  1024000,
  1536000,
  1792000,
  1920000,
  2048000,
  2160000,
  2400000,
  2560000,
  2880000,
  3200000,
];

const List<String> rtlSdrSampleRatesTxt = [
  '250KHz',
  '1.024MHz',
  '1.536MHz',
  '1.792MHz',
  '1.92MHz',
  '2.048MHz',
  '2.16MHz',
  '2.4MHz',
  '2.56MHz',
  '2.88MHz',
  '3.2MHz',
];

const List<String> rtlSdrDirectSamplingModesTxt = [
  'Disabled',
  'I branch',
  'Q branch',
];

/// SourceSetting ids of the RTL-SDR module.
abstract final class RtlSdrSettingId {
  static const device = SourceSettingId.device;
  static const sampleRate = SourceSettingId.sampleRate;
  static const refresh = SourceSettingId.refresh;
  static const directSampling = 'directSampling';
  static const ppm = 'ppm';
  static const gain = 'gain';
  static const biasT = 'biasT';
  static const offsetTuning = 'offsetTuning';
  static const rtlAgc = 'rtlAgc';
  static const tunerAgc = 'tunerAgc';
}

/// _INIT_(): `def["devices"] = {}; def["device"] = 0;`
Map<String, Object?> rtlSdrDefaultConfig() => {
  'devices': <String, Object?>{},
  'device': 0,
};

/// asyncCount = (int)roundf(sampleRate / (200 * 512)) * 512  (main.cpp:324):
/// bytes per USB transfer, ~5 ms of samples, multiple of 512.
int rtlSdrAsyncCount(double sampleRate) {
  final f = Float32List(1)..[0] = sampleRate / (200 * 512); // roundf(float)
  return f[0].round() * 512;
}

class RtlSdrSourceModule implements UsbSourceModule {
  @override
  final String name;
  final SourceCore core;

  /// Device handed over by the UI isolate (null: no device, like devFd < 0).
  UsbSourceParams? params;
  final UsbDeviceOpener opener;
  final SourceModuleConfig config;

  @override
  SourceErrorCallback? onError;

  @override
  void Function(Map<String, Object?> config)? onConfigChanged;

  RtlSdrDev? openDev;
  bool enabled = true;
  @override
  double sampleRate;
  bool _running = false;
  double freq = 100e6;
  String selectedDevName = '';
  int devId = 0;
  int srId = 0;
  int devCount = 0;

  int ppm = 0;

  bool biasT = false;

  int gainId = 0;
  List<int> gainList = [];

  bool rtlAgc = false;
  bool tunerAgc = false;
  bool offsetTuning = false;

  int directSamplingMode = 0;

  // Handler stuff
  int asyncCount = 0;

  String dbTxt = '--';

  final List<String> devNames = [];

  // Dart runtime state (worker thread / stream equivalents)
  Future<int>? _worker;
  SourceSink? _sink;
  Float32List _writeBuf = Float32List(0);
  WatchedUsbDeviceHandle? _usb;
  Future<void> _serial = Future<void>.value();
  bool _errorReported = false;

  RtlSdrSourceModule(
    this.name,
    this.core,
    this.params, {
    UsbDeviceOpener? opener,
    Map<String, Object?>? savedConfig,
    this.onConfigChanged,
    this.onError,
  }) : opener = opener ?? defaultUsbDeviceOpener,
       config = SourceModuleConfig(rtlSdrDefaultConfig(), savedConfig),
       sampleRate = rtlSdrSampleRates[0] {
    config.onChanged = (c) => onConfigChanged?.call(c);

    refresh();

    config.acquire();
    final dev = config.conf['device'];
    if (dev is! String) {
      selectedDevName = '';
      config.conf['device'] = '';
    } else {
      selectedDevName = dev;
    }
    config.release(true);
    selectByName(selectedDevName);
  }

  /// Construct from the plain map sent by the UI isolate:
  /// `{fd, vid, pid, deviceName, serial, manufacturer, product}`.
  factory RtlSdrSourceModule.fromParams(
    Map<Object?, Object?> params,
    SourceCore core, {
    String name = 'RTL-SDR',
    UsbDeviceOpener? opener,
    Map<String, Object?>? savedConfig,
    void Function(Map<String, Object?> config)? onConfigChanged,
    SourceErrorCallback? onError,
  }) => RtlSdrSourceModule(
    name,
    core,
    UsbSourceParams.fromMap(params),
    opener: opener,
    savedConfig: savedConfig,
    onConfigChanged: onConfigChanged,
    onError: onError,
  );

  @override
  String get sourceName => 'RTL-SDR';

  @override
  bool get running => _running;

  @override
  List<String> get deviceNames => List.unmodifiable(devNames);

  /// ~RTLSDRSourceModule
  @override
  Future<void> dispose() => stop();

  void enable() {
    enabled = true;
  }

  void disable() {
    enabled = false;
  }

  bool isEnabled() => enabled;

  /// Device name as built by the desktop refresh() (main.cpp:132-138), minus
  /// the ImGui "##i" suffix.
  static String deviceNameFor(UsbSourceParams p) {
    final sn = (p.serial != null && p.serial!.isNotEmpty)
        ? p.serial!
        : 'No Serial';
    final ven = p.manufacturer ?? '';
    final prod = p.product ?? '';
    if (ven.isNotEmpty && prod.isNotEmpty) {
      return '$ven $prod [$sn]';
    }
    // rtlsdr_get_device_name(): known_devices[] name, "" if unknown
    final devName = findKnownDevice(p.vid, p.pid)?.name ?? '';
    return '$devName [$sn]';
  }

  @override
  void refresh() {
    devNames.clear();

    // Android branch: one device, the one we have an fd for.
    devCount = 0;
    final p = params;
    if (p == null || p.fd < 0) return;

    devCount = 1;
    devNames.add(deviceNameFor(p));
  }

  void selectFirst() {
    if (devCount > 0) {
      selectById(0);
    }
  }

  void selectByName(String name) {
    for (var i = 0; i < devCount; i++) {
      if (name == devNames[i]) {
        selectById(i);
        return;
      }
    }
    selectFirst();
  }

  /// rtlsdr_open_sys_dev(&dev, devFd)
  ({int r, RtlSdrDev? dev, WatchedUsbDeviceHandle? usb}) _openSysDev() {
    final p = params;
    if (p == null) return (r: -1, dev: null, usb: null);
    late final WatchedUsbDeviceHandle usb;
    try {
      usb = WatchedUsbDeviceHandle(opener(p), (e) {
        // only the handle of the running stream matters (select() handles
        // are closed right away)
        if (identical(usb, _usb)) _deviceLost(e);
      });
    } on Object catch (e) {
      SourceLog.error('Could not wrap RTL-SDR fd ${p.fd}: $e');
      return (r: e is UsbException ? e.code : -1, dev: null, usb: null);
    }
    final res = RtlSdrDev.open(usb);
    return (r: res.r, dev: res.dev, usb: usb);
  }

  void selectById(int id) {
    selectedDevName = devNames[id];

    final o = _openSysDev();
    final oret = o.r;

    if (oret < 0 || o.dev == null) {
      selectedDevName = '';
      SourceLog.error('Could not open RTL-SDR: $oret');
      onError?.call('Could not open RTL-SDR ($oret)', oret, fatal: false);
      return;
    }
    final dev = o.dev!;

    gainList = dev.getTunerGains()..sort();

    if (dev.tuner?.setFreq == null && dev.tunerType != RtlSdrTuner.unknown) {
      final t = RtlSdrTuner.names[dev.tunerType];
      SourceLog.error('RTL-SDR tuner $t is not supported by the Dart driver');
      onError?.call(
        'RTL-SDR tuner $t is not supported yet',
        dev.tunerType,
        fatal: false,
      );
    }

    var created = false;
    config.acquire();
    if (!config.devices.containsKey(selectedDevName)) {
      created = true;
      config.device(selectedDevName)
        ..['sampleRate'] = 2400000.0
        ..['directSampling'] = directSamplingMode
        ..['ppm'] = 0
        ..['biasT'] = biasT
        ..['offsetTuning'] = offsetTuning
        ..['rtlAgc'] = rtlAgc
        ..['tunerAgc'] = tunerAgc
        ..['gain'] = gainId;
    }
    final c = config.device(selectedDevName);

    // Load config
    if (c.containsKey('sampleRate')) {
      final selectedSr = jsonInt(c['sampleRate'], 0);
      for (var i = 0; i < 11; i++) {
        if (rtlSdrSampleRates[i] == selectedSr) {
          srId = i;
          sampleRate = selectedSr.toDouble();
          break;
        }
      }
    }

    if (c.containsKey('directSampling')) {
      directSamplingMode = jsonInt(c['directSampling'], directSamplingMode);
    }

    if (c.containsKey('ppm')) {
      ppm = jsonInt(c['ppm'], ppm);
    }

    if (c.containsKey('biasT')) {
      biasT = jsonBool(c['biasT'], biasT);
    }

    if (c.containsKey('offsetTuning')) {
      offsetTuning = jsonBool(c['offsetTuning'], offsetTuning);
    }

    if (c.containsKey('rtlAgc')) {
      rtlAgc = jsonBool(c['rtlAgc'], rtlAgc);
    }

    if (c.containsKey('tunerAgc')) {
      tunerAgc = jsonBool(c['tunerAgc'], tunerAgc);
    }

    if (c.containsKey('gain')) {
      gainId = jsonInt(c['gain'], gainId);
    }

    if (gainId >= gainList.length) {
      gainId = gainList.length - 1;
    }
    if (gainId < 0) gainId = 0; // Dart: C++ would index gainList[-1]
    updateGainTxt();

    config.release(created);

    // rtlsdr_close(openDev): nothing is streaming, so the async close()
    // completes all its USB traffic synchronously.
    unawaited(dev.close());
  }

  /// getBandwdithScaled (unused by the C++ menu, kept for completeness)
  static String getBandwdithScaled(double bw) {
    if (bw >= 1000000.0) {
      return '${(bw / 1000000.0).toStringAsFixed(1)}MHz';
    } else if (bw >= 1000.0) {
      return '${(bw / 1000.0).toStringAsFixed(1)}KHz';
    } else {
      return '${bw.toStringAsFixed(1)}Hz';
    }
  }

  /// menuSelected
  @override
  void select() {
    core.setInputSampleRate(sampleRate);
    SourceLog.info("RTLSDRSourceModule '$name': Menu Select!");
  }

  /// menuDeselected
  @override
  void deselect() {
    SourceLog.info("RTLSDRSourceModule '$name': Menu Deselect!");
  }

  Future<void> _serialize(FutureOr<void> Function() f) {
    final next = _serial.then((_) => f());
    _serial = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> start(SourceSink sink) => _serialize(() => _start(sink));

  void _start(SourceSink sink) {
    if (_running) return;
    if (selectedDevName == '') {
      SourceLog.error('No device selected');
      onError?.call('No device selected', null, fatal: false);
      return;
    }

    final o = _openSysDev();
    final oret = o.r;

    if (oret < 0 || o.dev == null) {
      SourceLog.error('Could not open RTL-SDR');
      onError?.call('Could not open RTL-SDR ($oret)', oret, fatal: false);
      return;
    }
    final dev = o.dev!;
    if (dev.tuner?.setFreq == null && dev.tunerType != RtlSdrTuner.unknown) {
      // Dart: tuner driver not ported (librtlsdr would drive it)
      final t = RtlSdrTuner.names[dev.tunerType];
      unawaited(dev.close());
      SourceLog.error('RTL-SDR tuner $t is not supported by the Dart driver');
      onError?.call(
        'RTL-SDR tuner $t is not supported yet',
        dev.tunerType,
        fatal: false,
      );
      return;
    }
    openDev = dev;
    _usb = o.usb;
    _errorReported = false;

    SourceLog.info('RTL-SDR Sample Rate: $sampleRate');

    dev.setSampleRate(sampleRate.truncate());
    dev.setCenterFreq(_u32(freq));
    dev.setFreqCorrection(ppm);
    dev.setTunerBandwidth(0);
    dev.setDirectSampling(directSamplingMode);
    dev.setBiasTee(biasT ? 1 : 0);
    dev.setAgcMode(rtlAgc ? 1 : 0);
    dev.setTunerGain(gainList[gainId]);
    if (tunerAgc) {
      dev.setTunerGainMode(0);
    } else {
      dev.setTunerGainMode(1);
      dev.setTunerGain(gainList[gainId]);
    }
    dev.setOffsetTuning(offsetTuning ? 1 : 0);

    asyncCount = rtlSdrAsyncCount(sampleRate);

    _writeBuf = Float32List(asyncCount);
    _sink = sink;
    _worker = worker(dev);

    _running = true;
    SourceLog.info("RTLSDRSourceModule '$name': Start!");
  }

  @override
  Future<void> stop() => _serialize(_stop);

  Future<void> _stop() async {
    if (!_running) return;
    _running = false;
    _sink = null; // stream.stopWriter()
    final dev = openDev!;
    dev.cancelAsync();
    final w = _worker;
    if (w != null) await w; // workerThread.join()
    _worker = null;
    await dev.close();
    openDev = null;
    _usb = null;
    SourceLog.info("RTLSDRSourceModule '$name': Stop!");
  }

  /// C++: `rtlsdr_set_center_freq(dev, freq)` with a double -> uint32_t.
  static int _u32(double f) => f.truncate() & 0xffffffff;

  @override
  void tune(double freq) {
    final dev = openDev;
    if (_running && dev != null) {
      final newFreq = _u32(freq);
      int i;
      for (i = 0; i < 10; i++) {
        dev.setCenterFreq(_u32(freq));
        if (dev.getCenterFreq() == newFreq) break;
      }
      if (i > 1) {
        SourceLog.warn('RTL-SDR took $i attempts to tune...');
      }
    }
    this.freq = freq;
    SourceLog.info("RTLSDRSourceModule '$name': Tune: $freq!");
  }

  // ---- menuHandler ---------------------------------------------------------

  @override
  List<SourceSetting> get settings => [
    ChoiceSetting(RtlSdrSettingId.device, 'Device', deviceNames, devId),
    ChoiceSetting(
      RtlSdrSettingId.sampleRate,
      'Sample Rate',
      rtlSdrSampleRatesTxt,
      srId,
    ),
    ChoiceSetting(
      RtlSdrSettingId.directSampling,
      'Direct Sampling',
      rtlSdrDirectSamplingModesTxt,
      directSamplingMode,
    ),
    SliderSetting(
      RtlSdrSettingId.ppm,
      'PPM Correction',
      min: -1000000,
      max: 1000000,
      step: 1,
      value: ppm.toDouble(),
    ),
    SliderSetting(
      RtlSdrSettingId.gain,
      'Gain $dbTxt',
      min: 0,
      max: gainList.isEmpty ? 0 : (gainList.length - 1).toDouble(),
      step: 1,
      value: gainId.toDouble(),
    ),
    BoolSetting(RtlSdrSettingId.biasT, 'Bias T', biasT),
    BoolSetting(RtlSdrSettingId.offsetTuning, 'Offset Tuning', offsetTuning),
    BoolSetting(RtlSdrSettingId.rtlAgc, 'RTL AGC', rtlAgc),
    BoolSetting(RtlSdrSettingId.tunerAgc, 'Tuner AGC', tunerAgc),
  ];

  /// Gain slider is disabled in SDR++ when tuner AGC is on or no gains.
  bool get gainEnabled => !(tunerAgc || gainList.isEmpty);

  void _saveDev(String key, Object? value) {
    if (selectedDevName != '') {
      config.acquire();
      config.device(selectedDevName)[key] = value;
      config.release(true);
    }
  }

  @override
  void applySetting(String id, Object value) {
    final dev = openDev;
    switch (id) {
      case RtlSdrSettingId.device:
        if (_running) return; // BeginDisabled
        final i = jsonInt(value, devId);
        if (i < 0 || i >= devCount) return;
        devId = i;
        selectById(devId);
        core.setInputSampleRate(sampleRate);
        if (selectedDevName != '') {
          config.acquire();
          config.conf['device'] = selectedDevName;
          config.release(true);
        }

      case RtlSdrSettingId.sampleRate:
        if (_running) return; // BeginDisabled
        final i = jsonInt(value, srId);
        if (i < 0 || i >= rtlSdrSampleRates.length) return;
        srId = i;
        sampleRate = rtlSdrSampleRates[srId];
        core.setInputSampleRate(sampleRate);
        _saveDev('sampleRate', sampleRate);

      case RtlSdrSettingId.refresh:
        if (_running) return; // BeginDisabled
        refresh();
        selectByName(selectedDevName);
        core.setInputSampleRate(sampleRate);

      case RtlSdrSettingId.directSampling:
        final m = jsonInt(value, directSamplingMode);
        if (m < 0 || m > 2) return;
        directSamplingMode = m;
        if (_running && dev != null) {
          dev.setDirectSampling(directSamplingMode);

          // Update gains (fix for librtlsdr bug)
          if (directSamplingMode == 0) {
            dev.setAgcMode(rtlAgc ? 1 : 0);
            if (tunerAgc) {
              dev.setTunerGainMode(0);
            } else {
              dev.setTunerGainMode(1);
              dev.setTunerGain(gainList[gainId]);
            }
          }
        }
        _saveDev('directSampling', directSamplingMode);

      case RtlSdrSettingId.ppm:
        ppm = jsonInt(value, ppm).clamp(-1000000, 1000000);
        if (_running && dev != null) {
          dev.setFreqCorrection(ppm);
        }
        _saveDev('ppm', ppm);

      case RtlSdrSettingId.gain:
        if (!gainEnabled) return; // BeginDisabled
        gainId = jsonInt(value, gainId).clamp(0, gainList.length - 1);
        updateGainTxt();
        if (_running && dev != null) {
          dev.setTunerGain(gainList[gainId]);
        }
        _saveDev('gain', gainId);

      case RtlSdrSettingId.biasT:
        biasT = jsonBool(value, biasT);
        if (_running && dev != null) {
          dev.setBiasTee(biasT ? 1 : 0);
        }
        _saveDev('biasT', biasT);

      case RtlSdrSettingId.offsetTuning:
        offsetTuning = jsonBool(value, offsetTuning);
        if (_running && dev != null) {
          dev.setOffsetTuning(offsetTuning ? 1 : 0);
        }
        _saveDev('offsetTuning', offsetTuning);

      case RtlSdrSettingId.rtlAgc:
        rtlAgc = jsonBool(value, rtlAgc);
        if (_running && dev != null) {
          dev.setAgcMode(rtlAgc ? 1 : 0);
        }
        _saveDev('rtlAgc', rtlAgc);

      case RtlSdrSettingId.tunerAgc:
        tunerAgc = jsonBool(value, tunerAgc);
        if (_running && dev != null) {
          if (tunerAgc) {
            dev.setTunerGainMode(0);
          } else {
            dev.setTunerGainMode(1);
            dev.setTunerGain(gainList[gainId]);
          }
        }
        _saveDev('tunerAgc', tunerAgc);

      default:
        throw ArgumentError.value(id, 'id', 'unknown RTL-SDR setting');
    }
  }

  // ---- worker / asyncHandler ----------------------------------------------

  /// worker(): rtlsdr_reset_buffer + rtlsdr_read_async until cancelled.
  Future<int> worker(RtlSdrDev dev) async {
    dev.resetBuffer();
    final r = await dev.readAsync(asyncHandler, 0, asyncCount);
    // Dart: read_async ended on its own (device lost / submit failure)
    if (_running && identical(dev, openDev)) {
      if (r == -1 || dev.devLost != 0) {
        _deviceLost(UsbException(UsbError.noDevice, 'RTL-SDR device lost'));
      } else if (r != 0) {
        _fail('RTL-SDR streaming failed ($r)', r);
      }
    }
    return r;
  }

  void asyncHandler(UsbBlock block) {
    final sink = _sink;
    if (sink == null) return; // stream.stopWriter()
    final len = block.length;
    if (_writeBuf.length < len) _writeBuf = Float32List(len);
    final buf = Pointer<Uint8>.fromAddress(block.address).asTypedList(len);
    final sampCount = rtlsdrConvertU8ToF32(buf, len, _writeBuf);
    sink(_writeBuf, sampCount); // stream.swap(sampCount)
  }

  void updateGainTxt() {
    dbTxt = gainList.isEmpty
        ? '--'
        : '${(gainList[gainId] / 10.0).toStringAsFixed(1)} dB';
  }

  // ---- Dart-only: error reporting -----------------------------------------

  void _deviceLost(Object error) {
    if (!_running || _errorReported) return;
    _errorReported = true;
    SourceLog.error("RTLSDRSourceModule '$name': device lost ($error)");
    onError?.call('RTL-SDR device disconnected', error, fatal: true);
    unawaited(stop());
  }

  void _fail(String message, Object error) {
    if (!_running || _errorReported) return;
    _errorReported = true;
    SourceLog.error("RTLSDRSourceModule '$name': $message");
    onError?.call(message, error, fatal: true);
    unawaited(stop());
  }

  // ---- config persistence --------------------------------------------------

  @override
  Map<String, Object?> saveConfig() => deepCopyJson(config.conf);

  @override
  void restoreConfig(Map<String, Object?> conf) {
    config.conf = deepCopyJson(rtlSdrDefaultConfig());
    config.load(conf);
    if (_running) return;
    final d = config.conf['device'];
    selectByName(d is String ? d : selectedDevName);
  }
}

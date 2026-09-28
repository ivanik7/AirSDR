// Dart port of the SDR++ HackRF source module.
//
// Source: ~/prj/sdrpp/source_modules/hackrf_source/src/main.cpp (436 lines,
// SDR++ by Ryzerth, GPL-3.0). Section map (C++ line numbers):
//   sampleRates / bandwidths (+ txt) .......................... 30-79
//   constructor / destructor .................................. 83-115
//   refresh (Android branch: one device per fd) ............... 131-159
//   selectFirst / selectBySerial .............................. 161-224
//   menuSelected / menuDeselected ............................. 227-236
//   bandwidthIdToBw ........................................... 238-241
//   start ...................................................... 243-274
//   stop ....................................................... 276-288
//   tune ....................................................... 290-297
//   menuHandler -> settings / applySetting .................... 299-382
//   callback (int8 -> float, volk_8i_s32f_convert_32f) ........ 384-389
//   _INIT_ (config defaults) ................................... 416-423
//
// Call order of start() (also in STATUS-hackrf.md): open (hackrf_open_by_fd ->
// hackrfOpenSetup) -> setSampleRate -> setBasebandFilterBandwidth(bw or
// hackrfComputeBasebandFilterBw(sr)) -> setFreq -> setAntennaEnable ->
// setAmpEnable -> setLnaGain -> setVgaGain -> startRx(callback).
// stop() = hackrf_close() (sends transceiver OFF, cancels transfers), there is
// no explicit hackrf_stop_rx in SDR++.
//
// Differences from C++ (forced by the Dart runtime, see docs/10-architecture.md
// and the header of rtl_sdr_source.dart): fd from [UsbSourceParams], sink
// instead of dsp::stream, declarative settings, [SourceModuleConfig], device
// loss reported through [onError] + clean self-stop. The Android device list
// entry uses the USB serial (when Android exposes it) as config key instead of
// SDR++'s constant "fake_serial", so settings are kept per board.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import '../../../drivers/hackrf/hackrf.dart';
import '../../../drivers/hackrf/hackrf_convert.dart';
import '../../../usb/usb_transport.dart';
import '../../signal_path/source_handler.dart';
import 'usb_source.dart';

const List<String> hackrfAggModesStr = ['Off', 'Low', 'High'];

const List<String> hackrfSampleRatesTxt = [
  '20MHz',
  '16MHz',
  '10MHz',
  '8MHz',
  '5MHz',
  '4MHz',
  '2MHz',
];

const List<int> hackrfSampleRates = [
  20000000,
  16000000,
  10000000,
  8000000,
  5000000,
  4000000,
  2000000,
];

const List<int> hackrfBandwidths = [
  1750000,
  2500000,
  3500000,
  5000000,
  5500000,
  6000000,
  7000000,
  8000000,
  9000000,
  10000000,
  12000000,
  14000000,
  15000000,
  20000000,
  24000000,
  28000000,
];

const List<String> hackrfBandwidthsTxt = [
  '1.75MHz',
  '2.5MHz',
  '3.5MHz',
  '5MHz',
  '5.5MHz',
  '6MHz',
  '7MHz',
  '8MHz',
  '9MHz',
  '10MHz',
  '12MHz',
  '14MHz',
  '15MHz',
  '20MHz',
  '24MHz',
  '28MHz',
  'Auto',
];

/// SourceSetting ids of the HackRF module.
abstract final class HackrfSettingId {
  static const device = SourceSettingId.device;
  static const sampleRate = SourceSettingId.sampleRate;
  static const refresh = SourceSettingId.refresh;
  static const bandwidth = 'bandwidth';
  static const lnaGain = 'lnaGain';
  static const vgaGain = 'vgaGain';
  static const biasT = 'biasT';
  static const amp = 'amp';
}

/// _INIT_(): `def["devices"] = {}; def["device"] = "";`
Map<String, Object?> hackrfDefaultConfig() => {
  'devices': <String, Object?>{},
  'device': '',
};

/// ImGui::SliderFloatWithSteps quantisation (gui/widgets/stepped_slider.cpp):
/// v_i = int((v - v_min) / v_step), clamped by the slider to [0, N];
/// v = v_min + float(v_i) * v_step.
double sliderFloatWithSteps(double v, double vMin, double vMax, double vStep) {
  final countValues = ((vMax - vMin) / vStep).truncate();
  var vI = ((v - vMin) / vStep).truncate();
  if (vI < 0) vI = 0;
  if (vI > countValues) vI = countValues;
  return vMin + vI * vStep;
}

class HackrfSourceModule implements UsbSourceModule {
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

  HackrfDevice? openDev;
  bool enabled = true;
  int _sampleRate;
  bool _running = false;
  double freq = 100e6;
  String selectedSerial = '';
  int devId = 0;
  int srId = 0;
  int bwId = 16;
  bool biasT = false;
  bool amp = false;
  double lna = 0;
  double vga = 0;

  final List<String> devList = [];

  /// devListTxt entries (display names).
  final List<String> devListTxt = [];

  // Dart runtime state
  SourceSink? _sink;
  Float32List _writeBuf = Float32List(0);
  WatchedUsbDeviceHandle? _usb;
  Future<void> _serial = Future<void>.value();
  bool _errorReported = false;

  HackrfSourceModule(
    this.name,
    this.core,
    this.params, {
    UsbDeviceOpener? opener,
    Map<String, Object?>? savedConfig,
    this.onConfigChanged,
    this.onError,
  }) : opener = opener ?? defaultUsbDeviceOpener,
       config = SourceModuleConfig(hackrfDefaultConfig(), savedConfig),
       // Select the last samplerate option
       _sampleRate = 2000000 {
    config.onChanged = (c) => onConfigChanged?.call(c);

    hackrfInit();

    srId = 6;

    refresh();

    config.acquire();
    final confSerial = config.conf['device'];
    config.release();
    selectBySerial(confSerial is String ? confSerial : '');
  }

  /// Construct from the plain map sent by the UI isolate:
  /// `{fd, vid, pid, deviceName, serial, manufacturer, product}`.
  factory HackrfSourceModule.fromParams(
    Map<Object?, Object?> params,
    SourceCore core, {
    String name = 'HackRF',
    UsbDeviceOpener? opener,
    Map<String, Object?>? savedConfig,
    void Function(Map<String, Object?> config)? onConfigChanged,
    SourceErrorCallback? onError,
  }) => HackrfSourceModule(
    name,
    core,
    UsbSourceParams.fromMap(params),
    opener: opener,
    savedConfig: savedConfig,
    onConfigChanged: onConfigChanged,
    onError: onError,
  );

  @override
  String get sourceName => 'HackRF';

  @override
  bool get running => _running;

  @override
  double get sampleRate => _sampleRate.toDouble();

  @override
  List<String> get deviceNames => List.unmodifiable(devListTxt);

  /// ~HackRFSourceModule
  @override
  Future<void> dispose() async {
    await stop();
    hackrfExit();
  }

  void enable() {
    enabled = true;
  }

  void disable() {
    enabled = false;
  }

  bool isEnabled() => enabled;

  /// Serial used as config key: the USB serial string (32 hex digits on
  /// HackRF), SDR++'s "fake_serial" when Android does not expose it.
  static String serialFor(UsbSourceParams p) =>
      (p.serial != null && p.serial!.isNotEmpty) ? p.serial! : 'fake_serial';

  /// Display name: desktop SDR++ shows `serial_numbers[i] + 16` (the last 16
  /// digits); Android shows "HackRF USB".
  static String displayNameFor(UsbSourceParams p) {
    final s = p.serial;
    if (s == null || s.isEmpty) return 'HackRF USB';
    return s.length > 16 ? s.substring(16) : s;
  }

  @override
  void refresh() {
    devList.clear();
    devListTxt.clear();

    final p = params;
    if (p == null || p.fd < 0) return;
    devList.add(serialFor(p));
    devListTxt.add(displayNameFor(p));
  }

  void selectFirst() {
    if (devList.isNotEmpty) {
      selectBySerial(devList[0]);
      return;
    }
    selectedSerial = '';
  }

  void selectBySerial(String serial) {
    if (!devList.contains(serial)) {
      selectFirst();
      return;
    }

    // C++: `created` is never set to true, so creating the defaults does not
    // trigger a save (kept 1:1).
    const created = false;
    config.acquire();
    if (!config.devices.containsKey(serial)) {
      config.device(serial)
        ..['sampleRate'] = 2000000
        ..['biasT'] = false
        ..['amp'] = false
        ..['lnaGain'] = 0
        ..['vgaGain'] = 0
        ..['bandwidth'] = 16;
    }
    config.release(created);

    // Set default values
    srId = 0;
    _sampleRate = 2000000;
    biasT = false;
    amp = false;
    lna = 0;
    vga = 0;
    bwId = 16;

    // Load from config if available and validate
    final c = config.device(serial);
    if (c.containsKey('sampleRate')) {
      final psr = jsonInt(c['sampleRate'], 0);
      for (var i = 0; i < 7; i++) {
        if (hackrfSampleRates[i] == psr) {
          _sampleRate = psr;
          srId = i;
        }
      }
    }
    if (c.containsKey('biasT')) {
      biasT = jsonBool(c['biasT'], biasT);
    }
    if (c.containsKey('amp')) {
      amp = jsonBool(c['amp'], amp);
    }
    if (c.containsKey('lnaGain')) {
      lna = jsonDouble(c['lnaGain'], lna);
    }
    if (c.containsKey('vgaGain')) {
      vga = jsonDouble(c['vgaGain'], vga);
    }
    if (c.containsKey('bandwidth')) {
      bwId = jsonInt(c['bandwidth'], bwId);
      bwId = bwId.clamp(0, 16);
    }

    selectedSerial = serial;
  }

  /// menuSelected
  @override
  void select() {
    core.setInputSampleRate(sampleRate);
    SourceLog.info("HackRFSourceModule '$name': Menu Select!");
  }

  /// menuDeselected
  @override
  void deselect() {
    SourceLog.info("HackRFSourceModule '$name': Menu Deselect!");
  }

  int bandwidthIdToBw(int id) {
    if (id == 16) {
      return hackrfComputeBasebandFilterBw(_sampleRate);
    }
    return hackrfBandwidths[id];
  }

  Future<void> _serialize(FutureOr<void> Function() f) {
    final next = _serial.then((_) => f());
    _serial = next.catchError((Object _) {});
    return next;
  }

  /// hackrf_open_by_fd(devFd, &dev)
  (int, HackrfDevice?, WatchedUsbDeviceHandle?) _openByFd() {
    final p = params;
    if (p == null) return (hackrfErrorNotFound, null, null);
    late final WatchedUsbDeviceHandle usb;
    try {
      usb = WatchedUsbDeviceHandle(opener(p), (e) {
        if (identical(usb, _usb)) _deviceLost(e);
      });
    } on UsbException catch (e) {
      lastLibusbError = e.code;
      return (hackrfErrorLibusb, null, null);
    } on Object {
      return (hackrfErrorOther, null, null);
    }
    final (err, dev) = hackrfOpenSetup(usb);
    return (err, dev, usb);
  }

  @override
  Future<void> start(SourceSink sink) => _serialize(() => _start(sink));

  Future<void> _start(SourceSink sink) async {
    if (_running) return;
    if (selectedSerial == '') {
      SourceLog.error('Tried to start HackRF source with empty serial');
      onError?.call('No HackRF selected', null, fatal: false);
      return;
    }

    final (err, dev, usb) = _openByFd();
    if (err != hackrfSuccess || dev == null) {
      SourceLog.error(
        'Could not open HackRF $selectedSerial: ${hackrfErrorName(err)}',
      );
      onError?.call(
        'Could not open HackRF: ${hackrfErrorName(err)}',
        err,
        fatal: false,
      );
      return;
    }
    openDev = dev;
    _usb = usb;
    _errorReported = false;

    dev.setSampleRate(_sampleRate.toDouble());
    dev.setBasebandFilterBandwidth(bandwidthIdToBw(bwId));
    dev.setFreq(_u64(freq));

    dev.setAntennaEnable(biasT ? 1 : 0);
    dev.setAmpEnable(amp ? 1 : 0);
    dev.setLnaGain(_u32(lna));
    dev.setVgaGain(_u32(vga));

    _writeBuf = Float32List(transferBufferSize);
    _sink = sink;
    final r = await dev.startRx(callback, this);
    if (r != hackrfSuccess) {
      // C++ ignores the result; report it (the device would stay silent).
      SourceLog.error('hackrf_start_rx failed: ${hackrfErrorName(r)}');
      _sink = null;
      await dev.close();
      openDev = null;
      _usb = null;
      onError?.call(
        'Could not start HackRF: ${hackrfErrorName(r)}',
        r,
        fatal: false,
      );
      return;
    }

    _running = true;
    SourceLog.info("HackRFSourceModule '$name': Start!");
  }

  @override
  Future<void> stop() => _serialize(_stop);

  Future<void> _stop() async {
    if (!_running) return;
    _running = false;
    _sink = null; // stream.stopWriter()
    // TODO: Stream stop
    final err = await openDev!.close();
    if (err != hackrfSuccess) {
      SourceLog.error(
        'Could not close HackRF $selectedSerial: ${hackrfErrorName(err)}',
      );
    }
    openDev = null;
    _usb = null;
    SourceLog.info("HackRFSourceModule '$name': Stop!");
  }

  /// C++ implicit double -> uint64_t conversion.
  static int _u64(double f) => f < 0 ? 0 : f.truncate();

  /// C++ implicit float -> uint32_t conversion.
  static int _u32(double f) => f < 0 ? 0 : f.truncate() & 0xffffffff;

  @override
  void tune(double freq) {
    final dev = openDev;
    if (_running && dev != null) {
      dev.setFreq(_u64(freq));
    }
    this.freq = freq;
    SourceLog.info("HackRFSourceModule '$name': Tune: $freq!");
  }

  // ---- menuHandler ---------------------------------------------------------

  @override
  List<SourceSetting> get settings => [
    ChoiceSetting(HackrfSettingId.device, 'Device', deviceNames, devId),
    ChoiceSetting(
      HackrfSettingId.sampleRate,
      'Sample Rate',
      hackrfSampleRatesTxt,
      srId,
    ),
    ChoiceSetting(
      HackrfSettingId.bandwidth,
      'Bandwidth',
      hackrfBandwidthsTxt,
      bwId,
    ),
    SliderSetting(
      HackrfSettingId.lnaGain,
      'LNA Gain',
      min: 0,
      max: 40,
      step: 8,
      value: lna,
    ),
    SliderSetting(
      HackrfSettingId.vgaGain,
      'VGA Gain',
      min: 0,
      max: 62,
      step: 2,
      value: vga,
    ),
    BoolSetting(HackrfSettingId.biasT, 'Bias-T', biasT),
    BoolSetting(HackrfSettingId.amp, 'Amp Enabled', amp),
  ];

  void _saveDev(String key, Object? value) {
    config.acquire();
    config.device(selectedSerial)[key] = value;
    config.release(true);
  }

  @override
  void applySetting(String id, Object value) {
    final dev = openDev;
    switch (id) {
      case HackrfSettingId.device:
        if (_running) return; // BeginDisabled
        final i = jsonInt(value, devId);
        if (i < 0 || i >= devList.length) return;
        devId = i;
        selectBySerial(devList[devId]);
        core.setInputSampleRate(sampleRate);
        config.acquire();
        config.conf['device'] = selectedSerial;
        config.release(true);

      case HackrfSettingId.sampleRate:
        if (_running) return; // BeginDisabled
        final i = jsonInt(value, srId);
        if (i < 0 || i >= hackrfSampleRates.length) return;
        srId = i;
        _sampleRate = hackrfSampleRates[srId];
        core.setInputSampleRate(sampleRate);
        _saveDev('sampleRate', _sampleRate);

      case HackrfSettingId.refresh:
        if (_running) return; // BeginDisabled
        refresh();
        selectBySerial(selectedSerial);
        core.setInputSampleRate(sampleRate);

      case HackrfSettingId.bandwidth:
        final i = jsonInt(value, bwId);
        if (i < 0 || i > 16) return;
        bwId = i;
        if (_running && dev != null) {
          dev.setBasebandFilterBandwidth(bandwidthIdToBw(bwId));
        }
        _saveDev('bandwidth', bwId);

      case HackrfSettingId.lnaGain:
        lna = sliderFloatWithSteps(jsonDouble(value, lna), 0, 40, 8);
        if (_running && dev != null) {
          dev.setLnaGain(_u32(lna));
        }
        _saveDev('lnaGain', lna.truncate());

      case HackrfSettingId.vgaGain:
        vga = sliderFloatWithSteps(jsonDouble(value, vga), 0, 62, 2);
        if (_running && dev != null) {
          dev.setVgaGain(_u32(vga));
        }
        _saveDev('vgaGain', vga.truncate());

      case HackrfSettingId.biasT:
        biasT = jsonBool(value, biasT);
        if (_running && dev != null) {
          dev.setAntennaEnable(biasT ? 1 : 0);
        }
        _saveDev('biasT', biasT);

      case HackrfSettingId.amp:
        amp = jsonBool(value, amp);
        if (_running && dev != null) {
          dev.setAmpEnable(amp ? 1 : 0);
        }
        _saveDev('amp', amp);

      default:
        throw ArgumentError.value(id, 'id', 'unknown HackRF setting');
    }
  }

  // ---- callback -------------------------------------------------------------

  int callback(HackrfTransfer transfer) {
    final sink = _sink;
    if (sink == null) return -1; // !stream.swap(): writer stopped
    final len = transfer.validLength;
    if (_writeBuf.length < len) _writeBuf = Float32List(len);
    // volk_8i_s32f_convert_32f(writeBuf, buffer, 128.0f, valid_length)
    final count = hackrfConvertS8ToF32(transfer.buffer, len, _writeBuf);
    sink(_writeBuf, count); // stream.swap(valid_length / 2)
    return 0;
  }

  // ---- Dart-only: error reporting -----------------------------------------

  void _deviceLost(Object error) {
    if (!_running || _errorReported) return;
    _errorReported = true;
    SourceLog.error("HackRFSourceModule '$name': device lost ($error)");
    onError?.call('HackRF device disconnected', error, fatal: true);
    unawaited(stop());
  }

  // ---- config persistence --------------------------------------------------

  @override
  Map<String, Object?> saveConfig() => deepCopyJson(config.conf);

  @override
  void restoreConfig(Map<String, Object?> conf) {
    config.conf = deepCopyJson(hackrfDefaultConfig());
    config.load(conf);
    if (_running) return;
    final d = config.conf['device'];
    selectBySerial(d is String ? d : selectedSerial);
  }
}

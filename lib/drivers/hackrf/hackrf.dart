// Dart port of the libhackrf RX subset.
//
// Source: ~/prj/ref/hackrf/host/libhackrf/src/hackrf.c (+ hackrf.h),
// greatscottgadgets/hackrf @ 7f96cc8. Ported functions and their C lines:
//   vendor requests / constants ........... hackrf.c:57-148, hackrf.h:511-860
//   max2837_ft table ...................... hackrf.c:175-196
//   cancel_transfers / prepare_transfers .. hackrf.c:219-443
//   set_hackrf_configuration .............. hackrf.c:445-506
//   hackrf_init / hackrf_exit ............. hackrf.c:512-540
//   hackrf_open_setup ..................... hackrf.c:718-836
//   hackrf_set_transceiver_mode ........... hackrf.c:943-965
//   hackrf_set_baseband_filter_bandwidth .. hackrf.c:1156-1178
//   hackrf_board_id_read .................. hackrf.c:1713-1732
//   hackrf_version_string_read ............ hackrf.c:1734-1757
//   hackrf_usb_api_version_read ........... hackrf.c:1759-1765
//   hackrf_set_freq(_explicit) ............ hackrf.c:1767-1867
//   hackrf_set_sample_rate(_manual) ....... hackrf.c:1869-1959
//   hackrf_set_amp_enable ................. hackrf.c:1961-1981
//   hackrf_board_partid_serialno_read ..... hackrf.c:1983-2020
//   hackrf_set_lna_gain / vga_gain ........ hackrf.c:2022-2074
//   hackrf_set_antenna_enable ............. hackrf.c:2102-2122
//   transfer callback / thread ............ hackrf.c:2124-2317
//   hackrf_is_streaming ................... hackrf.c:2319-2337
//   hackrf_start_rx / stop_rx ............. hackrf.c:2339-2379
//   hackrf_close .......................... hackrf.c:2467-2501
//   hackrf_error_name / board_id_name ..... hackrf.c:2503-2645
//   hackrf_compute_baseband_filter_bw* .... hackrf.c:2647-2683
//   hackrf_get_transfer_buffer_size/depth . hackrf.c:3225-3239
//   hackrf_board_rev_read ................. hackrf.c:3241-3261
//
// Differences from C, forced by the UsbDeviceHandle contract:
//  * The device is opened on an already opened [UsbDeviceHandle]
//    (Android: fd from UsbManager), i.e. this is hackrf_open_setup(); device
//    enumeration (hackrf_device_list, hackrf_open_by_serial) is not ported.
//  * libusb_get_configuration() is issued as the standard GET_CONFIGURATION
//    control request (0x80/0x08, 1 byte), the contract has no getter.
//  * detach_kernel_drivers() is a no-op (the contract cannot query kernel
//    drivers; on Android none is bound, libusb returns NOT_SUPPORTED there).
//  * libusb errors arrive as [UsbException]; they are converted back to the
//    negative libusb return value so the C control flow is kept 1:1.
//  * The libusb event thread + TRANSFER_COUNT transfers are replaced by
//    [UsbDeviceHandle.openBulkIn] (reader isolate, same count/size). Therefore
//    startRx/stopRx/close are async (Future<int>).
//  * Calls after close() return LIBUSB_ERROR_NO_DEVICE instead of crashing.
//
// Copyright (c) 2012-2026 Great Scott Gadgets <info@greatscottgadgets.com>
// Copyright (c) 2012, Jared Boone <jared@sharebrained.com>
// Copyright (c) 2013, Benjamin Vernoux <titanmkd@gmail.com>
// (BSD-3-Clause, see hackrf.c); Dart port part of sdr_flutter, GPL-3.0.

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import '../../usb/usb_transport.dart';

// ---------------------------------------------------------------------------
// hackrf.h: enum hackrf_error
// ---------------------------------------------------------------------------

/// No error happened
const int hackrfSuccess = 0;

/// TRUE value, returned by some functions that return boolean value.
const int hackrfTrue = 1;

/// The function was called with invalid parameters.
const int hackrfErrorInvalidParam = -2;

/// USB device not found, returned at opening.
const int hackrfErrorNotFound = -5;

/// Resource is busy, possibly the device is already opened.
const int hackrfErrorBusy = -6;

/// Memory allocation (on host side) failed
const int hackrfErrorNoMem = -11;

/// LibUSB error, use [hackrfErrorName] to get a human-readable error string
/// (using `libusb_strerror`)
const int hackrfErrorLibusb = -1000;

/// Error setting up transfer thread (pthread-related error)
const int hackrfErrorThread = -1001;

/// Streaming thread could not start due to an error
const int hackrfErrorStreamingThreadErr = -1002;

/// Streaming thread stopped due to an error
const int hackrfErrorStreamingStopped = -1003;

/// Streaming thread exited (normally)
const int hackrfErrorStreamingExitCalled = -1004;

/// The installed firmware does not support this function
const int hackrfErrorUsbApiVersion = -1005;

/// Can not exit library as one or more HackRFs still in use
const int hackrfErrorNotLastDevice = -2000;

/// Unspecified error
const int hackrfErrorOther = -9999;

// ---------------------------------------------------------------------------
// hackrf.h: platforms, board ids, usb board ids, rf path filter
// ---------------------------------------------------------------------------

const int hackrfPlatformJawbreaker = 1 << 0;
const int hackrfPlatformHackrf1Og = 1 << 1;
const int hackrfPlatformRad1o = 1 << 2;
const int hackrfPlatformHackrf1R9 = 1 << 3;
const int hackrfPlatformPraline = 1 << 4;

/// enum hackrf_board_id
const int boardIdJellybean = 0;
const int boardIdJawbreaker = 1;
const int boardIdHackrf1Og = 2;
const int boardIdRad1o = 3;
const int boardIdHackrf1R9 = 4;
const int boardIdPraline = 5;
const int boardIdUnrecognized = 0xFE;
const int boardIdUndetected = 0xFF;
const int boardIdHackrfOne = boardIdHackrf1Og;
const int boardIdInvalid = boardIdUndetected;

/// enum hackrf_usb_board_id
const int usbBoardIdJawbreaker = 0x604B;
const int usbBoardIdHackrfOne = 0x6089;
const int usbBoardIdRad1o = 0xCC15;
const int usbBoardIdInvalid = 0xFFFF;

/// enum rf_path_filter
const int rfPathFilterBypass = 0;
const int rfPathFilterLowPass = 1;
const int rfPathFilterHighPass = 2;

// ---------------------------------------------------------------------------
// hackrf.c private definitions
// ---------------------------------------------------------------------------

const int defaultRequestTimeout = 100;

// TODO: Factor this into a shared #include so that firmware can use
// the same values.
abstract final class HackrfVendorRequest {
  static const setTransceiverMode = 1;
  static const sampleRateSet = 6;
  static const basebandFilterBandwidthSet = 7;
  static const boardIdRead = 14;
  static const versionStringRead = 15;
  static const setFreq = 16;
  static const ampEnable = 17;
  static const boardPartidSerialnoRead = 18;
  static const setLnaGain = 19;
  static const setVgaGain = 20;
  static const antennaEnable = 23;
  static const setFreqExplicit = 24;
  static const boardRevRead = 45;
  static const getBufferSize = 61;
}

const int usbConfigStandard = 0x1;

const int rxEndpointAddress = UsbReqType.endpointIn | 1;
const int txEndpointAddress = UsbReqType.endpointOut | 2;

/// hackrf_transceiver_mode
const int hackrfTransceiverModeOff = 0;
const int hackrfTransceiverModeReceive = 1;
const int hackrfTransceiverModeTransmit = 2;

const int transferCount = 4;
const int transferBufferSize = 262144;
const int usbMaxSerialLength = 32;

const int hackrfUsbVid = 0x1d50;
const int hackrfJawbreakerUsbPid = 0x604b;
const int hackrfOneUsbPid = 0x6089;
const int rad1oUsbPid = 0xcc15;

/// max2837_ft[] (bandwidth_hz), 0-terminated like in C.
const List<int> max2837Ft = [
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
  0,
];

const int _freqOneMhz = 1000 * 1000;

const int _vendorOut =
    UsbReqType.endpointOut | UsbReqType.typeVendor | UsbReqType.recipientDevice;
const int _vendorIn =
    UsbReqType.endpointIn | UsbReqType.typeVendor | UsbReqType.recipientDevice;

int _openDevices = 0;

/// `last_libusb_error` (global in hackrf.c).
int lastLibusbError = 0; // LIBUSB_SUCCESS

// ---------------------------------------------------------------------------
// hackrf.h structs
// ---------------------------------------------------------------------------

/// USB transfer information passed to RX callback (hackrf_transfer).
/// A callback should treat all these fields as read-only.
class HackrfTransfer {
  /// HackRF USB device for this transfer
  final HackrfDevice device;

  /// Native address of the transfer data buffer (interleaved 8 bit I/Q samples)
  final int address;

  /// length of data buffer in bytes
  final int bufferLength;

  /// number of buffer bytes that were transferred
  int validLength;

  /// User provided RX context.
  final Object? rxCtx;

  HackrfTransfer(
    this.device,
    this.address,
    this.bufferLength,
    this.validLength,
    this.rxCtx,
  );

  /// View on the native buffer ([validLength] bytes); valid only during the
  /// callback (the slot is resubmitted afterwards).
  Uint8List get buffer =>
      Pointer<Uint8>.fromAddress(address).asTypedList(validLength);

  /// Signed view (int8 I/Q) of the same bytes.
  Int8List get bufferInt8 =>
      Pointer<Int8>.fromAddress(address).asTypedList(validLength);
}

/// read_partid_serialno_t: MCU (LPC43xx) part ID and serial number.
class ReadPartidSerialno {
  /// MCU part ID register value
  final List<int> partId; // uint32_t[2]
  /// MCU device unique ID (serial number)
  final List<int> serialNo; // uint32_t[4]
  const ReadPartidSerialno(this.partId, this.serialNo);
}

/// hackrf_sample_block_cb_fn: return 0 to continue, nonzero to stop.
typedef HackrfSampleBlockCb = int Function(HackrfTransfer transfer);

// ---------------------------------------------------------------------------
// library functions
// ---------------------------------------------------------------------------

/// hackrf_init(): libusb context is owned by the transport, nothing to do.
int hackrfInit() => hackrfSuccess;

/// hackrf_exit()
int hackrfExit() {
  if (_openDevices == 0) {
    return hackrfSuccess;
  } else {
    return hackrfErrorNotLastDevice;
  }
}

/// Open a HackRF on an already opened USB handle (Android fd) —
/// hackrf_open_setup(). Returns (result, device).
(int, HackrfDevice?) hackrfOpenSetup(UsbDeviceHandle usbDevice) =>
    HackrfDevice.openSetup(usbDevice);

/// True if (vid, pid) is a HackRF (hackrf_open / hackrf_device_list filter).
bool hackrfIsHackrfUsbId(int vid, int pid) =>
    vid == hackrfUsbVid &&
    (pid == hackrfOneUsbPid ||
        pid == hackrfJawbreakerUsbPid ||
        pid == rad1oUsbPid);

/// Return final bw round down and less than expected bw.
int hackrfComputeBasebandFilterBwRoundDownLt(int bandwidthHz) {
  bandwidthHz = bandwidthHz.toUnsigned(32);
  var p = 0;
  while (max2837Ft[p] != 0) {
    if (max2837Ft[p] >= bandwidthHz) {
      break;
    }
    p++;
  }
  /* Round down (if no equal to first entry) */
  if (p != 0) {
    p--;
  }
  return max2837Ft[p];
}

/// Return final bw.
int hackrfComputeBasebandFilterBw(int bandwidthHz) {
  bandwidthHz = bandwidthHz.toUnsigned(32);
  var p = 0;
  while (max2837Ft[p] != 0) {
    if (max2837Ft[p] >= bandwidthHz) {
      break;
    }
    p++;
  }

  /* Round down (if no equal to first entry) and if > bandwidth_hz */
  if (p != 0) {
    if (max2837Ft[p] > bandwidthHz) p--;
  }

  return max2837Ft[p];
}

/// English strings of libusb_strerror() (libusb/strerror.c).
String libusbStrerror(int errcode) {
  switch (errcode) {
    case 0:
      return 'Success';
    case UsbError.io:
      return 'Input/Output Error';
    case UsbError.invalidParam:
      return 'Invalid parameter';
    case UsbError.access:
      return 'Access denied (insufficient permissions)';
    case UsbError.noDevice:
      return 'No such device (it may have been disconnected)';
    case UsbError.notFound:
      return 'Entity not found';
    case UsbError.busy:
      return 'Resource busy';
    case UsbError.timeout:
      return 'Operation timed out';
    case UsbError.overflow:
      return 'Overflow';
    case UsbError.pipe:
      return 'Pipe error';
    case UsbError.interrupted:
      return 'System call interrupted (perhaps due to signal)';
    case UsbError.noMem:
      return 'Insufficient memory';
    case UsbError.notSupported:
      return 'Operation not supported or unimplemented on this platform';
    case UsbError.other:
      return 'Other error';
    default:
      return '**UNKNOWN**';
  }
}

String hackrfErrorName(int errcode) {
  switch (errcode) {
    case hackrfSuccess:
      return 'HACKRF_SUCCESS';

    case hackrfTrue:
      return 'HACKRF_TRUE';

    case hackrfErrorInvalidParam:
      return 'invalid parameter(s)';

    case hackrfErrorNotFound:
      return 'HackRF not found';

    case hackrfErrorBusy:
      return 'HackRF busy';

    case hackrfErrorNoMem:
      return 'insufficient memory';

    case hackrfErrorLibusb:
      if (lastLibusbError != 0) return libusbStrerror(lastLibusbError);
      return 'USB error';

    case hackrfErrorThread:
      return 'transfer thread error';

    case hackrfErrorStreamingThreadErr:
      return 'streaming thread encountered an error';

    case hackrfErrorStreamingStopped:
      return 'streaming stopped';

    case hackrfErrorStreamingExitCalled:
      return 'streaming terminated';

    case hackrfErrorUsbApiVersion:
      return 'feature not supported by installed firmware';

    case hackrfErrorNotLastDevice:
      return 'one or more HackRFs still in use';

    case hackrfErrorOther:
      return 'unspecified error';

    default:
      return 'unknown error code';
  }
}

String hackrfBoardIdName(int boardId) {
  switch (boardId) {
    case boardIdJellybean:
      return 'Jellybean';

    case boardIdJawbreaker:
      return 'Jawbreaker';

    case boardIdHackrf1Og:
      return 'HackRF One';

    case boardIdRad1o:
      return 'rad1o';

    case boardIdHackrf1R9:
      return 'HackRF One';

    case boardIdPraline:
      return 'HackRF Pro';

    case boardIdUnrecognized:
      return 'unrecognized';

    case boardIdUndetected:
      return 'undetected';

    default:
      return 'unknown';
  }
}

int hackrfBoardIdPlatform(int boardId) {
  switch (boardId) {
    case boardIdJawbreaker:
      return hackrfPlatformJawbreaker;

    case boardIdHackrf1Og:
      return hackrfPlatformHackrf1Og;

    case boardIdRad1o:
      return hackrfPlatformRad1o;

    case boardIdHackrf1R9:
      return hackrfPlatformHackrf1R9;

    case boardIdPraline:
      return hackrfPlatformPraline;

    default:
      return 0;
  }
}

String hackrfUsbBoardIdName(int usbBoardId) {
  switch (usbBoardId) {
    case usbBoardIdJawbreaker:
      return 'Jawbreaker';

    case usbBoardIdHackrfOne:
      return 'HackRF One';

    case usbBoardIdRad1o:
      return 'rad1o';

    case usbBoardIdInvalid:
      return 'Invalid Board ID';

    default:
      return 'Unknown Board ID';
  }
}

String hackrfFilterPathName(int path) {
  switch (path) {
    case rfPathFilterBypass:
      return 'mixer bypass';
    case rfPathFilterLowPass:
      return 'low pass filter';
    case rfPathFilterHighPass:
      return 'high pass filter';
    default:
      return 'invalid filter path';
  }
}

// ---------------------------------------------------------------------------
// struct hackrf_device
// ---------------------------------------------------------------------------

class HackrfDevice {
  UsbDeviceHandle? usbDevice;
  int usbApiVersion = 0;
  HackrfSampleBlockCb? callback;

  /// In C: the libusb event thread is running. Here: between open and close.
  bool transferThreadStarted = false;
  bool streaming = false;
  Object? rxCtx;
  bool doExit = false;

  /// true if the USB transfers have been setup
  bool transfersSetup = false;
  int bufferSize = 0;

  BulkInStream? _transfers;
  StreamSubscription<UsbBlock>? _subscription;
  bool _preparing = false;

  HackrfDevice._(this.usbDevice);

  /// libusb_control_transfer() with libusb return-value semantics.
  int _libusbControlTransfer(
    int requestType,
    int request,
    int value,
    int index,
    Uint8List? data,
    int length,
    int timeout,
  ) {
    final dev = usbDevice;
    if (dev == null) return UsbError.noDevice;
    try {
      return dev.controlTransfer(
        requestType & 0xff,
        request & 0xff,
        value & 0xffff,
        index & 0xffff,
        data ?? Uint8List(0),
        length & 0xffff,
        timeoutMs: timeout,
      );
    } on UsbException catch (e) {
      return e.code;
    }
  }

  // ---- open ---------------------------------------------------------------

  /// libusb_get_configuration(): GET_CONFIGURATION standard request.
  static int _libusbGetConfiguration(UsbDeviceHandle dev, List<int> config) {
    final b = Uint8List(1);
    int r;
    try {
      r = dev.controlTransfer(
        UsbReqType.endpointIn,
        0x08,
        0,
        0,
        b,
        1,
        timeoutMs: 1000,
      );
    } on UsbException catch (e) {
      return e.code;
    }
    if (r != 1) return UsbError.io;
    config[0] = b[0];
    return 0;
  }

  /// detach_kernel_drivers(): kernel driver state is not visible through the
  /// UsbDeviceHandle contract (libusb on Android reports NOT_SUPPORTED, which
  /// hackrf.c treats as success).
  static int _detachKernelDrivers(UsbDeviceHandle usbDeviceHandle) {
    return 0;
  }

  static int _setHackrfConfiguration(UsbDeviceHandle usbDevice, int config) {
    int result;
    final currConfig = [0];

    result = _libusbGetConfiguration(usbDevice, currConfig);
    if (result != 0) {
      lastLibusbError = result;
      return hackrfErrorLibusb;
    }

    if (currConfig[0] != config) {
      result = _detachKernelDrivers(usbDevice);
      if (result != 0) {
        return result;
      }
      try {
        usbDevice.setConfiguration(config);
      } on UsbException catch (e) {
        lastLibusbError = e.code;
        return hackrfErrorLibusb;
      }
    }

    result = _detachKernelDrivers(usbDevice);
    if (result != 0) {
      return result;
    }
    return 0; // LIBUSB_SUCCESS
  }

  static void _libusbClose(UsbDeviceHandle usbDevice) {
    try {
      usbDevice.close();
    } on UsbException {
      // libusb_close() is void
    }
  }

  static void _libusbReleaseInterface(UsbDeviceHandle usbDevice, int n) {
    try {
      usbDevice.releaseInterface(n);
    } on UsbException {
      // return value ignored in hackrf.c
    }
  }

  /// hackrf_open_setup(). Returns (result, device).
  static (int, HackrfDevice?) openSetup(UsbDeviceHandle usbDevice) {
    int result;
    final deviceDescriptor = usbDevice.deviceDescriptor;

    //int speed = libusb_get_device_speed(usb_device);
    // TODO: Error or warning if not high speed USB?

    result = _setHackrfConfiguration(usbDevice, usbConfigStandard);
    if (result != 0) {
      _libusbClose(usbDevice);
      return (result, null);
    }

    try {
      usbDevice.claimInterface(0);
    } on UsbException catch (e) {
      lastLibusbError = e.code;
      _libusbClose(usbDevice);
      return (hackrfErrorLibusb, null);
    }

    final libDevice = HackrfDevice._(usbDevice);
    libDevice.usbApiVersion = deviceDescriptor.bcdDevice;
    libDevice.callback = null;
    libDevice.transferThreadStarted = false;
    libDevice.streaming = false;
    libDevice.doExit = false;

    if (libDevice.usbApiVersion >= 0x0112) {
      // Fetch buffer size from device so we know how many bytes to flush TX with.
      final bufferSize = Uint8List(4);
      result = libDevice._libusbControlTransfer(
        _vendorIn,
        HackrfVendorRequest.getBufferSize,
        0,
        0,
        bufferSize,
        4,
        defaultRequestTimeout,
      );

      if (result < 4) {
        lastLibusbError = result;
        return (hackrfErrorLibusb, null);
      }

      libDevice.bufferSize = ByteData.sublistView(bufferSize)
          .getUint32(0, Endian.little);
    } else {
      // All older firmware uses a fixed 32KB buffer size.
      libDevice.bufferSize = 32768;
    }

    // allocate_transfers(): buffers are allocated by openBulkIn() at start_rx.

    result = libDevice._createTransferThread();
    if (result != 0) {
      _libusbReleaseInterface(usbDevice, 0);
      _libusbClose(usbDevice);
      return (result, null);
    }

    _openDevices++;

    return (hackrfSuccess, libDevice);
  }

  // ---- control requests ---------------------------------------------------

  int setTransceiverMode(int value) {
    int result;
    result = _libusbControlTransfer(
      _vendorOut,
      HackrfVendorRequest.setTransceiverMode,
      value,
      0,
      null,
      0,
      defaultRequestTimeout,
    );

    if (result != 0) {
      lastLibusbError = result;
      return hackrfErrorLibusb;
    } else {
      return hackrfSuccess;
    }
  }

  int setBasebandFilterBandwidth(int bandwidthHz) {
    int result;
    bandwidthHz = bandwidthHz.toUnsigned(32);
    result = _libusbControlTransfer(
      _vendorOut,
      HackrfVendorRequest.basebandFilterBandwidthSet,
      bandwidthHz & 0xffff,
      bandwidthHz >> 16,
      null,
      0,
      defaultRequestTimeout,
    );

    if (result != 0) {
      lastLibusbError = result;
      return hackrfErrorLibusb;
    } else {
      return hackrfSuccess;
    }
  }

  /// hackrf_board_id_read(). Returns (result, value).
  (int, int) boardIdRead() {
    int result;
    final value = Uint8List(1)..[0] = boardIdUndetected;
    result = _libusbControlTransfer(
      _vendorIn,
      HackrfVendorRequest.boardIdRead,
      0,
      0,
      value,
      1,
      defaultRequestTimeout,
    );

    if (result < 1) {
      lastLibusbError = result;
      return (hackrfErrorLibusb, value[0]);
    } else {
      return (hackrfSuccess, value[0]);
    }
  }

  /// hackrf_version_string_read(). Returns (result, version).
  (int, String) versionStringRead([int length = 255]) {
    int result;
    length &= 0xff; // uint8_t length
    final version = Uint8List(length);
    result = _libusbControlTransfer(
      _vendorIn,
      HackrfVendorRequest.versionStringRead,
      0,
      0,
      version,
      length,
      defaultRequestTimeout,
    );

    if (result < 0) {
      lastLibusbError = result;
      return (hackrfErrorLibusb, '');
    } else {
      // version[result] = '\0'; C string ends at the first NUL.
      var n = 0;
      while (n < result && version[n] != 0) {
        n++;
      }
      return (hackrfSuccess, String.fromCharCodes(version, 0, n));
    }
  }

  /// hackrf_usb_api_version_read(). Returns (result, version).
  (int, int) usbApiVersionRead() => (hackrfSuccess, usbApiVersion);

  int setFreq(int freqHz) {
    int lFreqMhz;
    int lFreqHz;
    int length;
    int result;

    /* Convert Freq Hz 64bits to Freq MHz (32bits) & Freq Hz (32bits) */
    lFreqMhz = (freqHz ~/ _freqOneMhz).toUnsigned(32);
    lFreqHz = (freqHz - lFreqMhz * _freqOneMhz).toUnsigned(32);
    final setFreqParams = ByteData(8)
      ..setUint32(0, lFreqMhz, Endian.little)
      ..setUint32(4, lFreqHz, Endian.little);
    length = 8; // sizeof(set_freq_params_t)

    result = _libusbControlTransfer(
      _vendorOut,
      HackrfVendorRequest.setFreq,
      0,
      0,
      setFreqParams.buffer.asUint8List(),
      length,
      defaultRequestTimeout,
    );

    if (result < length) {
      lastLibusbError = result;
      return hackrfErrorLibusb;
    } else {
      return hackrfSuccess;
    }
  }

  int setFreqExplicit(int ifFreqHz, int loFreqHz, int path) {
    int length;
    int result;

    /*
     * Restriction to the range 2170-2740 MHz is strongly recommended for
     * HackRF One and Jawbreaker.  We permit IF as low as 2000 MHz and as
     * high as 3000 MHz for backwards compatibility and for
     * experimentation, but settings outside the recommended range are
     * unlikely to work.
     */
    if (ifFreqHz < 2000000000 || ifFreqHz > 3000000000) {
      return hackrfErrorInvalidParam;
    }

    if ((path != rfPathFilterBypass) &&
        (loFreqHz < 84375000 || loFreqHz > 5400000000)) {
      return hackrfErrorInvalidParam;
    }

    if (path > 2) {
      return hackrfErrorInvalidParam;
    }

    // struct set_freq_explicit_params {u64 if, u64 lo, u8 path} — sizeof 24,
    // the 7 padding bytes are sent as zeros.
    final params = ByteData(24)
      ..setUint64(0, ifFreqHz, Endian.little)
      ..setUint64(8, loFreqHz, Endian.little)
      ..setUint8(16, path & 0xff);
    length = 24;

    result = _libusbControlTransfer(
      _vendorOut,
      HackrfVendorRequest.setFreqExplicit,
      0,
      0,
      params.buffer.asUint8List(),
      length,
      defaultRequestTimeout,
    );

    if (result < length) {
      lastLibusbError = result;
      return hackrfErrorLibusb;
    } else {
      return hackrfSuccess;
    }
  }

  /*
   * You should probably use hackrf_set_sample_rate() below instead of this
   * function.  They both result in automatic baseband filter selection as
   * described below.
   */
  int setSampleRateManual(int freqHz, int divider) {
    int length;
    int result;
    freqHz = freqHz.toUnsigned(32);
    divider = divider.toUnsigned(32);

    final setFracrateParams = ByteData(8)
      ..setUint32(0, freqHz, Endian.little)
      ..setUint32(4, divider, Endian.little);
    length = 8; // sizeof(set_fracrate_params_t)

    result = _libusbControlTransfer(
      _vendorOut,
      HackrfVendorRequest.sampleRateSet,
      0,
      0,
      setFracrateParams.buffer.asUint8List(),
      length,
      defaultRequestTimeout,
    );

    if (result < length) {
      lastLibusbError = result;
      return hackrfErrorLibusb;
    } else {
      return setBasebandFilterBandwidth(
        hackrfComputeBasebandFilterBw(_doubleToUint32(0.75 * freqHz / divider)),
      );
    }
  }

  /*
   * For anti-aliasing, the baseband filter bandwidth is automatically set to the
   * widest available setting that is no more than 75% of the sample rate.  This
   * happens every time the sample rate is set.  If you want to override the
   * baseband filter selection, you must do so after setting the sample rate.
   */
  int setSampleRate(double freq) {
    final (freqHz, divider) = hackrfSampleRateToFracrate(freq);
    return setSampleRateManual(freqHz, divider);
  }

  int setAmpEnable(int value) {
    int result;
    result = _libusbControlTransfer(
      _vendorOut,
      HackrfVendorRequest.ampEnable,
      value & 0xff,
      0,
      null,
      0,
      defaultRequestTimeout,
    );

    if (result != 0) {
      lastLibusbError = result;
      return hackrfErrorLibusb;
    } else {
      return hackrfSuccess;
    }
  }

  /// hackrf_board_partid_serialno_read(). Returns (result, partid/serial).
  (int, ReadPartidSerialno?) boardPartidSerialnoRead() {
    int length;
    int result;

    length = 24; // sizeof(read_partid_serialno_t)
    final buf = Uint8List(length);
    result = _libusbControlTransfer(
      _vendorIn,
      HackrfVendorRequest.boardPartidSerialnoRead,
      0,
      0,
      buf,
      length,
      defaultRequestTimeout,
    );

    if (result < length) {
      lastLibusbError = result;
      return (hackrfErrorLibusb, null);
    } else {
      final bd = ByteData.sublistView(buf);
      int u32(int i) => bd.getUint32(4 * i, Endian.little);
      return (
        hackrfSuccess,
        ReadPartidSerialno([u32(0), u32(1)], [u32(2), u32(3), u32(4), u32(5)]),
      );
    }
  }

  int setLnaGain(int value) {
    int result;
    final retval = Uint8List(1);
    value = value.toUnsigned(32);

    if (value > 40) {
      return hackrfErrorInvalidParam;
    }

    value &= ~0x07;
    result = _libusbControlTransfer(
      _vendorIn,
      HackrfVendorRequest.setLnaGain,
      0,
      value,
      retval,
      1,
      defaultRequestTimeout,
    );

    if (result != 1 || retval[0] == 0) {
      return hackrfErrorInvalidParam;
    } else {
      return hackrfSuccess;
    }
  }

  int setVgaGain(int value) {
    int result;
    final retval = Uint8List(1);
    value = value.toUnsigned(32);

    if (value > 62) {
      return hackrfErrorInvalidParam;
    }

    value &= ~0x01;
    result = _libusbControlTransfer(
      _vendorIn,
      HackrfVendorRequest.setVgaGain,
      0,
      value,
      retval,
      1,
      defaultRequestTimeout,
    );

    if (result != 1 || retval[0] == 0) {
      return hackrfErrorInvalidParam;
    } else {
      return hackrfSuccess;
    }
  }

  /// Bias tee (antenna port power).
  int setAntennaEnable(int value) {
    int result;
    result = _libusbControlTransfer(
      _vendorOut,
      HackrfVendorRequest.antennaEnable,
      value & 0xff,
      0,
      null,
      0,
      defaultRequestTimeout,
    );

    if (result != 0) {
      lastLibusbError = result;
      return hackrfErrorLibusb;
    } else {
      return hackrfSuccess;
    }
  }

  /// hackrf_board_rev_read() (USB API >= 0x0106). Returns (result, value).
  (int, int) boardRevRead() {
    if (usbApiVersion < 0x0106) return (hackrfErrorUsbApiVersion, 0);
    int result;
    final value = Uint8List(1);
    result = _libusbControlTransfer(
      _vendorIn,
      HackrfVendorRequest.boardRevRead,
      0,
      0,
      value,
      1,
      defaultRequestTimeout,
    );

    if (result < 1) {
      lastLibusbError = result;
      return (hackrfErrorLibusb, value[0]);
    } else {
      return (hackrfSuccess, value[0]);
    }
  }

  /// Get USB transfer buffer size. @return size in bytes
  int getTransferBufferSize() => transferBufferSize;

  /// Get the total number of USB transfer buffers.
  int getTransferQueueDepth() => transferCount;

  // ---- streaming ------------------------------------------------------------

  /*
   * Check if the transfers are setup and owned by libusb.
   *
   * Returns true if the device transfers are currently setup
   * in libusb, false otherwise.
   */
  bool _transfersCheckSetup() => _transfers != null && transfersSetup == true;

  /*
   * Cancel any transfers that are in-flight.
   *
   * Returns HACKRF_SUCCESS if OK, HACKRF_ERROR_OTHER if the
   * transfers aren't currently setup.
   */
  Future<int> _cancelTransfers() async {
    // If we're cancelling transfers for any reason, we're shutting down.
    streaming = false;

    if (_transfersCheckSetup() == true) {
      final transfers = _transfers!;
      final subscription = _subscription;
      _transfers = null;
      _subscription = null;
      transfersSetup = false;

      // Cancel all transfers and wait until the reader is gone.
      final done = transfers.cancel();
      await subscription?.cancel();
      await done;

      return hackrfSuccess;
    } else {
      return hackrfErrorOther;
    }
  }

  /// prepare_transfers() for RX: submit TRANSFER_COUNT bulk IN transfers.
  Future<int> _prepareTransfers(int endpointAddress) async {
    final dev = usbDevice;
    if (dev == null) {
      // This shouldn't happen.
      return hackrfErrorOther;
    }

    final BulkInStream transfers;
    try {
      transfers = await dev.openBulkIn(
        endpointAddress,
        numBuffers: transferCount,
        bufferLength: transferBufferSize,
      );
    } on UsbException catch (e) {
      lastLibusbError = e.code;
      return hackrfErrorLibusb;
    }

    _transfers = transfers;
    // For RX, all transfers are ready: ready_transfers == TRANSFER_COUNT.
    streaming = true;
    transfersSetup = true;
    _subscription = transfers.blocks.listen(
      (block) => _hackrfLibusbTransferCallback(transfers, block),
      onError: (Object e) => _hackrfLibusbTransferError(transfers),
      onDone: () => _hackrfLibusbTransferError(transfers),
    );
    return hackrfSuccess;
  }

  void _hackrfLibusbTransferCallback(BulkInStream transfers, UsbBlock block) {
    if (!identical(transfers, _transfers)) {
      transfers.release(block);
      return;
    }
    var resubmit = false;

    final transfer = HackrfTransfer(
      this,
      block.address,
      transferBufferSize,
      block.length,
      rxCtx,
    );

    // success == LIBUSB_TRANSFER_COMPLETED
    if (streaming && (callback!(transfer) == 0) && (transfer.validLength > 0)) {
      resubmit = transfersSetup;
    }

    // If a data transfer was resubmitted successfully, we're done.
    if (!resubmit) {
      // No further calls should be made to the callback.
      streaming = false;
    }
    // The slot always goes back to the reader; with streaming == false no more
    // data is delivered to the callback (C: transfer is not resubmitted).
    transfers.release(block);
  }

  /// Transfer completed with status != LIBUSB_TRANSFER_COMPLETED.
  void _hackrfLibusbTransferError(BulkInStream transfers) {
    if (!identical(transfers, _transfers)) return;
    streaming = false;
  }

  Future<int> _prepareSetupTransfers(
    int endpointAddress,
    HackrfSampleBlockCb callback,
  ) async {
    if (transfersSetup == true || _preparing) {
      return hackrfErrorBusy;
    }

    this.callback = callback;
    _preparing = true;
    try {
      return await _prepareTransfers(endpointAddress);
    } finally {
      _preparing = false;
    }
  }

  int _createTransferThread() {
    if (transferThreadStarted == false) {
      streaming = false;
      doExit = false;
      transferThreadStarted = true;
    } else {
      return hackrfErrorBusy;
    }

    return hackrfSuccess;
  }

  Future<int> _killTransferThread() async {
    if (transferThreadStarted != false) {
      /*
       * Cancel transfers. This call will block until the transfer
       * thread has handled all completion callbacks.
       */
      await _cancelTransfers();

      // Set flag to tell the thread to exit.
      doExit = true;
      transferThreadStarted = false;
    }

    /*
     * Reset do_exit; we're now done here and the thread was
     * already dead or is now dead.
     */
    doExit = false;

    return hackrfSuccess;
  }

  int isStreaming() {
    /* return hackrf is streaming only when streaming, transfer_thread_started are true and do_exit equal false */

    if ((transferThreadStarted == true) &&
        (streaming == true) &&
        (doExit == false)) {
      return hackrfTrue;
    } else {
      if (transferThreadStarted == false) {
        return hackrfErrorStreamingThreadErr;
      }

      if (streaming == false) {
        return hackrfErrorStreamingStopped;
      }

      return hackrfErrorStreamingExitCalled;
    }
  }

  Future<int> startRx(HackrfSampleBlockCb callback, [Object? rxCtx]) async {
    int result;
    const endpointAddress = rxEndpointAddress;
    this.rxCtx = rxCtx;
    result = setTransceiverMode(hackrfTransceiverModeReceive);
    if (result == hackrfSuccess) {
      result = await _prepareSetupTransfers(endpointAddress, callback);
    }
    return result;
  }

  int _hackrfStopCmd() {
    int result;
    result = setTransceiverMode(hackrfTransceiverModeOff);
    return result;
  }

  /*
   * Stop any pending receive.
   *
   * This call stops transfers and halts recieve if it is enabled.
   *
   * It returns HACKRF_SUCCESS if receive was started and it was
   * properly stopped, an error otherwise.
   */
  Future<int> stopRx() async {
    int result;

    result = await _cancelTransfers();
    if (result != hackrfSuccess) {
      return result;
    }

    return _hackrfStopCmd();
  }

  Future<int> close() async {
    int result1, result2;

    result1 = hackrfSuccess;
    result2 = hackrfSuccess;

    result1 = _hackrfStopCmd();

    /*
     * Finally kill the transfer thread, which will
     * also cancel any pending transmit/receive transfers.
     */
    result2 = await _killTransferThread();
    final dev = usbDevice;
    if (dev != null) {
      _libusbReleaseInterface(dev, 0);
      _libusbClose(dev);
      usbDevice = null;
    }

    _openDevices--;

    if (result2 != hackrfSuccess) {
      return result2;
    }
    return result1;
  }
}

// ---------------------------------------------------------------------------
// hackrf_set_sample_rate() fraction computation
// ---------------------------------------------------------------------------

/// (uint32_t) conversion of a double (in-range values: truncation toward 0).
int _doubleToUint32(double d) => d.truncate().toUnsigned(32);

/// C `int` shift `1 << n` with x86 (gcc) semantics: 32-bit, count mod 32.
int _cIntShl1(int n) => (1 << (n & 31)).toSigned(32);

/// The divider search of hackrf_set_sample_rate() (hackrf.c:1920-1959),
/// using the IEEE-754 bit layout of doubles via ByteData.
/// Returns (freq_hz, divider) for hackrf_set_sample_rate_manual().
(int, int) hackrfSampleRateToFracrate(double freq) {
  const maxN = 32;
  int freqHz, divider;
  final double freqFrac = 1.0 + freq - freq.truncate().toSigned(32).toDouble();
  int a, m;
  int i, e;

  final v = ByteData(8);

  v.setFloat64(0, freq, Endian.host);

  e = (v.getUint64(0, Endian.host) >>> 52) - 1023;

  m = ((1 << 52) - 1);

  v.setFloat64(0, freqFrac, Endian.host);
  final vU64 = v.getUint64(0, Endian.host) & m;

  // `int` arithmetic, then sign-extended to uint64_t
  m &= ~(_cIntShl1(e + 4) - 1).toSigned(32);

  a = 0;

  for (i = 1; i < maxN; i++) {
    a += vU64;
    if ((a & m) == 0 || (~a & m) == 0) break;
  }

  if (i == maxN) i = 1;

  freqHz = _doubleToUint32(freq * i + 0.5);
  divider = i;

  return (freqHz, divider);
}

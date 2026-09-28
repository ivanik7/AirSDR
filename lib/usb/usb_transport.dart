// USB transport abstraction used by the Dart ports of librtlsdr / libhackrf.
//
// Semantics mirror libusb's synchronous API (libusb_control_transfer etc.) so that
// driver code can be ported line by line. All calls are synchronous and are meant
// to run in a background isolate (DSP/driver isolate). Errors are reported by
// throwing [UsbException] with a libusb-compatible negative code.
//
// Bulk streaming (rtlsdr_read_async / hackrf transfer thread equivalent) is done by
// [BulkInStream]: a reader isolate keeps N URBs in flight and hands filled native
// buffers to the consumer as [UsbBlock]s; the consumer must [BulkInStream.release]
// each block after use so the slot can be resubmitted.

import 'dart:typed_data';

/// libusb-compatible error codes (negative).
abstract final class UsbError {
  static const io = -1;
  static const invalidParam = -2;
  static const access = -3;
  static const noDevice = -4;
  static const notFound = -5;
  static const busy = -6;
  static const timeout = -7;
  static const overflow = -8;
  static const pipe = -9;
  static const interrupted = -10;
  static const noMem = -11;
  static const notSupported = -12;
  static const other = -99;
}

class UsbException implements Exception {
  final int code; // UsbError.*
  final String message;
  UsbException(this.code, this.message);
  @override
  String toString() => 'UsbException($code): $message';
}

/// bmRequestType helpers (LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_VENDOR ...).
abstract final class UsbReqType {
  static const endpointIn = 0x80;
  static const endpointOut = 0x00;
  static const typeStandard = 0x00;
  static const typeClass = 0x20;
  static const typeVendor = 0x40;
  static const recipientDevice = 0x00;
  static const recipientInterface = 0x01;
  static const recipientEndpoint = 0x02;
}

class UsbDeviceDescriptor {
  final int vendorId;
  final int productId;
  final int bcdDevice;
  final int iManufacturer;
  final int iProduct;
  final int iSerialNumber;
  const UsbDeviceDescriptor({
    required this.vendorId,
    required this.productId,
    this.bcdDevice = 0,
    this.iManufacturer = 0,
    this.iProduct = 0,
    this.iSerialNumber = 0,
  });
}

/// One filled bulk buffer living in native memory.
class UsbBlock {
  /// Slot index inside the stream's buffer pool (pass back to [BulkInStream.release]).
  final int slot;

  /// Native address of the buffer (Pointer<Uint8>.fromAddress(address)).
  final int address;

  /// Number of valid bytes.
  final int length;
  const UsbBlock(this.slot, this.address, this.length);
}

/// Continuous bulk-IN streaming (N transfers in flight).
abstract class BulkInStream {
  /// Filled blocks, in order. Delivered on the isolate that called [UsbDeviceHandle.openBulkIn].
  Stream<UsbBlock> get blocks;

  /// Return a slot to the pool so it can be resubmitted to the device.
  void release(UsbBlock block);

  /// Number of device buffers dropped because no free slot was available.
  int get droppedBuffers;

  /// Cancel all transfers and free native memory. Completes when the reader is gone.
  Future<void> cancel();
}

/// An opened USB device (libusb_device_handle equivalent).
abstract class UsbDeviceHandle {
  UsbDeviceDescriptor get deviceDescriptor;

  /// libusb_control_transfer. For IN transfers [data] receives up to [length] bytes;
  /// for OUT transfers the first [length] bytes of [data] are sent. Returns bytes transferred.
  int controlTransfer(int requestType, int request, int value, int index,
      Uint8List data, int length,
      {int timeoutMs = 1000});

  /// libusb_bulk_transfer (synchronous). Returns bytes transferred.
  int bulkTransfer(int endpoint, Uint8List data, int length,
      {int timeoutMs = 1000});

  void setConfiguration(int configuration);
  void claimInterface(int interfaceNumber);
  void releaseInterface(int interfaceNumber);
  void clearHalt(int endpoint);
  void resetDevice();

  /// libusb_get_string_descriptor_ascii; null if index == 0 or on error.
  String? getStringDescriptorAscii(int index);

  /// Start continuous bulk-IN streaming (rtlsdr_read_async / hackrf RX).
  Future<BulkInStream> openBulkIn(int endpoint,
      {required int numBuffers, required int bufferLength});

  void close();
}

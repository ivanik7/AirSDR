// Descriptor helpers shared by the usbfs transport and the mock transport.
//
// Ports of:
//  * libusb descriptor.c `libusb_get_string_descriptor_ascii()` (libusb master
//    a45bb16, descriptor.c:1332-1389) and libusb.h `libusb_get_string_descriptor()`
//    / `libusb_get_descriptor()` (libusb.h:2257-2285).
//  * libusb descriptor.c device-descriptor parsing (`usbi_parse_descriptor` "bbwbbbbwwwbbbb")
//    for the 18-byte standard device descriptor (USB 2.0 spec §9.6.1).
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'usb_transport.dart';

abstract final class UsbStd {
  static const requestGetDescriptor = 0x06;
  static const dtDevice = 0x01;
  static const dtConfig = 0x02;
  static const dtString = 0x03;
  static const dtDeviceSize = 18;

  /// DESC_HEADER_LENGTH in libusb.
  static const descHeaderLength = 2;
}

/// Parse an 18-byte standard device descriptor (little endian).
/// Throws [UsbException] (io) when the header is invalid.
UsbDeviceDescriptor parseDeviceDescriptor(Uint8List raw) {
  if (raw.length < UsbStd.dtDeviceSize ||
      raw[0] < UsbStd.dtDeviceSize ||
      raw[1] != UsbStd.dtDevice) {
    throw UsbException(
      UsbError.io,
      'invalid device descriptor (len=${raw.length}, bLength=${raw.isEmpty ? -1 : raw[0]})',
    );
  }
  final bd = ByteData.sublistView(raw);
  return UsbDeviceDescriptor(
    vendorId: bd.getUint16(8, Endian.little),
    productId: bd.getUint16(10, Endian.little),
    bcdDevice: bd.getUint16(12, Endian.little),
    iManufacturer: raw[14],
    iProduct: raw[15],
    iSerialNumber: raw[16],
  );
}

/// libusb_get_string_descriptor(): GET_DESCRIPTOR(STRING, index) with [langid].
int getStringDescriptor(
  UsbDeviceHandle h,
  int descIndex,
  int langid,
  Uint8List data,
  int length,
) {
  return h.controlTransfer(
    UsbReqType.endpointIn,
    UsbStd.requestGetDescriptor,
    ((UsbStd.dtString << 8) | (descIndex & 0xff)) & 0xffff,
    langid & 0xffff,
    data,
    length,
  );
}

/// Port of libusb_get_string_descriptor_ascii(). Returns the ASCII string
/// (non-ASCII UTF-16 units become '?'), or throws [UsbException].
/// [length] is the size of the C destination buffer incl. the NUL terminator.
String getStringDescriptorAsciiOrThrow(
  UsbDeviceHandle h,
  int descIndex, {
  int length = 256,
}) {
  /* Asking for the zero'th index is special - it returns a string
   * descriptor that contains all the language IDs supported by the
   * device. Typically there aren't many - often only one. Language
   * IDs are 16 bit numbers, and they start at the third byte in the
   * descriptor. There's also no point in trying to read descriptor 0
   * with this function. See USB 2.0 specification section 9.6.7 for
   * more information.
   */
  if (descIndex == 0) {
    throw UsbException(UsbError.invalidParam, 'string index 0');
  }

  // union usbi_string_desc_buf { ...; uint8_t buf[255]; }
  final buf = Uint8List(255);
  var r = getStringDescriptor(h, 0, 0, buf, 4);
  if (r != 4 || buf[0] < 4 || buf[1] != UsbStd.dtString) {
    throw UsbException(UsbError.io, 'invalid language ID string descriptor');
  }
  final langid = buf[2] | (buf[3] << 8);

  buf.fillRange(0, buf.length, 0);
  r = getStringDescriptor(h, descIndex, langid, buf, buf.length);
  final bLength = buf[0];
  if (r < UsbStd.descHeaderLength || bLength > r || buf[1] != UsbStd.dtString) {
    throw UsbException(UsbError.io, 'invalid string descriptor $descIndex');
  }

  /* Stop one byte before the end to leave room for null termination. */
  final destMax = length - 1;

  /* The descriptor has this number of wide characters */
  final srcMax = (bLength - 1 - 1) ~/ 2;

  /* Neither read nor write more than the smallest buffer */
  final idxMax = destMax < srcMax ? destMax : srcMax;

  final out = StringBuffer();
  for (var idx = 0; idx < idxMax; ++idx) {
    final wdata = buf[2 + 2 * idx] | (buf[3 + 2 * idx] << 8);
    if (wdata < 0x80) {
      out.writeCharCode(wdata);
    } else {
      out.write('?'); /* non-ASCII */
    }
  }
  return out.toString();
}

/// Contract-level wrapper: null if index == 0 or on error.
String? getStringDescriptorAsciiOrNull(UsbDeviceHandle h, int descIndex) {
  if (descIndex == 0) return null;
  try {
    return getStringDescriptorAsciiOrThrow(h, descIndex);
  } on UsbException {
    return null;
  }
}

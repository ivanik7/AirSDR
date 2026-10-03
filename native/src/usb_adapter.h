// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_USB_ADAPTER_H
#define SDRCORE_USB_ADAPTER_H

#include <cstddef>
#include <cstdint>

// Internal (non-public) interface between sdrcore.cpp's single producer
// thread and the two source-built USB drivers (third_party/rtl-sdr,
// third_party/hackrf). Not part of the ABI 2 contract in
// native/include/sdrcore.h and not exported from libsdrcore.so.
//
// Contract:
//   open(fd)      duplicates/wraps the caller-owned fd via libusb_wrap_sys_device
//                  (through the vendor driver's *_open_sys_dev/*_open_by_fd).
//                  The adapter does not take ownership of fd itself; wrap_sys_device
//                  keeps its own libusb-internal duplicate, so the caller's
//                  original fd must remain open until close().
//   configure(..) sets center frequency (RF Hz), sample rate (complex S/s) and
//                  a single combined gain in tenths of a dB, matching ABI 2's
//                  sdr_v2_configure() units exactly.
//   start(push,ctx) is a BLOCKING call made from the producer thread; it
//                  returns only after stop() is called from another thread
//                  (or on an unrecoverable I/O error). `push` is invoked with
//                  interleaved unsigned-8-bit IQ (CU8) buffers, same framing
//                  as the file/synthetic sources.
//   stop()         unblocks a pending start() and stops the hardware stream;
//                  safe to call once after start() has been entered.
//   close()        releases the device handle; safe to call after stop().
// All methods return SDR_OK (0) or a negative SdrResult-compatible code.
class UsbRxAdapter {
 public:
  using PushFn = void (*)(void* ctx, const uint8_t* data, size_t len);

  virtual ~UsbRxAdapter() = default;
  virtual int open(int fd) = 0;
  virtual int configure(uint64_t frequency_hz, uint32_t sample_rate,
                         int32_t gain_tenths_db) = 0;
  virtual int start(PushFn push, void* ctx) = 0;
  virtual void stop() = 0;
  virtual void close() = 0;
};

#endif  // SDRCORE_USB_ADAPTER_H

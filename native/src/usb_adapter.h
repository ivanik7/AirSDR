// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_USB_ADAPTER_H
#define SDRCORE_USB_ADAPTER_H

#include "sdrcore.h"

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
//                  stores the supplied descriptor without duplicating it;
//                  each adapter owns its explicit dup while the caller keeps
//                  the original UsbDeviceConnection alive until close().
//   configure(..) sets center frequency (RF Hz), sample rate (complex S/s) and
//                  a single combined gain in tenths of a dB, matching ABI 2's
//                  sdr_v2_configure() units exactly.
//   start(push,ctx) is a BLOCKING call made from the producer thread; it
//                  returns only after stop() is called from another thread
//                  (or on an unrecoverable I/O error). `push` is invoked with
//                  interleaved 8-bit IQ buffers (CU8 for RTL, CS8 for HackRF);
//                  the core normalizes HackRF to CU8 in its bounded ring.
//   stop()         unblocks a pending start() and stops the hardware stream;
//                  safe to call once after start() has been entered.
//   close()        releases the device handle; safe to call after stop().
//   get_tuner_gains(..) returns the device's supported tuner gain values in
//                  tenths of a dB, ascending, through the already-open
//                  device handle (no second USB claim). capacity==0 with
//                  gains==nullptr is a valid count-only probe. Insufficient
//                  capacity returns SDR_V3_BUFFER_SMALL and leaves `gains`
//                  unmodified; `count` always receives the required count.
//                  The default implementation reports SDR_UNSUPPORTED with
//                  count=0 for adapters without a discoverable gain table.
//   set_frequency(..) / set_gain(..) retune the LO or gain of an open device
//                  WHILE start() may be streaming on the producer thread
//                  (live tuning, like SDR++'s rtl_sdr source). Only used when
//                  supports_live_tuning() is true. Called from the core's
//                  tuner worker thread, which holds neither the core ring mutex nor any
//                  lock the push callback needs (the libusb event thread may
//                  be inside push() while a synchronous control transfer
//                  waits for it), never concurrently with configure(),
//                  close() or each other. Adapters without live tuning keep
//                  the full stop -> configure -> restart path.
//   retune_settle_bytes() is the amount of IQ already queued in the driver's
//                  in-flight transfers at the moment of a live retune; the
//                  core discards that much input so no pre-retune samples
//                  are demodulated or displayed under the new tune.
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
  virtual int get_tuner_gains(int32_t* gains, uint32_t capacity,
                               uint32_t* count) {
    if (count) *count = 0;
    return SDR_UNSUPPORTED;
  }
  virtual bool supports_live_tuning() const { return false; }
  virtual int set_frequency(uint64_t /*frequency_hz*/) { return SDR_UNSUPPORTED; }
  virtual int set_gain(int32_t /*gain_tenths_db*/) { return SDR_UNSUPPORTED; }
  virtual size_t retune_settle_bytes() const { return 0; }
};

#endif  // SDRCORE_USB_ADAPTER_H

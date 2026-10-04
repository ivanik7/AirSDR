// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_USB_RTLSDR_ADAPTER_H
#define SDRCORE_USB_RTLSDR_ADAPTER_H

#include "usb_adapter.h"
#include <atomic>

// RTL-SDR (R820T/R828D incl. Blog V4, E4000, FC0012/13) receive adapter over
// the vendored librtlsdr (third_party/rtl-sdr), opened from a caller-owned fd
// via rtlsdr_open_sys_dev() -> libusb_wrap_sys_device(). RX only.
//
// Ownership: libusb_wrap_sys_device() stores the fd value as-is and neither
// dup()s it nor closes it in libusb_close(). open() therefore dup()s the
// caller's fd itself and hands the dup to librtlsdr; close() closes that dup.
// The caller's original fd is never touched and must stay open for the
// duration (same contract as sdr_v2_open_file's native dup).
class RtlSdrAdapter final : public UsbRxAdapter {
 public:
  ~RtlSdrAdapter() override;
  int open(int fd) override;
  int configure(uint64_t frequency_hz, uint32_t sample_rate,
                 int32_t gain_tenths_db) override;
  int start(PushFn push, void* ctx) override;
  void stop() override;
  void close() override;
  // Returns the tuner's gain table (tenths of a dB, ascending) through the
  // already-open rtlsdr_dev_t; see usb_adapter.h for the capacity-probe and
  // BUFFER_SMALL contract. SDR_INVALID_STATE if not open.
  int get_tuner_gains(int32_t* gains, uint32_t capacity,
                       uint32_t* count) override;

 private:
  struct rtlsdr_dev* dev_ = nullptr;
  int owned_fd_ = -1;
  std::atomic<bool> stop_requested_{false};
  std::atomic<bool> stream_finished_{true};
};

#endif  // SDRCORE_USB_RTLSDR_ADAPTER_H

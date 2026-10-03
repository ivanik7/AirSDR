// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_USB_HACKRF_ADAPTER_H
#define SDRCORE_USB_HACKRF_ADAPTER_H

#include "usb_adapter.h"
#include <mutex>

// HackRF (One/Jawbreaker/rad1o) receive adapter over the vendored libhackrf
// (third_party/hackrf), opened from a caller-owned fd via
// hackrf_open_by_fd() -> libusb_wrap_sys_device(). RX only; TX is not wired.
//
// Ownership: libusb_wrap_sys_device() stores the fd as-is and does not dup()
// or close() it. open() dup()s the caller's fd and passes the dup to
// hackrf_open_by_fd(); close() closes that dup. The caller's original fd is
// never touched (same contract as the RTL-SDR adapter and sdr_v2_open_file).
class HackRfAdapter final : public UsbRxAdapter {
 public:
  ~HackRfAdapter() override;
  int open(int fd) override;
  int configure(uint64_t frequency_hz, uint32_t sample_rate,
                 int32_t gain_tenths_db) override;
  int start(PushFn push, void* ctx) override;
  void stop() override;
  void close() override;

 private:
  struct hackrf_device* dev_ = nullptr;
  int owned_fd_ = -1;
  std::mutex control_;
  bool stop_requested_ = false;
  bool streaming_ = false;
};

#endif  // SDRCORE_USB_HACKRF_ADAPTER_H

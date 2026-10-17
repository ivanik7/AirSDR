// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_USB_RTLSDR_ADAPTER_H
#define SDRCORE_USB_RTLSDR_ADAPTER_H

#include "usb_adapter.h"
#include <atomic>

// RTL-SDR (R820T/R828D incl. Blog V4, E4000, FC0012/13) receive adapter over
// the vendored librtlsdr (third_party/rtl-sdr), opened from a caller-owned fd
// via rtlsdr_open_sys_dev() -> libusb_wrap_sys_device() (Android, Linux), or
// on desktops by bus/address via rtlsdr_open_bus_address() -> libusb_open()
// (macOS, Windows; see sdr_host_open_usb_direct). RX only.
//
// Ownership: libusb_wrap_sys_device() stores the fd value as-is and neither
// dup()s it nor closes it in libusb_close(). open() therefore dup()s the
// caller's fd itself and hands the dup to librtlsdr; close() closes that dup.
// The caller's original fd is never touched and must stay open for the
// duration (same contract as sdr_v2_open_file's native dup). The direct path
// owns no descriptor; librtlsdr's own libusb context owns the device handle.
class RtlSdrAdapter final : public UsbRxAdapter {
 public:
  ~RtlSdrAdapter() override;
  int open(int fd) override;
  int open_bus_address(uint8_t bus, uint8_t address) override;
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
  // Live retune while rtlsdr_read_async streams (rtl_tcp / SDR++ do the same):
  // only the tuner PLL or gain registers are rewritten over control
  // transfers; sample rate and the async transfers stay untouched.
  bool supports_live_tuning() const override { return true; }
  int set_frequency(uint64_t frequency_hz) override;
  int set_gain(int32_t gain_tenths_db) override;
  // All submitted bulk transfers (kTransfers x kTransferBytes) may already
  // hold pre-retune IQ when the tuner is reprogrammed.
  size_t retune_settle_bytes() const override {
    return static_cast<size_t>(kTransfers) * kTransferBytes;
  }

  static constexpr uint32_t kTransfers = 16;
  static constexpr uint32_t kTransferBytes = 8192;

 private:
  struct rtlsdr_dev* dev_ = nullptr;
  int owned_fd_ = -1;
  std::atomic<bool> stop_requested_{false};
  std::atomic<bool> stream_finished_{true};
};

#endif  // SDRCORE_USB_RTLSDR_ADAPTER_H

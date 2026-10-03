// SPDX-License-Identifier: GPL-3.0-or-later
#include "usb_rtlsdr_adapter.h"

#include "rtl-sdr.h"

#include "sdrcore.h"

#include <unistd.h>

RtlSdrAdapter::~RtlSdrAdapter() { close(); }

int RtlSdrAdapter::open(int fd) {
  if (dev_) return SDR_INVALID_STATE;
  // libusb_wrap_sys_device() stores the fd it is given verbatim and does not
  // dup() or close() it; dup() here so librtlsdr/libusb own an independent
  // descriptor and the caller's original fd is left untouched.
  const int dup_fd = dup(fd);
  if (dup_fd < 0) return SDR_IO_ERROR;
  rtlsdr_dev_t* dev = nullptr;
  const int rc = rtlsdr_open_sys_dev(&dev, static_cast<intptr_t>(dup_fd));
  if (rc != 0 || !dev) {
    ::close(dup_fd);
    return SDR_DEVICE_GONE;
  }
  dev_ = dev;
  owned_fd_ = dup_fd;
  return SDR_OK;
}

int RtlSdrAdapter::configure(uint64_t frequency_hz, uint32_t sample_rate,
                              int32_t gain_tenths_db) {
  if (!dev_) return SDR_INVALID_STATE;
  if (frequency_hz > 0xFFFFFFFFull) return SDR_INVALID_ARGUMENT;
  if (rtlsdr_set_sample_rate(dev_, sample_rate) != 0) return SDR_IO_ERROR;
  if (rtlsdr_set_center_freq(dev_, static_cast<uint32_t>(frequency_hz)) != 0)
    return SDR_IO_ERROR;
  // Manual gain mode mirrors SDR++'s rtl_sdr source: AGC is not exposed
  // through ABI 2 yet, so a fixed caller-chosen gain is used throughout.
  if (rtlsdr_set_tuner_gain_mode(dev_, 1) != 0) return SDR_IO_ERROR;
  if (rtlsdr_set_tuner_gain(dev_, gain_tenths_db) != 0) return SDR_IO_ERROR;
  return SDR_OK;
}

namespace {
struct RtlAsyncCtx {
  UsbRxAdapter::PushFn push;
  void* ctx;
};

void rtlsdr_async_trampoline(unsigned char* buf, uint32_t len, void* raw) {
  auto* c = static_cast<RtlAsyncCtx*>(raw);
  if (c && c->push && buf && len) c->push(c->ctx, buf, len);
}
}  // namespace

int RtlSdrAdapter::start(PushFn push, void* ctx) {
  if (!dev_) return SDR_INVALID_STATE;
  if (rtlsdr_reset_buffer(dev_) != 0) return SDR_IO_ERROR;
  RtlAsyncCtx async_ctx{push, ctx};
  // Blocks until rtlsdr_cancel_async() is called from stop(); default buffer
  // count/length (0, 0) matches librtlsdr's own CLI tools (rtl_sdr.c).
  const int rc = rtlsdr_read_async(dev_, rtlsdr_async_trampoline, &async_ctx, 0, 0);
  return rc == 0 ? SDR_OK : SDR_IO_ERROR;
}

void RtlSdrAdapter::stop() {
  if (dev_) rtlsdr_cancel_async(dev_);
}

void RtlSdrAdapter::close() {
  if (dev_) {
    rtlsdr_close(dev_);
    dev_ = nullptr;
  }
  if (owned_fd_ >= 0) {
    ::close(owned_fd_);
    owned_fd_ = -1;
  }
}

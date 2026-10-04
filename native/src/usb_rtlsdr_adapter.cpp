// SPDX-License-Identifier: GPL-3.0-or-later
#include "usb_rtlsdr_adapter.h"

#include "rtl-sdr.h"

#include "sdrcore.h"
#include "sdrcore_v3.h"

#include <algorithm>
#include <chrono>
#include <thread>
#include <unistd.h>
#include <vector>

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

int RtlSdrAdapter::get_tuner_gains(int32_t* gains, uint32_t capacity,
                                    uint32_t* count) {
  if (!count) return SDR_INVALID_ARGUMENT;
  if (!dev_) { *count = 0; return SDR_INVALID_STATE; }
  if (capacity && !gains) { *count = 0; return SDR_INVALID_ARGUMENT; }
  // librtlsdr's own count-only probe: rtlsdr_get_tuner_gains(dev, NULL)
  // returns the number of entries without touching any buffer.
  const int total = rtlsdr_get_tuner_gains(dev_, nullptr);
  if (total < 0) { *count = 0; return SDR_IO_ERROR; }
  *count = static_cast<uint32_t>(total);
  // capacity==0 is always a valid count-only probe (regardless of how many
  // gains actually exist), distinct from a nonzero-but-insufficient
  // capacity, which is SDR_V3_BUFFER_SMALL.
  if (capacity == 0) return SDR_OK;
  if (capacity < *count) return SDR_V3_BUFFER_SMALL;
  if (*count == 0) return SDR_OK;
  // Query into a scratch buffer first so a mid-query failure never leaves
  // the caller's `gains` partially written (matches the "no gain array
  // modification" contract on any non-SDR_OK return).
  std::vector<int> raw(*count);
  const int got = rtlsdr_get_tuner_gains(dev_, raw.data());
  if (got != static_cast<int>(*count)) return SDR_IO_ERROR;
  // Exact migration of the legacy Dart gain path: old `rtl_sdr_source.dart`
  // called `dev.getTunerGains()..sort()` before indexing by gainId. librtlsdr's
  // static tables are already ascending for every known tuner, but sort here
  // explicitly so the ABI contract ("sorted ascending") holds regardless of
  // the vendored table's order.
  std::sort(raw.begin(), raw.end());
  for (uint32_t i = 0; i < *count; ++i) gains[i] = static_cast<int32_t>(raw[i]);
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
  stream_finished_ = false;
  if (stop_requested_) {
    stream_finished_ = true;
    stop_requested_ = false;
    return SDR_OK;
  }
  if (rtlsdr_reset_buffer(dev_) != 0) {
    stream_finished_ = true;
    stop_requested_ = false;
    return SDR_IO_ERROR;
  }
  if (stop_requested_) {
    stream_finished_ = true;
    stop_requested_ = false;
    return SDR_OK;
  }
  RtlAsyncCtx async_ctx{push, ctx};
  // Keep callback buffers aligned with the ring slot size. The upstream
  // default (262144 bytes) would overrun a single slot and starve the
  // consumer; 16 submitted buffers keep sufficient USB transfers in flight.
  const int rc = rtlsdr_read_async(dev_, rtlsdr_async_trampoline, &async_ctx, 16, 8192);
  stream_finished_ = true;
  stop_requested_ = false;
  return rc == 0 ? SDR_OK : (rc == -1 ? SDR_DEVICE_GONE : SDR_IO_ERROR);
}

void RtlSdrAdapter::stop() {
  stop_requested_ = true;
  // A stop can race the producer before read_async sets RUNNING. Retry the
  // cancellation until the producer finishes or acknowledges it; join() then
  // waits for all in-flight callbacks before freeing their context.
  while (dev_ && !stream_finished_) {
    if (rtlsdr_cancel_async(dev_) == 0) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
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

// SPDX-License-Identifier: GPL-3.0-or-later
#include "usb_hackrf_adapter.h"

#include "hackrf.h"

#include "sdrcore.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <thread>
#include <unistd.h>

namespace {
// HackRF has two cascaded RX gain stages (LNA 0-40dB/8dB steps, VGA/BB
// 0-62dB/2dB steps) plus a bypassable RF amp, unlike RTL-SDR's single tuner
// gain. ABI 2's sdr_v2_configure() exposes one gain_tenths_db knob; until a
// richer control surface exists (tracked for N2), it is split heuristically:
// the RF amp switches on above +20 dB equivalent and the remainder is spread
// across VGA then LNA. This is a documented limitation, not full parity with
// SDR++'s three-way HackRF gain UI.
struct HackRfGains {
  bool amp_enable;
  uint32_t lna_db;
  uint32_t vga_db;
};

uint32_t round_step(int value, int step, int max_value) {
  if (value < 0) value = 0;
  if (value > max_value) value = max_value;
  return static_cast<uint32_t>((value / step) * step);
}

HackRfGains split_gain(int32_t gain_tenths_db) {
  int gain_db = gain_tenths_db / 10;
  HackRfGains g{false, 0, 0};
  g.amp_enable = gain_db > 20;
  if (g.amp_enable) gain_db -= 14;  // approximate RF amp contribution
  const int vga_share = std::min(gain_db, 62);
  g.vga_db = round_step(vga_share, 2, 62);
  gain_db -= vga_share;
  g.lna_db = round_step(gain_db, 8, 40);
  return g;
}

std::atomic<int> g_hackrf_init_refcount{0};
}  // namespace

HackRfAdapter::~HackRfAdapter() { close(); }

int HackRfAdapter::open(int fd) {
  if (dev_) return SDR_INVALID_STATE;
  if (g_hackrf_init_refcount.fetch_add(1) == 0) {
    if (hackrf_init() != 0) {
      g_hackrf_init_refcount.fetch_sub(1);
      return SDR_INTERNAL_ERROR;
    }
  }
  // libusb_wrap_sys_device() stores the fd as-is and does not dup() or
  // close() it; dup() here so libhackrf/libusb own an independent descriptor
  // and the caller's original fd is left untouched.
  const int dup_fd = dup(fd);
  if (dup_fd < 0) {
    if (g_hackrf_init_refcount.fetch_sub(1) == 1) hackrf_exit();
    return SDR_IO_ERROR;
  }
  hackrf_device* dev = nullptr;
  const int rc = hackrf_open_by_fd(dup_fd, &dev);
  if (rc != 0 || !dev) {
    ::close(dup_fd);
    if (g_hackrf_init_refcount.fetch_sub(1) == 1) hackrf_exit();
    return SDR_DEVICE_GONE;
  }
  dev_ = dev;
  owned_fd_ = dup_fd;
  return SDR_OK;
}

int HackRfAdapter::configure(uint64_t frequency_hz, uint32_t sample_rate,
                              int32_t gain_tenths_db) {
  if (!dev_) return SDR_INVALID_STATE;
  if (hackrf_set_sample_rate(dev_, static_cast<double>(sample_rate)) != 0)
    return SDR_IO_ERROR;
  if (hackrf_set_freq(dev_, frequency_hz) != 0) return SDR_IO_ERROR;
  const HackRfGains g = split_gain(gain_tenths_db);
  if (hackrf_set_amp_enable(dev_, g.amp_enable ? 1 : 0) != 0) return SDR_IO_ERROR;
  if (hackrf_set_lna_gain(dev_, g.lna_db) != 0) return SDR_IO_ERROR;
  if (hackrf_set_vga_gain(dev_, g.vga_db) != 0) return SDR_IO_ERROR;
  return SDR_OK;
}

namespace {
struct HackRfStreamCtx {
  UsbRxAdapter::PushFn push;
  void* user_ctx;
};

int hackrf_rx_trampoline(hackrf_transfer* transfer) {
  auto* c = static_cast<HackRfStreamCtx*>(transfer->rx_ctx);
  if (c && c->push && transfer->buffer && transfer->valid_length > 0) {
    c->push(c->user_ctx, transfer->buffer,
            static_cast<size_t>(transfer->valid_length));
  }
  return 0;  // non-zero would stop the stream from the callback's side
}
}  // namespace

int HackRfAdapter::start(PushFn push, void* ctx) {
  if (!dev_) return SDR_INVALID_STATE;
  // hackrf_start_rx() spawns its own libusb transfer thread and returns
  // immediately, unlike rtlsdr_read_async(); poll hackrf_is_streaming() so
  // this call keeps the same "blocks until stop()" contract as the rtlsdr
  // adapter and the file/synthetic producer loop in sdrcore.cpp.
  HackRfStreamCtx stream_ctx{push, ctx};
  if (hackrf_start_rx(dev_, hackrf_rx_trampoline, &stream_ctx) != 0)
    return SDR_IO_ERROR;
  while (hackrf_is_streaming(dev_) == HACKRF_TRUE) {
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  return SDR_OK;
}

void HackRfAdapter::stop() {
  if (dev_) hackrf_stop_rx(dev_);
}

void HackRfAdapter::close() {
  if (dev_) {
    hackrf_close(dev_);
    dev_ = nullptr;
    if (g_hackrf_init_refcount.fetch_sub(1) == 1) hackrf_exit();
  }
  if (owned_fd_ >= 0) {
    ::close(owned_fd_);
    owned_fd_ = -1;
  }
}

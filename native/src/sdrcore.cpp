// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore.h"

#include "usb_adapter.h"
#include "usb_hackrf_adapter.h"
#include "usb_rtlsdr_adapter.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <poll.h>
#include <thread>
#include <unistd.h>

namespace {
constexpr size_t kSlots = 8;
constexpr size_t kBytes = 8192;
constexpr uint64_t kFnvOffset = 14695981039346656037ULL;
constexpr uint64_t kFnvPrime = 1099511628211ULL;
bool valid_rate(uint32_t rate) { return rate >= 1000 && rate <= 20000000; }
}  // namespace

struct SdrHandle {
  std::mutex mutex;
  std::condition_variable ready;
  std::atomic<bool> stopping{false};
  std::thread producer;
  std::thread consumer;
  std::array<std::array<uint8_t, kBytes>, kSlots> ring{};
  std::array<size_t, kSlots> lengths{};
  size_t head = 0, tail = 0, queued = 0;
  bool producer_done = false;
  int fd = -1;  // exclusively owned duplicate; Java/FFI retains original
  std::unique_ptr<UsbRxAdapter> usb_adapter;  // set only for SDR_RTLSDR/HACKRF
  SdrStats stats{};

  SdrHandle() {
    stats.size = sizeof(SdrStats);
    stats.revision = 2;
    stats.state = SDR_IDLE;
    stats.checksum = kFnvOffset;
  }

  void push(const uint8_t* bytes, size_t length) {
    // USB callbacks may deliver much more than one ring slot (RTL's default
    // async transfer is 262144 bytes). Split on complete IQ pairs; never
    // write beyond a slot. HackRF emits signed CS8, while this diagnostic
    // consumer and the other sources use unsigned CU8.
    length &= ~size_t{1};
    for (size_t offset = 0; offset < length;) {
      const size_t chunk = std::min(kBytes, length - offset);
      std::lock_guard<std::mutex> lock(mutex);
      stats.input_samples += chunk / 2;
      if (queued == kSlots) {
        stats.dropped_samples += chunk / 2;
      } else {
        if (stats.source == SDR_HACKRF) {
          for (size_t i = 0; i < chunk; ++i)
            ring[tail][i] = bytes[offset + i] ^ 0x80;
        } else {
          std::memcpy(ring[tail].data(), bytes + offset, chunk);
        }
        lengths[tail] = chunk;
        tail = (tail + 1) % kSlots;
        ++queued;
        ready.notify_one();
      }
      offset += chunk;
    }
  }

  void read_loop() {
    std::array<uint8_t, kBytes + 1> bytes{};
    size_t carry = 0;
    uint8_t phase = 0;
    if (usb_adapter) {
      // Blocks until the adapter's stop() unblocks it (join() calls that
      // from a different thread) or the hardware reports a fatal I/O error.
      const int rc = usb_adapter->start(
          [](void* ctx, const uint8_t* data, size_t len) {
            static_cast<SdrHandle*>(ctx)->push(data, len);
          },
          this);
      if (rc != SDR_OK && !stopping.load()) {
        std::lock_guard<std::mutex> lock(mutex);
        stats.last_error = rc;
        stats.state = SDR_ERROR;
      }
      { std::lock_guard<std::mutex> lock(mutex); producer_done = true; }
      ready.notify_all();
      return;
    }
    while (!stopping.load()) {
      size_t length = 0;
      if (fd >= 0) {
        pollfd p{fd, POLLIN, 0};
        int rc = poll(&p, 1, 50);
        if (rc < 0 && errno == EINTR) continue;
        if (rc == 0) continue;
        if (rc < 0 || (p.revents & (POLLERR | POLLNVAL))) {
          std::lock_guard<std::mutex> lock(mutex);
          stats.last_error = SDR_IO_ERROR;
          stats.state = SDR_ERROR;
          break;
        }
        ssize_t n = read(fd, bytes.data() + carry, kBytes - carry);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
          if (n < 0) {
            std::lock_guard<std::mutex> lock(mutex);
            stats.last_error = errno == ENODEV ? SDR_DEVICE_GONE : SDR_IO_ERROR;
            stats.state = SDR_ERROR;
          }
          break;
        }
        length = static_cast<size_t>(n) + carry;
        carry = length & 1;
        length -= carry;
        if (carry) {
          const uint8_t last = bytes[length];
          push(bytes.data(), length);
          bytes[0] = last;
          continue;
        }
      } else {
        for (size_t i = 0; i < kBytes; ++i) bytes[i] = phase++;
        length = kBytes;
      }
      if (length) push(bytes.data(), length);
      if (fd < 0) {
        uint32_t rate;
        { std::lock_guard<std::mutex> lock(mutex); rate = stats.sample_rate; }
        std::this_thread::sleep_for(std::chrono::microseconds(4096000000ULL / rate));
      }
    }
    { std::lock_guard<std::mutex> lock(mutex); producer_done = true; }
    ready.notify_all();
  }

  void consume_loop() {
    for (;;) {
      std::unique_lock<std::mutex> lock(mutex);
      ready.wait(lock, [this] { return queued || producer_done; });
      if (!queued && producer_done) return;
      const size_t length = lengths[head];
      for (size_t i = 0; i < length; ++i)
        stats.checksum = (stats.checksum ^ ring[head][i]) * kFnvPrime;
      stats.processed_samples += length / 2;
      head = (head + 1) % kSlots;
      --queued;
    }
  }

  void join() {
    stopping = true;
    if (usb_adapter) usb_adapter->stop();  // unblocks a blocking start() call
    if (producer.joinable()) producer.join();
    { std::lock_guard<std::mutex> lock(mutex); producer_done = true; }
    ready.notify_all();
    if (consumer.joinable()) consumer.join();
  }
};

extern "C" uint32_t sdr_version(void) { return 2u; }

extern "C" SdrHandle* sdr_create(void) {
  return new (std::nothrow) SdrHandle;
}

extern "C" void sdr_destroy(SdrHandle* handle) {
  if (!handle) return;
  handle->join();
  if (handle->usb_adapter) handle->usb_adapter->close();
  if (handle->fd >= 0) close(handle->fd);
  delete handle;
}

extern "C" int32_t sdr_v2_open_file(SdrHandle* h, int32_t fd, uint32_t rate) {
  if (!h || fd < 0 || !valid_rate(rate)) return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  if (h->stats.state != SDR_IDLE) return SDR_INVALID_STATE;
  int copy = dup(fd);
  if (copy < 0) return SDR_IO_ERROR;
  h->fd = copy;
  h->stats = SdrStats{};
  h->stats.size = sizeof(SdrStats);
  h->stats.revision = 2;
  h->stats.source = SDR_FILE;
  h->stats.state = SDR_OPEN;
  h->stats.sample_rate = rate;
  h->stats.checksum = kFnvOffset;
  return SDR_OK;
}

extern "C" int32_t sdr_v2_open_synthetic(SdrHandle* h, uint32_t rate) {
  if (!h || !valid_rate(rate)) return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  if (h->stats.state != SDR_IDLE) return SDR_INVALID_STATE;
  h->stats = SdrStats{};
  h->stats.size = sizeof(SdrStats);
  h->stats.revision = 2;
  h->stats.checksum = kFnvOffset;
  h->stats.source = SDR_SYNTHETIC;
  h->stats.state = SDR_OPEN;
  h->stats.sample_rate = rate;
  return SDR_OK;
}

extern "C" int32_t sdr_v2_open_usb(SdrHandle* h, int32_t fd, uint32_t source) {
  if (!h || fd < 0 || (source != SDR_RTLSDR && source != SDR_HACKRF))
    return SDR_INVALID_ARGUMENT;
  {
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->stats.state != SDR_IDLE) return SDR_INVALID_STATE;
  }
  std::unique_ptr<UsbRxAdapter> adapter;
  if (source == SDR_RTLSDR) {
    adapter = std::make_unique<RtlSdrAdapter>();
  } else {
    adapter = std::make_unique<HackRfAdapter>();
  }
  // open() dup()s fd itself (see usb_*_adapter.h); the caller's original fd,
  // owned by the Kotlin UsbSdrPlugin/UsbDeviceConnection, is never touched
  // and must stay open for the session (same contract as sdr_v2_open_file).
  const int rc = adapter->open(fd);
  if (rc != SDR_OK) return rc;
  std::lock_guard<std::mutex> lock(h->mutex);
  if (h->stats.state != SDR_IDLE) {
    adapter->close();
    return SDR_INVALID_STATE;
  }
  h->usb_adapter = std::move(adapter);
  h->stats = SdrStats{};
  h->stats.size = sizeof(SdrStats);
  h->stats.revision = 2;
  h->stats.source = source;
  h->stats.state = SDR_OPEN;
  h->stats.checksum = kFnvOffset;
  return SDR_OK;
}

extern "C" int32_t sdr_v2_configure(SdrHandle* h, uint64_t frequency,
                                      uint32_t rate, int32_t gain) {
  if (!h || !valid_rate(rate) || frequency > 7250000000ULL ||
      gain < -1000 || gain > 1000) return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  if (h->stats.state != SDR_OPEN) return SDR_INVALID_STATE;
  if (h->usb_adapter) {
    // Real hardware reconfiguration; unlike the file/synthetic sources this
    // actually retunes the RF front end (see usb_rtlsdr_adapter.cpp /
    // usb_hackrf_adapter.cpp for the exact register-level calls).
    const int rc = h->usb_adapter->configure(frequency, rate, gain);
    if (rc != SDR_OK) return rc;
  }
  h->stats.frequency_hz = frequency;
  h->stats.sample_rate = rate;
  h->stats.gain_tenths_db = gain;
  return SDR_OK;
}

extern "C" int32_t sdr_v2_start(SdrHandle* h) {
  if (!h) return SDR_INVALID_ARGUMENT;
  {
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->stats.state != SDR_OPEN) return SDR_INVALID_STATE;
    if (h->usb_adapter && h->stats.sample_rate == 0) return SDR_INVALID_STATE;
    h->head = h->tail = h->queued = 0;
    h->producer_done = false;
    h->stopping = false;
    h->stats.state = SDR_RUNNING;
  }
  try {
    h->consumer = std::thread([h] { h->consume_loop(); });
    h->producer = std::thread([h] { h->read_loop(); });
  } catch (...) {
    h->join();
    std::lock_guard<std::mutex> lock(h->mutex);
    h->stats.state = SDR_ERROR;
    h->stats.last_error = SDR_INTERNAL_ERROR;
    return SDR_INTERNAL_ERROR;
  }
  return SDR_OK;
}

extern "C" int32_t sdr_v2_stop(SdrHandle* h) {
  if (!h) return SDR_INVALID_ARGUMENT;
  {
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->stats.state != SDR_RUNNING && h->stats.state != SDR_ERROR)
      return SDR_INVALID_STATE;
  }
  h->join();
  std::lock_guard<std::mutex> lock(h->mutex);
  h->stats.state = SDR_OPEN;
  return SDR_OK;
}

extern "C" int32_t sdr_v2_close(SdrHandle* h) {
  if (!h) return SDR_INVALID_ARGUMENT;
  {
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->stats.state == SDR_IDLE) return SDR_INVALID_STATE;
  }
  h->join();
  std::lock_guard<std::mutex> lock(h->mutex);
  if (h->usb_adapter) { h->usb_adapter->close(); h->usb_adapter.reset(); }
  if (h->fd >= 0) { close(h->fd); h->fd = -1; }
  h->stats.state = SDR_IDLE;
  h->stats.source = SDR_NONE;
  return SDR_OK;
}

extern "C" int32_t sdr_v2_stats(SdrHandle* h, SdrStats* out) {
  if (!h || !out || out->size != sizeof(SdrStats) || out->revision != 2)
    return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  *out = h->stats;
  return SDR_OK;
}

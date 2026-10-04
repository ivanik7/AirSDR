// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore_v3.h"

#include "audio/audio_sink.h"
#include "dsp/receiver.h"
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
#include <cmath>
#include <memory>
#include <mutex>
#include <new>
#include <poll.h>
#include <string>
#include <thread>
#include <unistd.h>

namespace {
// 64 x 8 KiB = 512 KiB, ~109 ms of CU8 at 2.4 MS/s. Eight slots (27 ms) dropped
// IQ on ordinary scheduler stalls in the 600 s Blog V4 soak (t_848e6a1c).
constexpr size_t kSlots = 64;
constexpr size_t kBytes = 8192;
constexpr uint64_t kFnvOffset = 14695981039346656037ULL;
constexpr uint64_t kFnvPrime = 1099511628211ULL;
bool valid_rate(uint32_t rate) { return rate >= 1000 && rate <= 20000000; }
std::atomic<bool> g_native_usb_claim{false};
bool valid_controls(const SdrV3Controls& c) {
  if (c.size != sizeof(c) || c.revision != SDR_V3_REVISION || c.reserved ||
      !valid_rate(c.sample_rate) || c.center_frequency_hz > 7250000000ULL ||
      c.mode > SDR_V3_RAW || c.gain_tenths_db < -1000 || c.gain_tenths_db > 1000 ||
      c.agc > 1 || c.squelch > SDR_V3_SQUELCH_AUTO || c.muted > 1 ||
      !std::isfinite(c.squelch_level_db) || c.squelch_level_db < -100 ||
      c.squelch_level_db > 0 || !std::isfinite(c.auto_squelch_offset_db) ||
      c.auto_squelch_offset_db < -10 || c.auto_squelch_offset_db > 20 ||
      !std::isfinite(c.volume) || c.volume < 0 || c.volume > 1 ||
      c.bandwidth_hz < 50 || c.bandwidth_hz > c.sample_rate / 2) return false;
  // Minimums follow RadioController.demodParams (lib/ui/radio_controller.dart),
  // so every bandwidth the UI can send is accepted; maximums leave headroom.
  if (c.mode == SDR_V3_WFM && (c.bandwidth_hz < 50000 || c.bandwidth_hz > 300000)) return false;
  if (c.mode == SDR_V3_NFM && (c.bandwidth_hz < 1000 || c.bandwidth_hz > 50000)) return false;
  if (c.mode == SDR_V3_AM && (c.bandwidth_hz < 1000 || c.bandwidth_hz > 50000)) return false;
  if ((c.mode == SDR_V3_USB || c.mode == SDR_V3_LSB) &&
      (c.bandwidth_hz < 500 || c.bandwidth_hz > 50000)) return false;
  if (c.mode == SDR_V3_DSB && (c.bandwidth_hz < 1000 || c.bandwidth_hz > 50000)) return false;
  if (c.mode == SDR_V3_CW && c.bandwidth_hz > 5000) return false;
  if (c.squelch == SDR_V3_SQUELCH_AUTO && (c.mode == SDR_V3_WFM || c.mode == SDR_V3_RAW)) return false;
  const int64_t edge = (c.mode == SDR_V3_USB || c.mode == SDR_V3_LSB) ?
      static_cast<int64_t>(c.bandwidth_hz) : static_cast<int64_t>(c.bandwidth_hz / 2);
  const int64_t half = static_cast<int64_t>(c.sample_rate / 2);
  if (c.vfo_offset_hz < -half || c.vfo_offset_hz > half ||
      c.vfo_offset_hz < -half + edge || c.vfo_offset_hz > half - edge) return false;
  if (c.vfo_offset_hz < 0 && static_cast<uint64_t>(-c.vfo_offset_hz) > c.center_frequency_hz) return false;
  if (c.vfo_offset_hz > 0 && c.center_frequency_hz >
      7250000000ULL - static_cast<uint64_t>(c.vfo_offset_hz)) return false;
  return true;
}
bool valid_display(const SdrV3Display& d, uint32_t rate) {
  if (d.size != sizeof(d) || d.revision != SDR_V3_REVISION || !rate ||
      d.width < 1 || d.width > SDR_V3_MAX_FFT_WIDTH ||
      !d.view_bandwidth_hz || d.view_bandwidth_hz > rate) return false;
  const int64_t half = static_cast<int64_t>(rate / 2);
  return d.view_offset_hz >= -half + static_cast<int64_t>(d.view_bandwidth_hz / 2) &&
         d.view_offset_hz <= half - static_cast<int64_t>(d.view_bandwidth_hz / 2);
}
}  // namespace

struct SdrHandle {
  std::mutex mutex;
  std::mutex dsp_mutex;
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
  bool owns_usb_claim = false;
  bool v3_active = false;
  bool v3_configured = false;
  SdrV3Controls controls{};
  SdrV3Display display{};
  std::string sink_spec =
#ifdef __ANDROID__
      "aaudio";
#else
      "null";
#endif
  std::unique_ptr<sdrcore::AudioSink> audio_sink;
  std::unique_ptr<sdrcore::dsp::Receiver> receiver;
  SdrV3Snapshot snapshot{};
  SdrV3Fft fft{};
  std::vector<float> fft_bins;
  bool fft_unread = false;
  uint64_t fft_sequence = 0;
  uint64_t audio_base_frames = 0;
  uint64_t audio_base_dropped = 0;
  uint64_t audio_base_nonsilent = 0;
  SdrStats stats{};

  SdrHandle() {
    stats.size = sizeof(SdrStats);
    stats.revision = 2;
    stats.state = SDR_IDLE;
    stats.checksum = kFnvOffset;
    snapshot.size = sizeof(snapshot);
    snapshot.revision = SDR_V3_REVISION;
    snapshot.state = SDR_IDLE;
  }

  void reset_v3_open() {
    snapshot = SdrV3Snapshot{};
    snapshot.size = sizeof(snapshot);
    snapshot.revision = SDR_V3_REVISION;
    snapshot.source = stats.source;
    snapshot.state = SDR_OPEN;
    snapshot.sample_rate = stats.sample_rate;
    v3_active = false;
    v3_configured = false;
    controls = SdrV3Controls{};
    display = SdrV3Display{};
    fft_bins.clear();
    fft_unread = false;
    audio_base_frames = audio_base_dropped = audio_base_nonsilent = 0;
  }
  void async_error(int error) {
    if (!snapshot.last_error) snapshot.last_error = error;
    ++snapshot.error_sequence;
    snapshot.state = SDR_ERROR;
    stats.last_error = error;
    stats.state = SDR_ERROR;
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
    bool data_since_rewind = false;
    auto next_read = std::chrono::steady_clock::now();
    if (usb_adapter) {
      // Blocks until the adapter's stop() unblocks it (join() calls that
      // from a different thread) or the hardware reports a fatal I/O error.
      const int rc = usb_adapter->start(
          [](void* ctx, const uint8_t* data, size_t len) {
            static_cast<SdrHandle*>(ctx)->push(data, len);
          },
          this);
      if (!stopping.load()) {
        std::lock_guard<std::mutex> lock(mutex);
        // A USB producer must run until explicitly stopped. Even a driver
        // returning success without a stop is an unexpected loss of input.
        if (v3_active) async_error(rc == SDR_OK ? SDR_DEVICE_GONE : rc);
        else { stats.last_error = rc == SDR_OK ? SDR_DEVICE_GONE : rc; stats.state = SDR_ERROR; }
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
          if (v3_active) async_error(SDR_IO_ERROR);
          else { stats.last_error = SDR_IO_ERROR; stats.state = SDR_ERROR; }
          break;
        }
        ssize_t n = read(fd, bytes.data() + carry, kBytes - carry);
        if (n < 0 && errno == EINTR) continue;
        if (n == 0 && v3_active) {
          // Radio sessions replay recordings in a loop like the Dart
          // FileSource. A non-seekable stream that ends is lost input.
          // An empty recording would spin; treat it like a lost stream.
          if (data_since_rewind && lseek(fd, 0, SEEK_SET) == 0) {
            carry = 0;
            data_since_rewind = false;
            continue;
          }
          std::lock_guard<std::mutex> lock(mutex);
          async_error(SDR_IO_ERROR);
          break;
        }
        if (n <= 0) {
          if (n < 0) {
            std::lock_guard<std::mutex> lock(mutex);
            const int error = errno == ENODEV ? SDR_DEVICE_GONE : SDR_IO_ERROR;
            if (v3_active) async_error(error);
            else { stats.last_error = error; stats.state = SDR_ERROR; }
          }
          break;
        }
        length = static_cast<size_t>(n) + carry;
        data_since_rewind = true;
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
      // File IQ is replayed at its declared complex sample rate in v3; an
      // unpaced regular file fills eight ring slots before DSP can consume a
      // single block. Preserve the ABI-2 diagnostic fast-file behavior.
      if (fd < 0 || (v3_active && fd >= 0)) {
        uint32_t rate;
        { std::lock_guard<std::mutex> lock(mutex); rate = stats.sample_rate; }
        next_read += std::chrono::microseconds(length / 2 * 1000000ULL / rate);
        const auto now = std::chrono::steady_clock::now();
        if (next_read < now) next_read = now;
        while (!stopping.load() && std::chrono::steady_clock::now() < next_read)
          std::this_thread::sleep_until(std::min(next_read,
              std::chrono::steady_clock::now() + std::chrono::milliseconds(20)));
      }
    }
    { std::lock_guard<std::mutex> lock(mutex); producer_done = true; }
    ready.notify_all();
  }

  void consume_loop() {
    std::array<uint8_t, kBytes> block{};
    sdrcore::dsp::ProcessResult result;
    for (;;) {
      std::unique_lock<std::mutex> lock(mutex);
      ready.wait(lock, [this] { return queued || producer_done; });
      if (!queued && producer_done) return;
      const size_t length = lengths[head];
      const bool dsp = v3_active;
      if (dsp) std::memcpy(block.data(), ring[head].data(), length);
      else for (size_t i = 0; i < length; ++i)
        stats.checksum = (stats.checksum ^ ring[head][i]) * kFnvPrime;
      head = (head + 1) % kSlots;
      --queued;
      if (!dsp) { stats.processed_samples += length / 2; continue; }
      lock.unlock();
      sdrcore::AudioSinkStats audio_stats;
      try {
        std::lock_guard<std::mutex> dsp_lock(dsp_mutex);
        receiver->process(block.data(), length, result);
        if (!result.audio.empty())
          audio_sink->write(result.audio.data(), result.audio.size() / 2);
        audio_stats = audio_sink->stats();
      } catch (...) {
        std::lock_guard<std::mutex> failed(mutex);
        async_error(SDR_INTERNAL_ERROR);
        return;
      }
      lock.lock();
      stats.processed_samples += length / 2;
      snapshot.squelch_metric_db = result.signal_db;
      snapshot.squelch_threshold_db = result.squelch_threshold_db;
      snapshot.squelch_ready = result.squelch_ready;
      snapshot.squelch_open = result.squelch_open;
      snapshot.audio_frames = audio_base_frames + audio_stats.frames_written;
      snapshot.audio_dropped_frames = audio_base_dropped + audio_stats.frames_dropped;
      snapshot.audio_nonsilent_frames = audio_base_nonsilent + audio_stats.nonsilent_frames;
      if (audio_stats.last_error && snapshot.state != SDR_ERROR)
        async_error(audio_stats.last_error);
      if (!result.fft.empty() && snapshot.state == SDR_RUNNING) {
        if (fft_unread) ++snapshot.fft_overwrites;
        fft_bins = result.fft;
        fft = SdrV3Fft{};
        fft.size = sizeof(fft);
        fft.revision = SDR_V3_REVISION;
        fft.sequence = ++fft_sequence;
        fft.stream_generation = snapshot.stream_generation;
        fft.control_sequence = snapshot.control_sequence;
        fft.monotonic_ns = static_cast<uint64_t>(std::chrono::duration_cast<
            std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
        fft.low_hz = static_cast<int64_t>(controls.center_frequency_hz) +
            display.view_offset_hz - static_cast<int64_t>(display.view_bandwidth_hz / 2);
        fft.high_hz = fft.low_hz + display.view_bandwidth_hz;
        fft.width = static_cast<uint32_t>(fft_bins.size());
        fft_unread = true;
      }
    }
  }

  void join() {
    stopping = true;
    if (usb_adapter && producer.joinable()) usb_adapter->stop();
    if (producer.joinable()) producer.join();
    { std::lock_guard<std::mutex> lock(mutex); producer_done = true; }
    ready.notify_all();
    if (consumer.joinable()) consumer.join();
    if (audio_sink) {
      const auto final = audio_sink->stats();
      std::lock_guard<std::mutex> lock(mutex);
      snapshot.audio_frames = audio_base_frames + final.frames_written;
      snapshot.audio_dropped_frames = audio_base_dropped + final.frames_dropped;
      snapshot.audio_nonsilent_frames = audio_base_nonsilent + final.nonsilent_frames;
      audio_base_frames = snapshot.audio_frames;
      audio_base_dropped = snapshot.audio_dropped_frames;
      audio_base_nonsilent = snapshot.audio_nonsilent_frames;
      audio_sink->close();
      audio_sink.reset();
    }
  }
};

// ABI 3: all sdr_v3_* symbols are implemented; ABI 2 symbols are unchanged.
extern "C" uint32_t sdr_version(void) { return 3u; }

extern "C" SdrHandle* sdr_create(void) {
  return new (std::nothrow) SdrHandle;
}

extern "C" void sdr_destroy(SdrHandle* handle) {
  if (!handle) return;
  handle->join();
  if (handle->usb_adapter) handle->usb_adapter->close();
  if (handle->owns_usb_claim) g_native_usb_claim = false;
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
  h->reset_v3_open();
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
  h->reset_v3_open();
  return SDR_OK;
}

extern "C" int32_t sdr_v2_open_usb(SdrHandle* h, int32_t fd, uint32_t source) {
  if (!h || fd < 0 || (source != SDR_RTLSDR && source != SDR_HACKRF))
    return SDR_INVALID_ARGUMENT;
  {
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->stats.state != SDR_IDLE) return SDR_INVALID_STATE;
  }
  bool expected = false;
  if (!g_native_usb_claim.compare_exchange_strong(expected, true)) return SDR_INVALID_STATE;
  std::unique_ptr<UsbRxAdapter> adapter;
  try {
    if (source == SDR_RTLSDR) {
      adapter = std::make_unique<RtlSdrAdapter>();
    } else {
      adapter = std::make_unique<HackRfAdapter>();
    }
  } catch (...) {
    // No C++ exception may escape the public C ABI.
    g_native_usb_claim = false;
    return SDR_INTERNAL_ERROR;
  }
  // open() dup()s fd itself (see usb_*_adapter.h); the caller's original fd,
  // owned by the Kotlin UsbSdrPlugin/UsbDeviceConnection, is never touched
  // and must stay open for the session (same contract as sdr_v2_open_file).
  const int rc = adapter->open(fd);
  if (rc != SDR_OK) { g_native_usb_claim = false; return rc; }
  std::lock_guard<std::mutex> lock(h->mutex);
  if (h->stats.state != SDR_IDLE) {
    adapter->close();
    g_native_usb_claim = false;
    return SDR_INVALID_STATE;
  }
  h->usb_adapter = std::move(adapter);
  h->owns_usb_claim = true;
  h->stats = SdrStats{};
  h->stats.size = sizeof(SdrStats);
  h->stats.revision = 2;
  h->stats.source = source;
  h->stats.state = SDR_OPEN;
  h->stats.checksum = kFnvOffset;
  h->reset_v3_open();
  return SDR_OK;
}

extern "C" int32_t sdr_v2_configure(SdrHandle* h, uint64_t frequency,
                                      uint32_t rate, int32_t gain) {
  if (!h || !valid_rate(rate) || frequency > 7250000000ULL ||
      gain < -1000 || gain > 1000) return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  if (h->stats.state != SDR_OPEN || h->v3_active) return SDR_INVALID_STATE;
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
    if (h->stats.state != SDR_OPEN || h->v3_active) return SDR_INVALID_STATE;
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
    if (h->v3_active || (h->stats.state != SDR_RUNNING && h->stats.state != SDR_ERROR))
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
  if (h->owns_usb_claim) { h->owns_usb_claim = false; g_native_usb_claim = false; }
  if (h->fd >= 0) { close(h->fd); h->fd = -1; }
  h->stats.state = SDR_IDLE;
  h->stats.source = SDR_NONE;
  h->v3_active = false;
  h->v3_configured = false;
  h->receiver.reset();
  h->snapshot.state = SDR_IDLE;
  h->snapshot.source = SDR_NONE;
  h->fft_unread = false;
  h->fft_bins.clear();
  return SDR_OK;
}

extern "C" int32_t sdr_v2_stats(SdrHandle* h, SdrStats* out) {
  if (!h || !out || out->size != sizeof(SdrStats) || out->revision != 2)
    return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  *out = h->stats;
  return SDR_OK;
}

extern "C" int32_t sdr_v3_set_controls(SdrHandle* h, const SdrV3Controls* in) {
  if (!h || !in || !valid_controls(*in)) return SDR_INVALID_ARGUMENT;
  if (in->agc) return SDR_UNSUPPORTED;  // Hardware AGC is not implemented by the v2 adapters.
  bool restart = false;
  {
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->stats.state != SDR_OPEN && h->stats.state != SDR_RUNNING) return SDR_INVALID_STATE;
    if (h->stats.state == SDR_RUNNING && !h->v3_active) return SDR_INVALID_STATE;
    if (h->stats.source == SDR_RTLSDR && in->center_frequency_hz > UINT32_MAX)
      return SDR_UNSUPPORTED;
    restart = h->stats.state == SDR_RUNNING &&
        (h->stats.frequency_hz != in->center_frequency_hz ||
         h->stats.sample_rate != in->sample_rate ||
         h->stats.gain_tenths_db != in->gain_tenths_db);
  }
  if (restart) {
    const int rc = sdr_v3_stop(h);
    if (rc != SDR_OK) return rc;
  }
  int rc = SDR_OK;
  try {
    std::lock_guard<std::mutex> dsp_lock(h->dsp_mutex);
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->stats.state != SDR_OPEN && h->stats.state != SDR_RUNNING) return SDR_INVALID_STATE;
    if (h->usb_adapter && (h->stats.frequency_hz != in->center_frequency_hz ||
        h->stats.sample_rate != in->sample_rate ||
        h->stats.gain_tenths_db != in->gain_tenths_db || !h->v3_configured)) {
      rc = h->usb_adapter->configure(in->center_frequency_hz, in->sample_rate,
                                      in->gain_tenths_db);
      if (rc != SDR_OK) {
        // A multi-register hardware configure can partially succeed; never
        // advertise the old tune as still running after that failure.
        h->async_error(rc);
        return rc;
      }
    }
    if (!h->receiver) h->receiver = sdrcore::dsp::make_receiver();
    SdrV3Display display = h->display;
    if (!display.size || !valid_display(display, in->sample_rate)) {
      display = SdrV3Display{};
      display.size = sizeof(display);
      display.revision = SDR_V3_REVISION;
      display.view_bandwidth_hz = in->sample_rate;
      display.width = 512;
    }
    h->receiver->configure(*in, display);
    h->controls = *in;
    h->display = display;
    h->v3_configured = true;
    h->stats.frequency_hz = in->center_frequency_hz;
    h->stats.sample_rate = in->sample_rate;
    h->stats.gain_tenths_db = in->gain_tenths_db;
    h->snapshot.center_frequency_hz = in->center_frequency_hz;
    h->snapshot.vfo_offset_hz = in->vfo_offset_hz;
    h->snapshot.sample_rate = in->sample_rate;
    h->snapshot.mode = in->mode;
    h->snapshot.bandwidth_hz = in->bandwidth_hz;
    h->snapshot.gain_tenths_db = in->gain_tenths_db;
    h->snapshot.squelch_ready = 0;
    h->snapshot.squelch_open = 0;
    ++h->snapshot.control_sequence;
    h->fft_unread = false;
    h->fft_bins.clear();
  } catch (...) {
    std::lock_guard<std::mutex> lock(h->mutex);
    h->async_error(SDR_INTERNAL_ERROR);
    return SDR_INTERNAL_ERROR;
  }
  return restart ? sdr_v3_start(h) : SDR_OK;
}

extern "C" int32_t sdr_v3_set_display(SdrHandle* h, const SdrV3Display* in) {
  if (!h || !in) return SDR_INVALID_ARGUMENT;
  try {
    std::lock_guard<std::mutex> dsp_lock(h->dsp_mutex);
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->stats.state != SDR_OPEN && h->stats.state != SDR_RUNNING) return SDR_INVALID_STATE;
    if (h->stats.state == SDR_RUNNING && !h->v3_active) return SDR_INVALID_STATE;
    if (!valid_display(*in, h->v3_configured ? h->controls.sample_rate : h->stats.sample_rate))
      return SDR_INVALID_ARGUMENT;
    h->display = *in;
    if (h->v3_configured) h->receiver->configure(h->controls, *in);
    ++h->snapshot.control_sequence;
    h->fft_unread = false;
    h->fft_bins.clear();
  } catch (...) { return SDR_INTERNAL_ERROR; }
  return SDR_OK;
}

extern "C" int32_t sdr_v3_set_audio_sink(SdrHandle* h, const char* spec,
                                             uint32_t length) {
  if (!h || !spec || !length || length > SDR_V3_MAX_SINK_SPEC_BYTES ||
      std::memchr(spec, 0, length)) return SDR_INVALID_ARGUMENT;
  try {
    std::string copy(spec, length);
    sdrcore::AudioSinkSpec parsed;
    if (!sdrcore::parse_audio_sink_spec(copy.c_str(), &parsed)) return SDR_INVALID_ARGUMENT;
    if (!sdrcore::make_audio_sink(parsed)) return SDR_UNSUPPORTED;
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->stats.state != SDR_OPEN) return SDR_INVALID_STATE;
    h->sink_spec = std::move(copy);
    return SDR_OK;
  } catch (...) { return SDR_INTERNAL_ERROR; }
}

extern "C" int32_t sdr_v3_start(SdrHandle* h) {
  if (!h) return SDR_INVALID_ARGUMENT;
  {
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->stats.state != SDR_OPEN || !h->v3_configured) return SDR_INVALID_STATE;
  }
  try {
    sdrcore::AudioSinkSpec parsed;
    if (!sdrcore::parse_audio_sink_spec(h->sink_spec.c_str(), &parsed)) return SDR_INVALID_ARGUMENT;
    auto sink = sdrcore::make_audio_sink(parsed);
    if (!sink) return SDR_UNSUPPORTED;
    const int rc = sink->open(48000);
    if (rc != SDR_OK) return rc;
    {
      std::lock_guard<std::mutex> dsp_lock(h->dsp_mutex);
      h->receiver->reset();
    }
    {
      std::lock_guard<std::mutex> lock(h->mutex);
      h->audio_sink = std::move(sink);
      h->v3_active = true;
      h->head = h->tail = h->queued = 0;
      // A recording restarts from its beginning (Dart FileSource rewinds on
      // stop). Sockets/pipes cannot seek and simply continue.
      if (h->stats.source == SDR_FILE && h->fd >= 0) (void)lseek(h->fd, 0, SEEK_SET);
      h->producer_done = false;
      h->stopping = false;
      h->stats.state = SDR_RUNNING;
      h->snapshot.state = SDR_RUNNING;
      ++h->snapshot.stream_generation;
      h->snapshot.squelch_ready = 0;
      h->snapshot.squelch_open = 0;
      h->fft_unread = false;
      h->fft_bins.clear();
    }
    h->consumer = std::thread([h] { h->consume_loop(); });
    h->producer = std::thread([h] { h->read_loop(); });
  } catch (...) {
    h->join();
    std::lock_guard<std::mutex> lock(h->mutex);
    h->async_error(SDR_INTERNAL_ERROR);
    return SDR_INTERNAL_ERROR;
  }
  return SDR_OK;
}

extern "C" int32_t sdr_v3_stop(SdrHandle* h) {
  if (!h) return SDR_INVALID_ARGUMENT;
  {
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->v3_active || (h->stats.state != SDR_RUNNING && h->stats.state != SDR_ERROR))
      return SDR_INVALID_STATE;
  }
  h->join();
  std::lock_guard<std::mutex> lock(h->mutex);
  h->stats.state = SDR_OPEN;
  h->snapshot.state = SDR_OPEN;
  h->snapshot.squelch_ready = 0;
  h->snapshot.squelch_open = 0;
  h->fft_unread = false;
  h->fft_bins.clear();
  return SDR_OK;
}

extern "C" int32_t sdr_v3_snapshot(SdrHandle* h, SdrV3Snapshot* out) {
  if (!h || !out || out->size != sizeof(*out) || out->revision != SDR_V3_REVISION)
    return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  SdrV3Snapshot value = h->snapshot;
  value.input_samples = h->stats.input_samples;
  value.processed_samples = h->stats.processed_samples;
  value.dropped_samples = h->stats.dropped_samples;
  *out = value;
  return SDR_OK;
}

extern "C" int32_t sdr_v3_read_fft(SdrHandle* h, uint64_t after_sequence,
                                       SdrV3Fft* out, float* bins, uint32_t capacity) {
  if (!h || !out || out->size != sizeof(*out) || out->revision != SDR_V3_REVISION ||
      capacity > SDR_V3_MAX_FFT_WIDTH || (capacity && !bins)) return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  // Latest valid row newer than after_sequence, read or not (header contract);
  // stop/close/control changes invalidate it by clearing fft_bins.
  if (h->fft_bins.empty() || h->fft.sequence <= after_sequence ||
      h->snapshot.state != SDR_RUNNING) return SDR_V3_NO_DATA;
  if (capacity < h->fft.width) {
    out->width = h->fft.width;
    return SDR_V3_BUFFER_SMALL;
  }
  *out = h->fft;
  std::copy(h->fft_bins.begin(), h->fft_bins.end(), bins);
  h->fft_unread = false;
  return SDR_OK;
}

// Queries the RTL-SDR tuner's gain table through the already-open adapter;
// see native/include/sdrcore_v3.h for the full contract. No second USB
// claim: this reuses h->usb_adapter, the same handle sdr_v2_open_usb /
// sdr_host_open_usb created. Exact migration of the legacy Dart gain path
// (RtlSdrDev.getTunerGains()..sort()); the sort itself happens in
// RtlSdrAdapter::get_tuner_gains (usb_rtlsdr_adapter.cpp).
extern "C" int32_t sdr_v3_rtl_tuner_gains(SdrHandle* h, int32_t* gains,
                                            uint32_t capacity, uint32_t* count) {
  if (!h || !count) return SDR_INVALID_ARGUMENT;
  if (capacity && !gains) return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  if (h->stats.state == SDR_IDLE) { *count = 0; return SDR_INVALID_STATE; }
  if (h->stats.source != SDR_RTLSDR || !h->usb_adapter) {
    *count = 0;
    return SDR_UNSUPPORTED;
  }
  return h->usb_adapter->get_tuner_gains(gains, capacity, count);
}

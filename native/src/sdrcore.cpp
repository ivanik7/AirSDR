// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore_v3.h"
#include "sdrcore_decoder_v1.h"
#include "sdrcore_record_v1.h"
#include "decoder.hpp"

#include "audio/audio_sink.h"
#include "dsp/receiver.h"
#include "sdrcore_internal.h"
#include "usb_adapter.h"
#include "usb_hackrf_adapter.h"
#include "usb_rtlsdr_adapter.h"
#include "rtl_tcp_adapter.h"
#include "record/recorder.h"
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <cstring>
#include <filesystem>
#include <cmath>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#ifdef _WIN32
#include <io.h>
#else
#include <poll.h>
#include <unistd.h>
#endif

namespace {
// Descriptor primitives of the diagnostic file source (sdr_v2_open_file).
// POSIX: the plain calls. Windows (UCRT): the CRT's _dup/_read/_close/_lseeki64
// on CRT file descriptors; there is no poll(), so reads simply block (the
// file source is meant for regular files, where a read never waits).
#ifdef _WIN32
int fd_dup(int fd) { return _dup(fd); }
int fd_close(int fd) { return _close(fd); }
long long fd_read(int fd, void* buf, size_t len) {
  return _read(fd, buf, static_cast<unsigned>(len));
}
bool fd_rewind(int fd) { return _lseeki64(fd, 0, SEEK_SET) == 0; }
#else
int fd_dup(int fd) { return dup(fd); }
int fd_close(int fd) { return close(fd); }
long long fd_read(int fd, void* buf, size_t len) { return read(fd, buf, len); }
bool fd_rewind(int fd) { return lseek(fd, 0, SEEK_SET) == 0; }
#endif

// 64 x 8 KiB = 512 KiB, ~109 ms of CU8 at 2.4 MS/s. Eight slots (27 ms) dropped
// IQ on ordinary scheduler stalls in the 600 s Blog V4 soak (t_848e6a1c).
constexpr size_t kSlots = 64;
constexpr size_t kBytes = 8192;
constexpr uint64_t kFnvOffset = 14695981039346656037ULL;
constexpr uint64_t kFnvPrime = 1099511628211ULL;
bool valid_rate(uint32_t rate) { return rate >= 1000 && rate <= 20000000; }
const char* record_mode(uint32_t mode) {
  static constexpr const char* names[] = {"NFM", "WFM", "AM", "DSB", "USB", "CW", "LSB", "RAW"};
  return mode < sizeof(names) / sizeof(names[0]) ? names[mode] : "UNKNOWN";
}
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
  struct QueuedDecoderEvent {
    SdrDecoderEvent header{};
    std::vector<uint8_t> payload;
  };
  std::unique_ptr<sdrcore::decoder::Decoder> decoder;
  sdrcore::record::Recorder recorder;
  bool keep_recording_on_restart = false;
  sdrcore::decoder::Input decoder_input = sdrcore::decoder::Input::audio;
  uint32_t decoder_required_rate_hz = 0;
  std::deque<QueuedDecoderEvent> decoder_events;
  uint64_t decoder_sequence = 0;
  uint64_t decoder_dropped = 0;
  bool decoder_attached = false;
  bool rbds = false;
  nlohmann::json rds_fields = nlohmann::json::object();
  std::string rds_pi_candidate;
  unsigned rds_pi_repeats = 0;
  std::chrono::steady_clock::time_point rds_last_emit{};
  std::chrono::steady_clock::time_point rds_last_group{};
  bool rds_pending = false;
  bool rds_synced = false;
  void invalidate_decoder_events() { decoder_events.clear(); }
  uint64_t tuned_frequency() const {
    return static_cast<uint64_t>(static_cast<int64_t>(controls.center_frequency_hz) +
                                 controls.vfo_offset_hz);
  }
  void enqueue_decoder_event(sdrcore::decoder::Event event) {
    if (event.payload.size() > SDR_DECODER_MAX_PAYLOAD) {
      ++decoder_dropped;
      return;
    }
    if (decoder_events.size() == SDR_DECODER_QUEUE_CAPACITY) {
      decoder_events.pop_front();
      ++decoder_dropped;
    }
    QueuedDecoderEvent queued_event;
    queued_event.header.size = sizeof(SdrDecoderEvent);
    queued_event.header.revision = SDR_DECODER_REVISION;
    queued_event.header.sequence = ++decoder_sequence;
    queued_event.header.stream_generation = snapshot.stream_generation;
    queued_event.header.kind = static_cast<uint32_t>(event.kind);
    queued_event.header.payload_bytes = static_cast<uint32_t>(event.payload.size());
    queued_event.header.dropped_events = decoder_dropped;
    queued_event.payload = std::move(event.payload);
    decoder_events.push_back(std::move(queued_event));
  }
  void enqueue_rds_json(const nlohmann::json& object) {
    const std::string text = object.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
    enqueue_decoder_event({sdrcore::decoder::Result::message,
                           std::vector<uint8_t>(text.begin(), text.end())});
  }
  void reset_rds(const char* reason) {
    rds_fields = nlohmann::json::object();
    rds_pi_candidate.clear();
    rds_pi_repeats = 0;
    rds_pending = false;
    rds_synced = false;
    rds_last_group = {};
    rds_last_emit = {};
    enqueue_rds_json({{"source", "rds"}, {"version", 1}, {"event", "reset"},
                      {"frequency_hz", tuned_frequency()}, {"rbds", rbds},
                      {"reason", reason}});
  }
  void drain_rds_groups() {
    if (!receiver || controls.mode != SDR_V3_WFM) return;
    std::string raw;
    const auto now = std::chrono::steady_clock::now();
    while (receiver->take_rds_group(raw)) {
      auto group = nlohmann::json::parse(raw, nullptr, false);
      if (group.is_discarded() || !group.is_object()) { ++decoder_dropped; continue; }
      group.erase("group");
      if (group.contains("pi") && group["pi"].is_string() &&
          rds_fields.contains("pi") && group["pi"] != rds_fields["pi"]) {
        const auto candidate = group["pi"].get<std::string>();
        rds_pi_repeats = candidate == rds_pi_candidate ? rds_pi_repeats + 1 : 1;
        rds_pi_candidate = candidate;
        if (rds_pi_repeats < 3) continue;
        reset_rds("pi");
      } else {
        rds_pi_candidate.clear();
        rds_pi_repeats = 0;
      }
      bool changed = false;
      for (auto it = group.begin(); it != group.end(); ++it) {
        if (!rds_fields.contains(it.key()) || rds_fields[it.key()] != it.value()) {
          rds_fields[it.key()] = it.value();
          changed = true;
        }
      }
      rds_last_group = now;
      if (!rds_synced) { rds_synced = true; changed = true; }
      rds_pending |= changed;
    }
    if (rds_last_group != std::chrono::steady_clock::time_point{} &&
        now - rds_last_group > std::chrono::seconds(10)) reset_rds("signal_lost");
    if (rds_pending && (rds_last_emit == std::chrono::steady_clock::time_point{} ||
        now - rds_last_emit >= std::chrono::milliseconds(250))) {
      enqueue_rds_json({{"source", "rds"}, {"version", 1}, {"event", "state"},
                        {"frequency_hz", tuned_frequency()}, {"rbds", rbds},
                        {"fields", rds_fields}, {"sync", receiver->rds_synced()}});
      rds_pending = false;
      rds_last_emit = now;
    }
  }
  void drain_decoder_events() {
    if (!decoder) return;
    sdrcore::decoder::Event event;
    for (size_t i = 0; i < SDR_DECODER_QUEUE_CAPACITY && decoder->take_event(event); ++i) {
      enqueue_decoder_event(std::move(event));
      event = {};
    }
    decoder_dropped += decoder->take_dropped_count();
  }
  std::mutex mutex;
  std::mutex dsp_mutex;
  std::condition_variable ready;
  std::atomic<bool> stopping{false};
  std::thread producer;
  std::thread consumer;
  // Live tuner worker (RUNNING sessions on adapters with live tuning). It
  // owns every tuner control transfer while the stream runs, so
  // sdr_v3_set_controls never waits for USB I2C on the caller's (Flutter UI)
  // thread. The request slot is latest-wins; all fields guarded by `mutex`.
  std::thread tuner;
  std::condition_variable tune_cv;
  SdrV3Controls tune_request{};
  bool tune_pending = false;  // tune_request not yet picked up
  bool tune_busy = false;     // worker is issuing control transfers
  bool tune_quit = false;
  std::array<std::array<uint8_t, kBytes>, kSlots> ring{};
  std::array<size_t, kSlots> lengths{};
  // Per-slot flag: IQ captured before/while the tuner was reprogrammed. Such
  // blocks are still demodulated (audio continues through the channel
  // filters, as in SDR++ and the old Dart engine) but never produce FFT rows
  // or squelch decisions for the new tune.
  std::array<bool, kSlots> slot_stale{};
  size_t head = 0, tail = 0, queued = 0;
  bool producer_done = false;
  // Live retune: input bytes still in flight in the driver's USB transfers
  // when the tuner was reprogrammed (marked stale on arrival), and a counter
  // of applied LO retunes; both guarded by mutex.
  size_t stale_bytes = 0;
  uint64_t lo_retunes = 0;
  int fd = -1;  // exclusively owned duplicate; Java/FFI retains original
  std::unique_ptr<UsbRxAdapter> usb_adapter;  // physical USB or network source
  bool owns_usb_claim = false;
  bool v3_active = false;
  bool v3_configured = false;
  SdrV3Controls controls{};      // latest accepted controls
  SdrV3Controls dsp_controls{};  // controls the receiver currently runs with
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
    invalidate_decoder_events();
    snapshot = SdrV3Snapshot{};
    snapshot.size = sizeof(snapshot);
    snapshot.revision = SDR_V3_REVISION;
    snapshot.source = stats.source;
    snapshot.state = SDR_OPEN;
    snapshot.sample_rate = stats.sample_rate;
    v3_active = false;
    v3_configured = false;
    controls = SdrV3Controls{};
    dsp_controls = SdrV3Controls{};
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
      std::lock_guard<std::mutex> lock(mutex);
      const size_t chunk = std::min(kBytes, length - offset);
      const bool stale = stale_bytes > 0 || tune_in_progress();
      stale_bytes -= std::min(stale_bytes, chunk);
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
        slot_stale[tail] = stale;
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
#ifndef _WIN32
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
#endif
        const long long n = fd_read(fd, bytes.data() + carry, kBytes - carry);
        if (n < 0 && errno == EINTR) continue;
        if (n == 0 && v3_active) {
          // Radio sessions replay recordings in a loop like the Dart
          // FileSource. A non-seekable stream that ends is lost input.
          // An empty recording would spin; treat it like a lost stream.
          if (data_since_rewind && fd_rewind(fd)) {
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

  bool tune_in_progress() const { return tune_pending || tune_busy; }

  // Applies queued live retunes in order, coalescing to the newest request.
  void tune_loop() {
    std::unique_lock<std::mutex> lock(mutex);
    for (;;) {
      tune_cv.wait(lock, [this] { return tune_quit || tune_pending; });
      if (tune_quit) break;
      const SdrV3Controls req = tune_request;
      tune_pending = false;
      tune_busy = true;
      const bool retune_freq = req.center_frequency_hz != stats.frequency_hz;
      const bool retune_gain = req.gain_tenths_db != stats.gain_tenths_db;
      lock.unlock();
      // No core lock is held during control transfers: the USB event thread
      // may need `mutex` inside push() before a synchronous control transfer
      // issued here can complete. join() stops this worker before it stops
      // or closes the adapter, so the adapter stays valid.
      int rc = SDR_OK;
      if (retune_freq) rc = usb_adapter->set_frequency(req.center_frequency_hz);
      if (rc == SDR_OK && retune_gain) rc = usb_adapter->set_gain(req.gain_tenths_db);
      std::unique_lock<std::mutex> dsp_lock(dsp_mutex);
      lock.lock();
      tune_busy = false;
      if (rc != SDR_OK) {
        // The hardware may be partially retuned; never advertise either the
        // old or the requested tune as valid after that failure.
        tune_pending = false;
        controls = dsp_controls;
        if (stats.state == SDR_RUNNING) async_error(rc);
        continue;
      }
      // The tuner really holds `req` now, even if the stream is stopping.
      stats.frequency_hz = req.center_frequency_hz;
      stats.gain_tenths_db = req.gain_tenths_db;
      snapshot.center_frequency_hz = req.center_frequency_hz;
      snapshot.gain_tenths_db = req.gain_tenths_db;
      if (stats.state != SDR_RUNNING) continue;
      try {
        if (retune_freq) {
          invalidate_decoder_events();
          if (req.mode == SDR_V3_WFM || dsp_controls.mode == SDR_V3_WFM)
            reset_rds(req.mode != dsp_controls.mode ? "mode" : "retune");
          // IQ queued in the ring and the driver's in-flight transfers that
          // will still be delivered were captured before the new tune.
          for (size_t i = 0, s = head; i < queued; ++i, s = (s + 1) % kSlots)
            slot_stale[s] = true;
          stale_bytes = usb_adapter->retune_settle_bytes();
          ++lo_retunes;
        }
        receiver->configure(req, display);
        dsp_controls = req;
      } catch (...) {
        async_error(SDR_INTERNAL_ERROR);
        continue;
      }
      snapshot.vfo_offset_hz = req.vfo_offset_hz;
      snapshot.mode = req.mode;
      snapshot.bandwidth_hz = req.bandwidth_hz;
      snapshot.squelch_ready = 0;
      snapshot.squelch_open = 0;
      fft_unread = false;
      fft_bins.clear();
    }
    // Requests not yet applied are dropped; accepted state falls back to
    // what the receiver and hardware actually run.
    tune_pending = false;
    controls = dsp_controls;
  }

  void stop_tuner() {
    if (!tuner.joinable()) return;
    {
      std::lock_guard<std::mutex> lock(mutex);
      tune_quit = true;
      tune_pending = false;
    }
    tune_cv.notify_all();
    tuner.join();  // waits for an in-flight control transfer sequence
  }

  void consume_loop() {
    std::array<uint8_t, kBytes> block{};
    sdrcore::dsp::ProcessResult result;
    uint64_t seen_retunes = 0;
    bool recording_receiver_error_handled = false;
    {
      std::lock_guard<std::mutex> lock(mutex);
      seen_retunes = lo_retunes;
    }
    for (;;) {
      std::unique_lock<std::mutex> lock(mutex);
      ready.wait(lock, [this] { return queued || producer_done; });
      if (!queued && producer_done) {
        lock.unlock();
        if (!stopping.load())
          recorder.stop(SDR_RECORD_STOP_RECEIVER);
        return;
      }
      const size_t length = lengths[head];
      const bool dsp = v3_active;
      // A row may only be published under the control epoch it was computed
      // in, and never from IQ captured before or during a live retune.
      const uint64_t dequeued_sequence = snapshot.control_sequence;
      const bool stale = slot_stale[head] || tune_in_progress();
      // First block of a new LO: forget the old station's FFT accumulation,
      // squelch history and pilot lock (filters/audio keep running).
      const bool new_station = !stale && seen_retunes != lo_retunes;
      if (new_station) seen_retunes = lo_retunes;
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
        if (new_station) receiver->retune();
        // Stale ring/USB transfers must never enter the decoder. Detach
        // during the gap and reattach only on a clean block of the new tune.
        if (decoder && (stale || !decoder_attached)) {
          receiver->set_decoder(stale ? nullptr : decoder.get(), decoder_input,
                                decoder_required_rate_hz);
          decoder_attached = !stale;
        }
        receiver->set_rds_suspended(stale);
        receiver->process(block.data(), length, result);
        const auto& applied = dsp_controls;
        const std::string mode = record_mode(applied.mode);
        bool record_current;
        {
          std::lock_guard<std::mutex> state_lock(mutex);
          record_current = !stale && !tune_in_progress() &&
              dequeued_sequence == snapshot.control_sequence &&
              snapshot.state == SDR_RUNNING;
        }
        if (record_current) recorder.offer_iq(block.data(), length, applied.sample_rate,
                                               applied.center_frequency_hz, mode);
        if (record_current && !result.recording_pcm.empty() &&
            !(decoder && decoder_input != sdrcore::decoder::Input::audio &&
              !(decoder_attached && decoder->provides_audio()))) {
          std::vector<sdrcore::record::Edge> edges;
          edges.reserve(result.recording_squelch_edges.size());
          for (const auto& edge : result.recording_squelch_edges)
            edges.push_back({edge.frame_offset, edge.open});
          recorder.offer_audio(result.recording_pcm.data(),
              result.recording_pcm.size() / result.recording_channels,
              result.recording_channels, edges, applied.center_frequency_hz, mode);
        }
        if (decoder && decoder_attached || dsp_controls.mode == SDR_V3_WFM) {
          std::lock_guard<std::mutex> state_lock(mutex);
          if (!stale && dequeued_sequence == snapshot.control_sequence &&
              !tune_in_progress() && snapshot.state == SDR_RUNNING) {
            if (decoder && decoder_attached) drain_decoder_events();
            drain_rds_groups();
          }
          else {
            sdrcore::decoder::Event discarded;
            for (size_t i = 0; decoder && i < SDR_DECODER_QUEUE_CAPACITY &&
                 decoder->take_event(discarded); ++i) discarded = {};
            std::string discarded_rds;
            while (receiver->take_rds_group(discarded_rds)) {}
          }
        }
        // Baseband decoders (rtl_433) keep their mute-while-decoding policy.
        // Audio-tap decoders (SSTV) listen alongside the operator, as in
        // OpenWebRX+: selection never mutes voice audio implicitly.
        // Voice decoders (DMR, Decoder::provides_audio) already replaced the
        // block with their synthesized PCM inside the receiver; while
        // detached for a stale slot they are muted like other baseband ones.
        if (decoder && decoder_input != sdrcore::decoder::Input::audio &&
            !(decoder_attached && decoder->provides_audio()))
          std::fill(result.audio.begin(), result.audio.end(), 0.0f);
        if (!result.audio.empty())
          audio_sink->write(result.audio.data(), result.audio.size() / 2);
        audio_stats = audio_sink->stats();
      } catch (...) {
        { std::lock_guard<std::mutex> failed(mutex); async_error(SDR_INTERNAL_ERROR); }
        recorder.stop(SDR_RECORD_STOP_RECEIVER);
        return;
      }
      lock.lock();
      // A control change committed between process() and here must not
      // stamp a row computed under the previous controls as current.
      const bool current = dequeued_sequence == snapshot.control_sequence &&
          !stale && !tune_in_progress();
      stats.processed_samples += length / 2;
      if (current) {
        snapshot.squelch_metric_db = result.signal_db;
        snapshot.squelch_threshold_db = result.squelch_threshold_db;
        snapshot.squelch_ready = result.squelch_ready;
        snapshot.squelch_open = result.squelch_open;
      }
      snapshot.audio_frames = audio_base_frames + audio_stats.frames_written;
      snapshot.audio_dropped_frames = audio_base_dropped + audio_stats.frames_dropped;
      snapshot.audio_nonsilent_frames = audio_base_nonsilent + audio_stats.nonsilent_frames;
      if (audio_stats.last_error && snapshot.state != SDR_ERROR)
        async_error(audio_stats.last_error);
      if (current && !result.fft.empty() && snapshot.state == SDR_RUNNING) {
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
        fft.low_hz = static_cast<int64_t>(dsp_controls.center_frequency_hz) +
            display.view_offset_hz - static_cast<int64_t>(display.view_bandwidth_hz / 2);
        fft.high_hz = fft.low_hz + display.view_bandwidth_hz;
        fft.width = static_cast<uint32_t>(fft_bins.size());
        fft_unread = true;
      }
      if (snapshot.state == SDR_ERROR && !recording_receiver_error_handled) {
        lock.unlock();
        recorder.stop(SDR_RECORD_STOP_RECEIVER);
        recording_receiver_error_handled = true;
      }
    }
  }

  void join() {
    // The tuner worker must be idle before the adapter is stopped or closed.
    stop_tuner();
    stopping = true;
    if (usb_adapter && producer.joinable()) usb_adapter->stop();
    if (producer.joinable()) producer.join();
    { std::lock_guard<std::mutex> lock(mutex); producer_done = true; }
    ready.notify_all();
    if (consumer.joinable()) consumer.join();
    if (!keep_recording_on_restart) recorder.stop(SDR_RECORD_STOP_RECEIVER);
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
  if (handle->receiver) handle->receiver->set_decoder(nullptr);
  if (handle->usb_adapter) handle->usb_adapter->close();
  if (handle->owns_usb_claim) g_native_usb_claim = false;
  if (handle->fd >= 0) fd_close(handle->fd);
  delete handle;
}

extern "C" int32_t sdr_v2_open_file(SdrHandle* h, int32_t fd, uint32_t rate) {
  if (!h || fd < 0 || !valid_rate(rate)) return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  if (h->stats.state != SDR_IDLE) return SDR_INVALID_STATE;
  int copy = fd_dup(fd);
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

namespace {
// Shared by the fd path (sdr_v2_open_usb) and the desktop direct path
// (sdrcore_open_usb_bus_address): state check, the single process-wide native
// USB claim, adapter creation and the IDLE -> OPEN transition. `open_device`
// runs the adapter's open call without the handle lock held.
template <typename OpenFn>
int32_t open_usb_session(SdrHandle* h, uint32_t source, OpenFn open_device) {
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
  const int rc = open_device(*adapter);
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
}  // namespace

// Internal (hidden) entry points of the desktop host layer, see
// sdrcore_internal.h. Validation of bus/address/source is done by the caller.
int32_t sdrcore_open_usb_bus_address(SdrHandle* h, uint8_t bus, uint8_t address,
                                     uint32_t source) {
  return open_usb_session(h, source, [&](UsbRxAdapter& adapter) {
    return adapter.open_bus_address(bus, address);
  });
}

bool sdrcore_native_usb_claim_active() { return g_native_usb_claim.load(); }

extern "C" int32_t sdr_v2_open_usb(SdrHandle* h, int32_t fd, uint32_t source) {
  if (!h || fd < 0 || (source != SDR_RTLSDR && source != SDR_HACKRF))
    return SDR_INVALID_ARGUMENT;
  // open() dup()s fd itself (see usb_*_adapter.h); the caller's original fd,
  // owned by the Kotlin UsbSdrPlugin/UsbDeviceConnection, is never touched
  // and must stay open for the session (same contract as sdr_v2_open_file).
  return open_usb_session(h, source, [fd](UsbRxAdapter& adapter) {
    return adapter.open(fd);
  });
}

extern "C" int32_t sdr_v3_open_rtl_tcp(SdrHandle* h, const char* host,
                                         uint32_t host_bytes, uint16_t port) {
  if (!h || !host || !port || !host_bytes || host_bytes > 255 ||
      std::memchr(host, 0, host_bytes)) return SDR_INVALID_ARGUMENT;
  try {
    auto adapter = std::make_unique<RtlTcpAdapter>(std::string(host, host_bytes), port);
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->stats.state != SDR_IDLE) return SDR_INVALID_STATE;
    h->usb_adapter = std::move(adapter);
    h->stats = SdrStats{};
    h->stats.size = sizeof(SdrStats);
    h->stats.revision = 2;
    h->stats.source = SDR_RTL_TCP;
    h->stats.state = SDR_OPEN;
    h->stats.checksum = kFnvOffset;
    h->reset_v3_open();
    return SDR_OK;
  } catch (...) { return SDR_INTERNAL_ERROR; }
}

extern "C" int32_t sdr_v3_rtl_tcp_link(SdrHandle* h) {
  if (!h) return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  if (h->stats.source != SDR_RTL_TCP ||
      (h->stats.state != SDR_OPEN && h->stats.state != SDR_RUNNING))
    return SDR_INVALID_STATE;
  return static_cast<RtlTcpAdapter*>(h->usb_adapter.get())->connected() ? 1 : 0;
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
    if (h->stats.state != SDR_OPEN || h->v3_active ||
        h->stats.source == SDR_RTL_TCP) return SDR_INVALID_STATE;
    if (h->usb_adapter && h->stats.sample_rate == 0) return SDR_INVALID_STATE;
    h->head = h->tail = h->queued = 0;
    h->stale_bytes = 0;
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
  if (h->fd >= 0) { fd_close(h->fd); h->fd = -1; }
  h->stats.state = SDR_IDLE;
  h->stats.source = SDR_NONE;
  h->v3_active = false;
  h->v3_configured = false;
  if (h->receiver) h->receiver->set_decoder(nullptr);
  h->decoder_attached = false;
  h->decoder.reset();
  h->invalidate_decoder_events();
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
    if ((h->stats.source == SDR_RTLSDR || h->stats.source == SDR_RTL_TCP) &&
        in->center_frequency_hz > UINT32_MAX)
      return SDR_UNSUPPORTED;
    if (h->stats.source == SDR_RTL_TCP &&
        !((in->sample_rate >= 225001 && in->sample_rate <= 300000) ||
          (in->sample_rate >= 900001 && in->sample_rate <= 3200000)))
      return SDR_UNSUPPORTED;
    if (h->decoder && h->decoder_input == sdrcore::decoder::Input::baseband &&
        (in->sample_rate < 200000 ||
         in->sample_rate / std::max(1u, (in->sample_rate + 299999u) / 300000u) < 200000))
      return SDR_UNSUPPORTED; // Existing baseband decoder cannot run at this rate.
    // LO/gain changes on a device that tunes while streaming are applied in
    // place (as SDR++ does): a full restart cancels USB transfers, joins both
    // threads and closes/reopens the audio device, which took ~420 ms per
    // retune on Android and blocked the calling UI thread. Even the tuner
    // I2C alone (~29 ms on SM-F936B + Blog V4) is too long for the UI
    // thread, so the request is only accepted here and the tuner worker
    // applies it (latest wins). While a retune is outstanding every later
    // request takes the same queue, so requests apply in order. Sample-rate
    // changes still restart because they reshape the whole DSP chain.
    const bool live_capable = h->stats.state == SDR_RUNNING && h->v3_configured &&
        h->tuner.joinable() && h->stats.sample_rate == in->sample_rate;
    if (live_capable && (h->tune_in_progress() ||
        h->controls.center_frequency_hz != in->center_frequency_hz ||
        h->controls.gain_tenths_db != in->gain_tenths_db)) {
      const bool rds_tune_changed =
          static_cast<int64_t>(h->controls.center_frequency_hz) + h->controls.vfo_offset_hz !=
          static_cast<int64_t>(in->center_frequency_hz) + in->vfo_offset_hz;
      const bool rds_mode_changed = h->controls.mode != in->mode;
      h->controls = *in;
      if (h->dsp_controls.center_frequency_hz != in->center_frequency_hz ||
          h->dsp_controls.vfo_offset_hz != in->vfo_offset_hz ||
          (h->decoder_input == sdrcore::decoder::Input::audio &&
           h->dsp_controls.mode != in->mode))
        h->invalidate_decoder_events();
      if (rds_tune_changed || rds_mode_changed)
        h->reset_rds(rds_mode_changed ? "mode" : "retune");
      h->tune_request = *in;
      h->tune_pending = true;
      // The epoch advances now: rows and squelch decisions of the previous
      // controls are invalid at once; rows of the new tune are published
      // only after the worker has applied it.
      ++h->snapshot.control_sequence;
      h->snapshot.squelch_ready = 0;
      h->snapshot.squelch_open = 0;
      h->fft_unread = false;
      h->fft_bins.clear();
      h->tune_cv.notify_one();
      return SDR_OK;
    }
    const bool hardware = h->stats.frequency_hz != in->center_frequency_hz ||
        h->stats.gain_tenths_db != in->gain_tenths_db ||
        h->stats.sample_rate != in->sample_rate;
    restart = h->stats.state == SDR_RUNNING && hardware;
    if (restart) h->keep_recording_on_restart = true;
  }
  if (restart) {
    const int rc = sdr_v3_stop(h);
    if (rc != SDR_OK) {
      h->keep_recording_on_restart = false;
      h->recorder.stop(SDR_RECORD_STOP_RECEIVER);
      return rc;
    }
  }
  // Every early error path after the receiver was stopped must end recording;
  // only a successful replacement stream may keep the same session alive.
  struct RestartGuard {
    SdrHandle* handle;
    bool armed;
    ~RestartGuard() {
      if (armed) {
        handle->keep_recording_on_restart = false;
        handle->recorder.stop(SDR_RECORD_STOP_RECEIVER);
      }
    }
  } restart_guard{h, restart};
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
    const bool old_wfm = h->v3_configured && h->controls.mode == SDR_V3_WFM;
    const bool rds_mode_changed = h->v3_configured && h->controls.mode != in->mode;
    const bool rds_tune_changed = h->v3_configured &&
        (static_cast<int64_t>(h->controls.center_frequency_hz) + h->controls.vfo_offset_hz !=
         static_cast<int64_t>(in->center_frequency_hz) + in->vfo_offset_hz);
    SdrV3Display display = h->display;
    if (!display.size || !valid_display(display, in->sample_rate)) {
      display = SdrV3Display{};
      display.size = sizeof(display);
      display.revision = SDR_V3_REVISION;
      display.view_bandwidth_hz = in->sample_rate;
      display.width = 512;
    }
    h->receiver->configure(*in, display);
    h->receiver->set_rds_rbds(h->rbds);
    if (h->decoder && (h->dsp_controls.center_frequency_hz != in->center_frequency_hz ||
                       h->dsp_controls.vfo_offset_hz != in->vfo_offset_hz ||
                       h->dsp_controls.sample_rate != in->sample_rate ||
                       h->dsp_controls.mode != in->mode))
      h->invalidate_decoder_events();
    h->controls = *in;
    h->dsp_controls = *in;
    if ((old_wfm || in->mode == SDR_V3_WFM) &&
        (rds_mode_changed || rds_tune_changed)) {
      h->invalidate_decoder_events();
      h->reset_rds(rds_mode_changed ? "mode" : "retune");
    }
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
  if (!restart) return SDR_OK;
  const int start_rc = sdr_v3_start(h);
  h->keep_recording_on_restart = false;
  if (start_rc == SDR_OK) restart_guard.armed = false;
  return start_rc;
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
    if (h->v3_configured) h->receiver->configure(h->dsp_controls, *in);
    ++h->snapshot.control_sequence;
    h->fft_unread = false;
    h->fft_bins.clear();
  } catch (...) { return SDR_INTERNAL_ERROR; }
  return SDR_OK;
}

extern "C" int32_t sdr_v3_set_wfm_stereo(SdrHandle* h, uint32_t enabled) {
  if (!h || enabled > 1) return SDR_INVALID_ARGUMENT;
  try {
    // Same lock order as controls/display; process() holds dsp_mutex while
    // touching receiver state. This call never reconfigures hardware.
    std::lock_guard<std::mutex> dsp_lock(h->dsp_mutex);
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->v3_configured || !h->receiver ||
        (h->stats.state != SDR_OPEN && h->stats.state != SDR_RUNNING) ||
        (h->stats.state == SDR_RUNNING && !h->v3_active))
      return SDR_INVALID_STATE;
    h->receiver->set_wfm_stereo(enabled != 0);
    ++h->snapshot.control_sequence;
    h->fft_unread = false;
    h->fft_bins.clear();
  } catch (...) { return SDR_INTERNAL_ERROR; }
  return SDR_OK;
}

extern "C" int32_t sdr_rds_set_rbds(SdrHandle* h, uint32_t enabled) {
  if (!h || enabled > 1) return SDR_INVALID_ARGUMENT;
  try {
    std::lock_guard<std::mutex> dsp_lock(h->dsp_mutex);
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->v3_configured || !h->receiver ||
        (h->stats.state != SDR_OPEN && h->stats.state != SDR_RUNNING) ||
        (h->stats.state == SDR_RUNNING && !h->v3_active)) return SDR_INVALID_STATE;
    if (h->rbds == (enabled != 0)) return SDR_OK;
    h->rbds = enabled != 0;
    h->receiver->set_rds_rbds(h->rbds);
    h->invalidate_decoder_events();
    if (h->controls.mode == SDR_V3_WFM) h->reset_rds("rbds");
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
    if (h->stats.source == SDR_RTL_TCP)
      static_cast<RtlTcpAdapter*>(h->usb_adapter.get())->prepare_start();
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
      h->stale_bytes = 0;
      // A recording restarts from its beginning (Dart FileSource rewinds on
      // stop). Sockets/pipes cannot seek and simply continue.
      if (h->stats.source == SDR_FILE && h->fd >= 0) (void)fd_rewind(h->fd);
      h->producer_done = false;
      h->stopping = false;
      h->stats.state = SDR_RUNNING;
      h->snapshot.state = SDR_RUNNING;
      ++h->snapshot.stream_generation;
      h->invalidate_decoder_events();
      if (h->controls.mode == SDR_V3_WFM) h->reset_rds("generation");
      h->snapshot.squelch_ready = 0;
      h->snapshot.squelch_open = 0;
      h->fft_unread = false;
      h->fft_bins.clear();
    }
    h->consumer = std::thread([h] { h->consume_loop(); });
    h->producer = std::thread([h] { h->read_loop(); });
    if (h->usb_adapter && h->usb_adapter->supports_live_tuning()) {
      {
        std::lock_guard<std::mutex> lock(h->mutex);
        h->tune_quit = false;
        h->tune_pending = h->tune_busy = false;
      }
      h->tuner = std::thread([h] { h->tune_loop(); });
    }
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
  h->invalidate_decoder_events();
  h->rds_fields = nlohmann::json::object();
  h->rds_pending = h->rds_synced = false;
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

extern "C" int32_t sdr_decoder_select(SdrHandle* h, const char* id,
                                       uint32_t id_bytes, const char* config,
                                       uint32_t config_bytes) {
  if (!h || (id_bytes && !id) || (config_bytes && !config) ||
      id_bytes > 31 || config_bytes > 4096 ||
      (id_bytes && std::memchr(id, 0, id_bytes))) return SDR_INVALID_ARGUMENT;
  try {
    std::lock_guard<std::mutex> dsp_lock(h->dsp_mutex);
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->v3_configured || !h->receiver ||
        (h->stats.state != SDR_OPEN && h->stats.state != SDR_RUNNING) ||
        (h->stats.state == SDR_RUNNING && !h->v3_active)) return SDR_INVALID_STATE;
    if (!id_bytes) {
      h->receiver->set_decoder(nullptr);
      h->decoder_attached = false;
      h->decoder.reset();
      h->invalidate_decoder_events();
      h->decoder_dropped = 0;
      return SDR_OK;
    }
    const std::string requested(id, id_bytes);
    for (const auto& reg : sdrcore::decoder::registry()) {
      if (requested != reg.descriptor.id) continue;
      if (!reg.create) return SDR_UNSUPPORTED;
      if (reg.descriptor.exclusive_receiver && h->stats.state == SDR_RUNNING)
        return SDR_INVALID_STATE;
      if (reg.descriptor.required_mode != UINT32_MAX &&
          reg.descriptor.required_mode != h->controls.mode) return SDR_UNSUPPORTED;
      const uint32_t sample_rate = h->controls.sample_rate;
      if (reg.descriptor.input == sdrcore::decoder::Input::baseband &&
          ((reg.descriptor.required_rate_hz == 1000000 &&
            (sample_rate < 1000000 ||
             std::abs(static_cast<int64_t>(h->controls.vfo_offset_hz)) + 500000 >
                 static_cast<int64_t>(sample_rate) / 2)) ||
           (reg.descriptor.required_rate_hz == 0 &&
            (sample_rate < 200000 ||
             sample_rate / std::max(1u, (sample_rate + 125000u) / 250000u) < 200000)) ||
           (reg.descriptor.required_rate_hz != 0 &&
            reg.descriptor.required_rate_hz != 1000000)))
        return SDR_UNSUPPORTED;
      if (reg.descriptor.input == sdrcore::decoder::Input::raw_iq &&
          (sample_rate < reg.descriptor.required_rate_hz ||
           std::abs(static_cast<int64_t>(h->controls.vfo_offset_hz)) +
               static_cast<int64_t>(reg.descriptor.required_rate_hz) / 2 >
               static_cast<int64_t>(sample_rate) / 2)) return SDR_UNSUPPORTED;
      auto candidate = reg.create();
      if (!candidate) return SDR_UNSUPPORTED;
      if (!candidate->configure(std::string_view(config ? config : "", config_bytes)))
        return SDR_INVALID_ARGUMENT;
      // Audio-tap backends (SSTV: USB/LSB/NFM, optionally pinned to one
      // configured underlying demod) must accept the applied mode now;
      // selection never changes the mode itself (decoder.hpp).
      if (reg.descriptor.input == sdrcore::decoder::Input::audio &&
          !candidate->accepts_mode(h->controls.mode)) return SDR_UNSUPPORTED;
      // Commit only after every validation succeeds. No second tuner or
      // control change; receiver owns a borrowed pointer under dsp_mutex.
      h->receiver->set_decoder(nullptr);
      h->decoder = std::move(candidate);
      h->decoder_input = reg.descriptor.input;
      h->decoder_required_rate_hz = reg.descriptor.required_rate_hz;
      h->decoder_attached = true;
      h->receiver->set_decoder(h->decoder.get(), h->decoder_input,
                               h->decoder_required_rate_hz);
      h->invalidate_decoder_events();
      h->decoder_dropped = 0;
      return SDR_OK;
    }
    return SDR_UNSUPPORTED;
  } catch (...) { return SDR_INTERNAL_ERROR; }
}

extern "C" int32_t sdr_decoder_poll(SdrHandle* h, uint64_t after_sequence,
                                     SdrDecoderEvent* event, uint8_t* payload,
                                     uint32_t capacity) {
  if (!h || !event || event->size != sizeof(*event) ||
      event->revision != SDR_DECODER_REVISION || (capacity && !payload))
    return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(h->mutex);
  if (h->snapshot.state != SDR_RUNNING) return SDR_DECODER_NO_DATA;
  const auto it = std::find_if(h->decoder_events.begin(), h->decoder_events.end(),
      [after_sequence](const SdrHandle::QueuedDecoderEvent& e) {
        return e.header.sequence > after_sequence;
      });
  if (it == h->decoder_events.end()) return SDR_DECODER_NO_DATA;
  if (capacity < it->payload.size()) {
    event->payload_bytes = static_cast<uint32_t>(it->payload.size());
    return SDR_DECODER_BUFFER_SMALL;
  }
  *event = it->header;
  event->dropped_events = h->decoder_dropped;
  if (!it->payload.empty()) std::memcpy(payload, it->payload.data(), it->payload.size());
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

extern "C" uint32_t sdr_record_version(void) { return SDR_RECORD_REVISION; }

extern "C" int32_t sdr_record_capabilities(uint32_t* streams, uint32_t* formats) {
  if (streams) *streams = SDR_RECORD_IQ | SDR_RECORD_AUDIO | SDR_RECORD_SQUELCH_AUDIO;
  if (formats) *formats = 1u << SDR_RECORD_WAV;
  return SDR_OK;
}

extern "C" int32_t sdr_record_set_provider(const char* scheme,
                                             uint32_t scheme_bytes,
                                             SdrRecordCreateFile fn, void* context) {
  try { return sdrcore::record::set_provider(scheme, scheme_bytes, fn, context); }
  catch (...) { return SDR_INTERNAL_ERROR; }
}

extern "C" int32_t sdr_record_set_notify(SdrHandle* h,
                                           SdrRecordNotify fn, void* context) {
  if (!h) return SDR_INVALID_ARGUMENT;
  h->recorder.set_notify(fn, context);
  return SDR_OK;
}

extern "C" int32_t sdr_record_start(SdrHandle* h,
                                      const SdrRecordConfig* config,
                                      const char* folder, uint32_t folder_bytes,
                                      const char* log_ids, uint32_t log_ids_bytes) {
  if (!h || !config || config->size != sizeof(*config) ||
      config->revision != SDR_RECORD_REVISION || !config->streams ||
      (config->streams & ~SDR_RECORD_STREAM_MASK) ||
      config->utc_offset_minutes < -840 || config->utc_offset_minutes > 840 ||
      config->start_unix_ms <= 0 ||
      !folder || !folder_bytes || folder_bytes > SDR_RECORD_MAX_FOLDER_BYTES ||
      std::memchr(folder, 0, folder_bytes) ||
      (log_ids_bytes && !log_ids) || log_ids_bytes > SDR_RECORD_MAX_LOG_IDS_BYTES ||
      (log_ids && log_ids_bytes && std::memchr(log_ids, 0, log_ids_bytes)))
    return SDR_INVALID_ARGUMENT;
  for (uint32_t n : config->reserved) if (n) return SDR_INVALID_ARGUMENT;
  // A malformed locator is an argument error, not an unavailable encoder or
  // an unregistered provider. `file:` always names an absolute native path.
  try {
    const std::string locator(folder, folder_bytes);
    const auto colon = locator.find(':');
    if (colon == std::string::npos || colon == 0 || colon > 16 ||
        colon + 1 == locator.size()) return SDR_INVALID_ARGUMENT;
    for (size_t i = 0; i < colon; ++i) {
      const char ch = locator[i];
      if (i == 0 ? ch < 'a' || ch > 'z' :
          !((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') ||
            ch == '+' || ch == '.' || ch == '-')) return SDR_INVALID_ARGUMENT;
    }
    if (locator.compare(0, 5, "file:") == 0 &&
        !std::filesystem::u8path(locator.substr(5)).is_absolute())
      return SDR_INVALID_ARGUMENT;
    const bool audio = config->streams & (SDR_RECORD_AUDIO | SDR_RECORD_SQUELCH_AUDIO);
    if ((!audio && (config->audio_format != SDR_RECORD_FORMAT_NONE || config->audio_bitrate_kbps)) ||
        (audio && config->audio_format == SDR_RECORD_FORMAT_NONE) ||
        config->audio_format > SDR_RECORD_OPUS ||
        ((config->streams & SDR_RECORD_DECODER_LOG) != 0 && log_ids_bytes == 0) ||
        ((config->streams & SDR_RECORD_DECODER_LOG) == 0 && log_ids_bytes != 0))
      return SDR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->v3_active || h->stats.state != SDR_RUNNING) return SDR_INVALID_STATE;
    if (config->streams & SDR_RECORD_DECODER_LOG ||
        (audio && (config->audio_format != SDR_RECORD_WAV || config->audio_bitrate_kbps)))
      return SDR_UNSUPPORTED;
    if (!sdrcore::record::supports_folder(locator)) return SDR_UNSUPPORTED;
    return h->recorder.start(*config, locator);
  } catch (...) { return SDR_INTERNAL_ERROR; }
}

extern "C" int32_t sdr_record_stop(SdrHandle* h) {
  if (!h) return SDR_INVALID_ARGUMENT;
  // Do not hold the receiver mutex across join/provider/notification calls.
  return h->recorder.stop(SDR_RECORD_STOP_USER);
}

extern "C" int32_t sdr_record_status(SdrHandle* h, SdrRecordStatus* out) {
  if (!h || !out || out->size != sizeof(*out) || out->revision != SDR_RECORD_REVISION)
    return SDR_INVALID_ARGUMENT;
  *out = h->recorder.status();
  return SDR_OK;
}

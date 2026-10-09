// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore_v3.h"
#include "sdrcore_decoder_v1.h"
#include "decoder.hpp"

#include "audio/audio_sink.h"
#include "dsp/receiver.h"
#include "usb_adapter.h"
#include "usb_hackrf_adapter.h"
#include "usb_rtlsdr_adapter.h"
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <deque>
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
  struct QueuedDecoderEvent {
    SdrDecoderEvent header{};
    std::vector<uint8_t> payload;
  };
  std::unique_ptr<sdrcore::decoder::Decoder> decoder;
  sdrcore::decoder::Input decoder_input = sdrcore::decoder::Input::audio;
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
  std::unique_ptr<UsbRxAdapter> usb_adapter;  // set only for SDR_RTLSDR/HACKRF
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
    {
      std::lock_guard<std::mutex> lock(mutex);
      seen_retunes = lo_retunes;
    }
    for (;;) {
      std::unique_lock<std::mutex> lock(mutex);
      ready.wait(lock, [this] { return queued || producer_done; });
      if (!queued && producer_done) return;
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
          receiver->set_decoder(stale ? nullptr : decoder.get(), decoder_input);
          decoder_attached = !stale;
        }
        receiver->set_rds_suspended(stale);
        receiver->process(block.data(), length, result);
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
        if (decoder && decoder_input != sdrcore::decoder::Input::audio)
          std::fill(result.audio.begin(), result.audio.end(), 0.0f);
        if (!result.audio.empty())
          audio_sink->write(result.audio.data(), result.audio.size() / 2);
        audio_stats = audio_sink->stats();
      } catch (...) {
        std::lock_guard<std::mutex> failed(mutex);
        async_error(SDR_INTERNAL_ERROR);
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
  if (h->fd >= 0) { close(h->fd); h->fd = -1; }
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
    if (h->stats.source == SDR_RTLSDR && in->center_frequency_hz > UINT32_MAX)
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
                       (h->decoder_input == sdrcore::decoder::Input::audio &&
                        h->dsp_controls.mode != in->mode)))
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
      if (h->stats.source == SDR_FILE && h->fd >= 0) (void)lseek(h->fd, 0, SEEK_SET);
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
          (sample_rate < 200000 ||
           sample_rate / std::max(1u, (sample_rate + 125000u) / 250000u) < 200000))
        return SDR_UNSUPPORTED;
      if (reg.descriptor.input == sdrcore::decoder::Input::raw_iq &&
          reg.descriptor.required_rate_hz &&
          sample_rate != reg.descriptor.required_rate_hz) return SDR_UNSUPPORTED;
      auto candidate = reg.create();
      if (!candidate) return SDR_UNSUPPORTED;
      if (!candidate->configure(std::string_view(config ? config : "", config_bytes)))
        return SDR_INVALID_ARGUMENT;
      // Commit only after every validation succeeds. No second tuner or
      // control change; receiver owns a borrowed pointer under dsp_mutex.
      h->receiver->set_decoder(nullptr);
      h->decoder = std::move(candidate);
      h->decoder_input = reg.descriptor.input;
      h->decoder_attached = true;
      h->receiver->set_decoder(h->decoder.get());
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

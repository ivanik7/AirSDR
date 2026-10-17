// SPDX-License-Identifier: GPL-3.0-or-later
//
// Regression test for the audio gap on discrete frequency switches (kanban
// t_8063d101): preset/channel taps, step buttons, frequency entry and band
// jumps are LO retunes to another station on a running RTL session.
//
// White-box: includes sdrcore.cpp, injects a fake live-tuning RTL adapter that
// delivers CU8 IQ paced at 2.4 MS/s in real time (8 KiB per 1.7 ms, like the
// librtlsdr async transfers), and swaps the audio sink for a model of the
// AAudio output: the production PcmRing (60 ms pre-roll, re-prime after an
// underflow) drained by a callback thread that pulls 192 frames every 4 ms.
// Every "station" carries the same strong FM tone, so any dip in the sink
// output or any zero-filled callback frame is caused by the switch path, not
// by RF content.
//
// The switch path must keep the DSP thread and the caller (Flutter UI thread)
// free of long work: whatever the DSP thread spends on a switch is taken out
// of the 60 ms playback cushion, and a switch that eats the cushion is an
// audible hole on a phone whose DSP thread runs slower than this host.
#include "../src/sdrcore.cpp"

#include "../src/audio/pcm_ring.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
constexpr double kPi = 3.14159265358979323846;
constexpr uint32_t kRate = 2400000;
constexpr size_t kChunkBytes = 8192;  // RtlSdrAdapter::kTransferBytes
// Stand-in for the measured tuner I2C time (29 ms phone, 49 ms Blog V4 host).
constexpr auto kTuneDelay = std::chrono::milliseconds(40);
constexpr size_t kCallbackFrames = 192;  // AAudio LOW_LATENCY burst, 4 ms
int failures = 0;

#define CHECK(cond, ...)                                        \
  do {                                                          \
    if (!(cond)) {                                              \
      std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
      std::fprintf(stderr, __VA_ARGS__);                        \
      std::fprintf(stderr, "\n");                               \
      ++failures;                                               \
    } else {                                                    \
      std::printf("[ok] ");                                     \
      std::printf(__VA_ARGS__);                                 \
      std::printf("\n");                                        \
    }                                                           \
  } while (0)

double ms_between(Clock::time_point a, Clock::time_point b) {
  return std::chrono::duration<double, std::milli>(b - a).count();
}

// Same FM signal at every tuned frequency: 1 kHz tone, 50 kHz deviation
// (WFM) or 2.5 kHz (NFM). Periodic over 2400 samples, so a precomputed table
// loops without a phase jump.
std::vector<uint8_t> fm_table(double deviation_hz) {
  const size_t period = kRate / 1000;
  std::vector<uint8_t> table(2 * period);
  const double beta = deviation_hz / 1000.0;
  for (size_t n = 0; n < period; ++n) {
    const double phase = beta * std::sin(2 * kPi * 1000.0 * n / kRate);
    table[2 * n] = static_cast<uint8_t>(std::lround(127.5 + 110 * std::cos(phase)));
    table[2 * n + 1] = static_cast<uint8_t>(std::lround(127.5 + 110 * std::sin(phase)));
  }
  return table;
}

class PacedFakeRtl : public UsbRxAdapter {
 public:
  explicit PacedFakeRtl(std::vector<uint8_t> table) : table_(std::move(table)) {}
  int open(int) override { return SDR_OK; }
  int configure(uint64_t, uint32_t, int32_t) override { return SDR_OK; }
  int start(PushFn push, void* ctx) override {
    std::vector<uint8_t> chunk(kChunkBytes);
    size_t index = 0;
    auto next = Clock::now();
    const auto period = std::chrono::nanoseconds(
        static_cast<int64_t>(kChunkBytes / 2 * 1e9 / kRate));
    while (!stopped_.load()) {
      for (size_t i = 0; i < kChunkBytes; ++i) {
        chunk[i] = table_[index];
        index = (index + 1) % table_.size();
      }
      push(ctx, chunk.data(), chunk.size());
      next += period;
      std::this_thread::sleep_until(next);
    }
    return SDR_OK;
  }
  void stop() override { stopped_ = true; }
  void close() override {}
  bool supports_live_tuning() const override { return true; }
  int set_frequency(uint64_t f) override {
    std::this_thread::sleep_for(kTuneDelay);
    frequency = f;
    return SDR_OK;
  }
  int set_gain(int32_t) override { return SDR_OK; }
  // Same in-flight window as RtlSdrAdapter (16 x 8 KiB transfers).
  size_t retune_settle_bytes() const override { return 16 * kChunkBytes; }
  std::atomic<uint64_t> frequency{0};

 private:
  std::vector<uint8_t> table_;
  std::atomic<bool> stopped_{false};
};

struct Callback {
  Clock::time_point t;
  size_t level_before;
  size_t from_ring;
};
// What the modelled device played; outlives the sink (join() destroys it).
struct Recording {
  std::vector<Callback> callbacks;
  std::vector<float> output;  // left channel as played, zero fill included
};

// AAudio model: production PcmRing + a 4 ms callback thread. Records every
// callback (time, ring level before the pop, frames taken from the ring) and
// the exact samples handed to the "device".
class CallbackSink : public sdrcore::AudioSink {
 public:
  explicit CallbackSink(std::shared_ptr<Recording> rec) : rec_(std::move(rec)) {}
  ~CallbackSink() override { close(); }
  const char* name() const override { return "callback-model"; }
  int open(uint32_t) override {
    ring_ = std::make_unique<sdrcore::PcmRing>(sdrcore::kPlaybackRingFrames,
                                               sdrcore::kPlaybackPrefillFrames);
    quit_ = false;
    thread_ = std::thread([this] { run(); });
    return 0;
  }
  size_t write(const float* stereo, size_t frames) override {
    if (!ring_) return 0;
    const size_t accepted = ring_->push(stereo, frames);
    std::lock_guard<std::mutex> lock(mutex_);
    stats_.frames_written += accepted;
    stats_.frames_dropped += frames - accepted;
    return accepted;
  }
  void close() override {
    quit_ = true;
    if (thread_.joinable()) thread_.join();
  }
  sdrcore::AudioSinkStats stats() const override {
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
  }
 private:
  void run() {
    std::vector<float> block(2 * kCallbackFrames);
    auto next = Clock::now();
    const auto period = std::chrono::microseconds(kCallbackFrames * 1000000 / 48000);
    while (!quit_.load()) {
      next += period;
      std::this_thread::sleep_until(next);
      const size_t level = ring_->queued();
      const size_t got = ring_->pop(block.data(), kCallbackFrames);
      rec_->callbacks.push_back({Clock::now(), level, got});
      for (size_t i = 0; i < kCallbackFrames; ++i) rec_->output.push_back(block[2 * i]);
    }
  }
  std::shared_ptr<Recording> rec_;
  std::unique_ptr<sdrcore::PcmRing> ring_;
  std::thread thread_;
  std::atomic<bool> quit_{true};
  mutable std::mutex mutex_;
  sdrcore::AudioSinkStats stats_;
};

SdrV3Controls make_controls(uint32_t mode, uint64_t center, int64_t offset) {
  SdrV3Controls c{};
  c.size = sizeof(c);
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = center;
  c.vfo_offset_hz = offset;
  c.sample_rate = kRate;
  c.mode = mode;
  c.bandwidth_hz = mode == SDR_V3_WFM ? 200000 : 12500;
  c.gain_tenths_db = 280;
  c.squelch = SDR_V3_SQUELCH_OFF;
  c.squelch_level_db = -50;
  c.volume = 1;
  c.muted = 0;
  return c;
}

SdrV3Snapshot snap(SdrHandle* h) {
  SdrV3Snapshot s{};
  s.size = sizeof(s);
  s.revision = SDR_V3_REVISION;
  assert(sdr_v3_snapshot(h, &s) == SDR_OK);
  return s;
}

struct SwitchRecord {
  Clock::time_point request;
  double call_us = 0;
  double applied_ms = -1;
  uint64_t center = 0;
};

struct RunResult {
  double steady_level_ms = 0;
  double worst_cushion_used_ms = 0;
  uint64_t zero_frames_after_prime = 0;
  size_t rms_holes = 0;
  size_t rms_windows = 0;
  double vfo_call_p50_us = 0;
  double vfo_call_max_us = 0;
};

double percentile(std::vector<double> v, double p) {
  if (v.empty()) return 0;
  std::sort(v.begin(), v.end());
  return v[std::min(v.size() - 1, static_cast<size_t>(p * (v.size() - 1) + 0.5))];
}

// Optional raw dump for STATUS-retune-gap.md (SDR_RETUNE_GAP_DUMP=<prefix>):
// <prefix>.f32 = played left channel (48 kHz float), <prefix>.jsonl = switches.
void dump(const char* label, const Recording& sink, const std::vector<SwitchRecord>& switches,
          Clock::time_point origin) {
  const char* prefix = std::getenv("SDR_RETUNE_GAP_DUMP");
  if (!prefix) return;
  const std::string base = std::string(prefix) + "-" + label;
  if (FILE* f = std::fopen((base + ".f32").c_str(), "wb")) {
    std::fwrite(sink.output.data(), sizeof(float), sink.output.size(), f);
    std::fclose(f);
  }
  if (FILE* f = std::fopen((base + ".jsonl").c_str(), "w")) {
    const double first_cb = sink.callbacks.empty() ? 0 :
        ms_between(origin, sink.callbacks.front().t);
    std::fprintf(f, "{\"event\":\"origin\",\"first_callback_ms\":%.3f,\"callback_frames\":%zu}\n",
                 first_cb, kCallbackFrames);
    for (const auto& s : switches)
      std::fprintf(f, "{\"event\":\"switch\",\"t_ms\":%.3f,\"center\":%llu,\"call_us\":%.1f,"
                   "\"applied_ms\":%.1f}\n", ms_between(origin, s.request),
                   static_cast<unsigned long long>(s.center), s.call_us, s.applied_ms);
    for (const auto& c : sink.callbacks)
      std::fprintf(f, "{\"event\":\"cb\",\"t_ms\":%.3f,\"level\":%zu,\"from_ring\":%zu}\n",
                   ms_between(origin, c.t), c.level_before, c.from_ring);
    std::fclose(f);
  }
}

RunResult run_switches(const char* label, uint32_t mode, bool stereo) {
  auto* h = new SdrHandle;
  auto adapter = std::make_unique<PacedFakeRtl>(fm_table(mode == SDR_V3_WFM ? 50000 : 2500));
  PacedFakeRtl* fake = adapter.get();
  h->usb_adapter = std::move(adapter);
  h->stats.state = SDR_OPEN;
  h->stats.source = SDR_RTLSDR;
  h->reset_v3_open();
  const uint64_t start_freq = mode == SDR_V3_WFM ? 101800000 : 145500000;
  SdrV3Controls c = make_controls(mode, start_freq, 0);
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  if (mode == SDR_V3_WFM) assert(sdr_v3_set_wfm_stereo(h, stereo ? 1 : 0) == SDR_OK);
  assert(sdr_v3_start(h) == SDR_OK);
  auto recording = std::make_shared<Recording>();
  {
    // The consumer touches audio_sink only under dsp_mutex.
    std::lock_guard<std::mutex> dsp_lock(h->dsp_mutex);
    auto model = std::make_unique<CallbackSink>(recording);
    model->open(48000);
    h->audio_sink->close();
    h->audio_sink = std::move(model);
  }
  const Recording* sink = recording.get();
  const auto origin = Clock::now();
  std::this_thread::sleep_for(std::chrono::milliseconds(1200));  // prime + settle

  // Discrete switches: beyond the 2.4 MHz span (band/preset jumps) and
  // in-span step nudges, alternating, every 350 ms.
  const int64_t wfm_jumps[] = {+3400000, +200000, -5100000, +100000, +2600000, -200000,
                               +7300000, -100000, -4400000, +300000, +1700000, -300000,
                               -6000000, +200000, +4000000, -100000, +2200000, -2400000};
  const int64_t nfm_jumps[] = {+1250000, +12500, -2500000, +25000, +3000000, -12500,
                               -1800000, +12500, +2600000, -25000, -1300000, +12500};
  const int64_t* jumps = mode == SDR_V3_WFM ? wfm_jumps : nfm_jumps;
  const size_t count = mode == SDR_V3_WFM ? std::size(wfm_jumps) : std::size(nfm_jumps);
  std::vector<SwitchRecord> switches;
  uint64_t center = start_freq;
  for (size_t i = 0; i < count; ++i) {
    center = static_cast<uint64_t>(static_cast<int64_t>(center) + jumps[i]);
    c = make_controls(mode, center, 0);
    SwitchRecord rec;
    rec.center = center;
    rec.request = Clock::now();
    assert(sdr_v3_set_controls(h, &c) == SDR_OK);
    rec.call_us = ms_between(rec.request, Clock::now()) * 1000;
    while (ms_between(rec.request, Clock::now()) < 340) {
      if (rec.applied_ms < 0 && snap(h).center_frequency_hz == center)
        rec.applied_ms = ms_between(rec.request, Clock::now());
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    switches.push_back(rec);
  }

  // In-band VFO moves (waterfall drag, 8 ms cadence): only the NCO moves, the
  // caller is the Flutter UI thread.
  std::vector<double> vfo_us;
  for (int k = 0; k < 60; ++k) {
    c = make_controls(mode, center, (k % 4 == 1) ? 1000 : (k % 4 == 3) ? -1000 : 0);
    const auto t0 = Clock::now();
    assert(sdr_v3_set_controls(h, &c) == SDR_OK);
    vfo_us.push_back(ms_between(t0, Clock::now()) * 1000);
    std::this_thread::sleep_for(std::chrono::milliseconds(8));
  }
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  assert(sdr_v3_stop(h) == SDR_OK);  // join() closes the sink (callback thread)

  RunResult r;
  r.vfo_call_p50_us = percentile(vfo_us, 0.5);
  r.vfo_call_max_us = *std::max_element(vfo_us.begin(), vfo_us.end());
  const auto& cbs = sink->callbacks;
  // Steady cushion: median ring level over the 400 ms before the first switch.
  std::vector<double> steady;
  for (const auto& cb : cbs) {
    const double t = ms_between(switches.front().request, cb.t);
    if (t > -400 && t < 0) steady.push_back(cb.level_before * 1000.0 / 48000);
  }
  r.steady_level_ms = percentile(steady, 0.5);
  // Zero-filled frames once playback has started (priming excluded).
  bool primed = false;
  size_t first_played = 0;
  for (size_t i = 0; i < cbs.size(); ++i) {
    if (cbs[i].from_ring) {
      if (!primed) first_played = i;
      primed = true;
    }
    if (primed) r.zero_frames_after_prime += kCallbackFrames - cbs[i].from_ring;
  }
  printf("  %s: steady cushion %.1f ms\n", label, r.steady_level_ms);
  printf("   #  jump_hz    call_us  applied_ms  min_cushion_ms  used_ms  zero_frames\n");
  for (size_t i = 0; i < switches.size(); ++i) {
    double min_level = 1e9;
    uint64_t zeros = 0;
    for (const auto& cb : cbs) {
      const double t = ms_between(switches[i].request, cb.t);
      if (t < 0 || t >= 340) continue;
      min_level = std::min(min_level, cb.level_before * 1000.0 / 48000);
      zeros += kCallbackFrames - cb.from_ring;
    }
    const double used = r.steady_level_ms - min_level;
    r.worst_cushion_used_ms = std::max(r.worst_cushion_used_ms, used);
    printf("  %2zu %+9lld %9.0f %10.1f %14.1f %8.1f %11llu\n", i,
           static_cast<long long>(jumps[i]), switches[i].call_us, switches[i].applied_ms,
           min_level, used, static_cast<unsigned long long>(zeros));
  }
  // RMS holes in what the device played: 2 ms windows below 25% of the
  // steady RMS, from 200 ms after playback start to the end of the switches.
  const auto& out = sink->output;
  const size_t win = 96;
  const size_t begin = (first_played + 50) * kCallbackFrames;
  double acc = 0;
  size_t n = 0;
  for (size_t i = begin; i < std::min(out.size(), begin + 48000 / 2); ++i, ++n) acc += out[i] * out[i];
  const double steady_rms = n ? std::sqrt(acc / n) : 0;
  const double end_ms = ms_between(cbs.front().t, switches.back().request) + 340;
  const size_t end = std::min(out.size(), static_cast<size_t>(end_ms * 48));
  for (size_t s = begin; s + win <= end; s += win) {
    double w = 0;
    for (size_t i = s; i < s + win; ++i) w += out[i] * out[i];
    ++r.rms_windows;
    if (std::sqrt(w / win) < 0.25 * steady_rms) ++r.rms_holes;
  }
  printf("  %s: steady RMS %.3f, RMS holes %zu/%zu, zero-filled frames after priming %llu, "
         "worst cushion used %.1f ms; VFO set_controls p50 %.0f us max %.0f us; "
         "IQ dropped %llu\n", label, steady_rms, r.rms_holes, r.rms_windows,
         static_cast<unsigned long long>(r.zero_frames_after_prime), r.worst_cushion_used_ms,
         r.vfo_call_p50_us, r.vfo_call_max_us,
         static_cast<unsigned long long>(snap(h).dropped_samples));
  CHECK(fake->frequency == center, "%s: last switch applied to the tuner", label);
  dump(label, *sink, switches, origin);
  sdr_destroy(h);
  return r;
}

void check(const char* label, const RunResult& r) {
  CHECK(r.zero_frames_after_prime == 0, "%s: no zero-filled frames caused by switches (%llu)",
        label, static_cast<unsigned long long>(r.zero_frames_after_prime));
  CHECK(r.rms_holes == 0, "%s: no RMS holes in the played audio (%zu)", label, r.rms_holes);
  // A switch may cost the DSP thread a few blocks, never most of the 60 ms
  // cushion: the phone DSP thread is several times slower than this host.
  CHECK(r.worst_cushion_used_ms <= 15,
        "%s: a switch uses at most 15 ms of the %.0f ms playback cushion (worst %.1f ms)",
        label, r.steady_level_ms, r.worst_cushion_used_ms);
  CHECK(r.vfo_call_p50_us <= 3000,
        "%s: in-band VFO set_controls on the UI thread p50 %.0f us <= 3000 us", label,
        r.vfo_call_p50_us);
}

}  // namespace

int main() {
  check("WFM stereo", run_switches("wfm-stereo", SDR_V3_WFM, true));
  check("WFM mono", run_switches("wfm-mono", SDR_V3_WFM, false));
  check("NFM", run_switches("nfm", SDR_V3_NFM, false));
  if (failures) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::printf("retune switch gap: all passed\n");
  return 0;
}

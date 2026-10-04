// SPDX-License-Identifier: GPL-3.0-or-later
//
// Regression test for the retune freeze (kanban t_c364ac15).
//
// Iteration 1: every LO retune (frequency digit/step/preset or drag end) ran
// sdr_v3_set_controls synchronously on the Flutter UI thread, and that call
// did a full stream restart: cancel USB async transfers, join producer and
// consumer, close AAudio, reconfigure sample rate + frequency + gain, reopen
// and restart AAudio. Logcat on SM-F936B showed ~420 ms (p50) of main-thread
// blocking and ~50 skipped Choreographer frames per retune
// (docs/retune-jank/phone-before-logcat.txt).
//
// Iteration 2: with live tuning, the tuner I2C writes alone still cost
// ~29 ms (p50, n=214) on the UI thread per retune
// (docs/retune-jank/phone-after-logcat.txt), 3-5 dropped frames at
// 120 Hz on every drag/step retune. The old Dart engine ran setCenterFreq on
// its DSP isolate, never on the UI isolate. A live retune is now accepted
// synchronously and applied by a native control worker (latest wins), so the
// caller never waits for tuner control transfers.
//
// White-box: includes sdrcore.cpp and injects a fake UsbRxAdapter whose
// stop() and set_frequency() are deliberately slow. The fake producer emits
// IQ whose content depends on the frequency the fake tuner currently has, so
// stale-row checks observe real data flow, not just bookkeeping.
#include "../src/sdrcore.cpp"

#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
constexpr auto kSlowStop = std::chrono::milliseconds(120);
// Stand-in for the ~29 ms rtlsdr_set_center_freq measured on the phone.
constexpr auto kSlowTune = std::chrono::milliseconds(40);
// Frequencies at which the fake tuner "receives" a strong fs/4 tone; any
// other frequency yields a near-silent DC-only stream.
constexpr uint64_t kToneFreq = 106100000;

class FakeAdapter : public UsbRxAdapter {
 public:
  explicit FakeAdapter(bool live) : live_(live) {}
  int open(int) override { return SDR_OK; }
  int configure(uint64_t f, uint32_t rate, int32_t gain) override {
    ++configures;
    last_freq = f;
    tuned_freq = f;
    last_rate = rate;
    last_gain = gain;
    return SDR_OK;
  }
  int start(PushFn push, void* ctx) override {
    {
      std::lock_guard<std::mutex> l(m_);
      ++starts;
      stopped_ = false;
    }
    std::vector<uint8_t> quiet(8192, 127), tone(8192);
    // fs/4 complex tone: I,Q = (1,0),(0,1),(-1,0),(0,-1) scaled to CU8.
    static const uint8_t kPattern[8] = {255, 128, 128, 255, 0, 128, 128, 0};
    for (size_t i = 0; i < tone.size(); ++i) tone[i] = kPattern[i % 8];
    std::unique_lock<std::mutex> l(m_);
    while (!stopped_) {
      l.unlock();
      const bool loud = tuned_freq.load() == kToneFreq;
      push(ctx, loud ? tone.data() : quiet.data(), 8192);
      l.lock();
      cv_.wait_for(l, std::chrono::milliseconds(2), [this] { return stopped_; });
    }
    return SDR_OK;
  }
  void stop() override {
    if (tuning.load()) stop_during_tune = true;
    std::this_thread::sleep_for(kSlowStop);
    std::lock_guard<std::mutex> l(m_);
    ++stops;
    stopped_ = true;
    cv_.notify_all();
  }
  void close() override {
    if (tuning.load()) close_during_tune = true;
  }
  bool supports_live_tuning() const override { return live_; }
  int set_frequency(uint64_t f) override {
    assert(live_);
    tuning = true;
    ++live_freqs;
    std::this_thread::sleep_for(tune_delay);
    last_freq = f;
    // The fake RF front end switches at the end of the I2C sequence.
    if (!fail_live) tuned_freq = f;
    tuning = false;
    return fail_live ? SDR_IO_ERROR : SDR_OK;
  }
  int set_gain(int32_t gain) override {
    assert(live_);
    tuning = true;
    ++live_gains;
    std::this_thread::sleep_for(tune_delay);
    last_gain = gain;
    tuning = false;
    return SDR_OK;
  }
  size_t retune_settle_bytes() const override { return 2 * 8192; }

  std::atomic<int> configures{0}, starts{0}, stops{0}, live_freqs{0}, live_gains{0};
  std::atomic<uint64_t> last_freq{0}, tuned_freq{0};
  std::atomic<uint32_t> last_rate{0};
  std::atomic<int32_t> last_gain{0};
  std::atomic<bool> fail_live{false}, tuning{false};
  std::atomic<bool> stop_during_tune{false}, close_during_tune{false};
  std::chrono::milliseconds tune_delay{0};

 private:
  const bool live_;
  std::mutex m_;
  std::condition_variable cv_;
  bool stopped_ = false;
};

SdrV3Controls controls(uint64_t f, uint32_t rate = 2400000, int32_t gain = 496) {
  SdrV3Controls c{};
  c.size = sizeof(c);
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = f;
  c.sample_rate = rate;
  c.mode = SDR_V3_WFM;
  c.bandwidth_hz = 200000;
  c.gain_tenths_db = gain;
  c.squelch_level_db = -50;
  c.volume = 1;
  c.muted = 1;
  return c;
}

SdrV3Snapshot snap(SdrHandle* h) {
  SdrV3Snapshot s{};
  s.size = sizeof(s);
  s.revision = SDR_V3_REVISION;
  assert(sdr_v3_snapshot(h, &s) == SDR_OK);
  return s;
}

long ms_since(Clock::time_point t) {
  return static_cast<long>(std::chrono::duration_cast<std::chrono::milliseconds>(
      Clock::now() - t).count());
}

double us_since(Clock::time_point t) {
  return std::chrono::duration<double, std::micro>(Clock::now() - t).count();
}

// Polls until pred(snapshot) holds (the control worker applies asynchronously).
template <typename Pred>
SdrV3Snapshot wait_for(SdrHandle* h, Pred pred, int max_ms = 3000) {
  const auto t0 = Clock::now();
  SdrV3Snapshot s = snap(h);
  while (!pred(s) && ms_since(t0) < max_ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    s = snap(h);
  }
  return s;
}

// Builds a RUNNING v3 RTL session on a fake adapter (null audio sink on host).
SdrHandle* running(FakeAdapter*& fake, bool live, uint64_t freq = 106000000) {
  auto* h = new SdrHandle;
  auto adapter = std::make_unique<FakeAdapter>(live);
  fake = adapter.get();
  h->usb_adapter = std::move(adapter);
  h->stats.state = SDR_OPEN;
  h->stats.source = SDR_RTLSDR;
  h->reset_v3_open();
  const SdrV3Controls c = controls(freq);
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  assert(sdr_v3_start(h) == SDR_OK);
  // Let the fake producer enter start().
  for (int i = 0; i < 500 && snap(h).processed_samples == 0; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  assert(fake->starts == 1);
  assert(snap(h).processed_samples > 0);
  return h;
}

void test_frequency_retune_does_not_block_caller() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  fake->tune_delay = kSlowTune;
  const SdrV3Snapshot before = snap(h);
  const SdrV3Controls next = controls(106100000);
  const auto t0 = Clock::now();
  assert(sdr_v3_set_controls(h, &next) == SDR_OK);
  const double call_us = us_since(t0);
  // Accepted synchronously: the epoch advances before the call returns, so
  // the UI can discard every row/squelch decision of the old tune at once.
  const SdrV3Snapshot accepted = snap(h);
  assert(accepted.control_sequence == before.control_sequence + 1);
  const SdrV3Snapshot after = wait_for(h, [](const SdrV3Snapshot& s) {
    return s.center_frequency_hz == 106100000;
  });
  const long applied_ms = ms_since(t0);
  printf("  LO retune: set_controls %.0f us, applied after %ld ms "
         "(tuner %lld ms, stop %lld ms)\n", call_us, applied_ms,
         static_cast<long long>(kSlowTune.count()),
         static_cast<long long>(kSlowStop.count()));
  // Must not wait for the slow tuner I2C (nor, of course, for a restart).
  assert(call_us < 10000);
  assert(after.center_frequency_hz == 106100000);
  assert(fake->stops == 0 && fake->starts == 1);
  assert(fake->live_freqs == 1 && fake->last_freq == 106100000);
  assert(fake->configures == 1);  // only the initial full configure
  assert(after.state == SDR_RUNNING);
  assert(after.stream_generation == before.stream_generation);
  assert(after.control_sequence == before.control_sequence + 1);
  // Stream keeps flowing after the live retune.
  const uint64_t processed = after.processed_samples;
  for (int i = 0; i < 500 && snap(h).processed_samples == processed; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  assert(snap(h).processed_samples > processed);
  assert(sdr_v3_stop(h) == SDR_OK);
  assert(fake->stops == 1);
  assert(snap(h).state == SDR_OPEN);
  sdr_destroy(h);
  printf("[ok] RUNNING LO retune returns before the slow tuner I2C completes\n");
}

void test_repeated_retunes_latest_wins() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  fake->tune_delay = kSlowTune;
  const uint64_t generation = snap(h).stream_generation;
  const uint64_t sequence = snap(h).control_sequence;
  const auto t0 = Clock::now();
  double worst_us = 0;
  for (int i = 1; i <= 20; ++i) {
    const SdrV3Controls next = controls(106000000 + 100000ULL * i);
    const auto c0 = Clock::now();
    assert(sdr_v3_set_controls(h, &next) == SDR_OK);
    worst_us = std::max(worst_us, us_since(c0));
  }
  const long elapsed = ms_since(t0);
  const SdrV3Snapshot s = wait_for(h, [](const SdrV3Snapshot& v) {
    return v.center_frequency_hz == 108000000;
  });
  printf("  20 rapid retunes: %ld ms total, worst call %.0f us, %d tuner writes\n",
         elapsed, worst_us, fake->live_freqs.load());
  assert(elapsed < kSlowTune.count());
  assert(s.center_frequency_hz == 108000000 && fake->last_freq == 108000000);
  assert(s.control_sequence == sequence + 20);
  // Coalesced: at most the in-flight request plus the latest one.
  assert(fake->live_freqs <= 3);
  assert(s.stream_generation == generation && fake->stops == 0);
  sdr_destroy(h);
  printf("[ok] rapid retunes coalesce; last request wins\n");
}

void test_gain_change_is_live() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  const uint64_t generation = snap(h).stream_generation;
  const SdrV3Controls next = controls(106000000, 2400000, 280);
  assert(sdr_v3_set_controls(h, &next) == SDR_OK);
  const SdrV3Snapshot s = wait_for(h, [](const SdrV3Snapshot& v) {
    return v.gain_tenths_db == 280;
  });
  assert(fake->live_gains == 1 && fake->last_gain == 280);
  assert(fake->live_freqs == 0 && fake->stops == 0);
  assert(s.gain_tenths_db == 280 && s.stream_generation == generation);
  sdr_destroy(h);
  printf("[ok] RUNNING gain-only change is applied live\n");
}

void test_vfo_only_change_is_synchronous() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  SdrV3Controls next = controls(106000000);
  next.vfo_offset_hz = 300000;
  assert(sdr_v3_set_controls(h, &next) == SDR_OK);
  const SdrV3Snapshot s = snap(h);
  assert(s.vfo_offset_hz == 300000);
  assert(fake->live_freqs == 0 && fake->live_gains == 0 && fake->stops == 0);
  sdr_destroy(h);
  printf("[ok] in-band VFO change needs no tuner access\n");
}

void test_sample_rate_change_still_restarts() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  const uint64_t generation = snap(h).stream_generation;
  const SdrV3Controls next = controls(106000000, 1024000);
  assert(sdr_v3_set_controls(h, &next) == SDR_OK);
  assert(fake->stops == 1 && fake->configures == 2 && fake->last_rate == 1024000);
  assert(snap(h).stream_generation == generation + 1);
  assert(snap(h).sample_rate == 1024000 && snap(h).state == SDR_RUNNING);
  sdr_destroy(h);
  printf("[ok] sample-rate change keeps the full restart path\n");
}

void test_rate_change_after_pending_retune_keeps_latest() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  fake->tune_delay = kSlowTune;
  const SdrV3Controls tune = controls(106300000);
  assert(sdr_v3_set_controls(h, &tune) == SDR_OK);
  // A rate change while the retune is in flight: restart with the newest
  // controls; the in-flight tune must not overwrite them afterwards.
  const SdrV3Controls rate = controls(106500000, 1024000);
  assert(sdr_v3_set_controls(h, &rate) == SDR_OK);
  std::this_thread::sleep_for(kSlowTune * 2);
  const SdrV3Snapshot s = snap(h);
  assert(s.state == SDR_RUNNING && s.sample_rate == 1024000);
  assert(s.center_frequency_hz == 106500000);
  assert(fake->tuned_freq == 106500000);
  sdr_destroy(h);
  printf("[ok] restart after an in-flight retune keeps the newest tune\n");
}

void test_adapter_without_live_tuning_falls_back_to_restart() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, false);
  const uint64_t generation = snap(h).stream_generation;
  const SdrV3Controls next = controls(107000000);
  assert(sdr_v3_set_controls(h, &next) == SDR_OK);
  assert(fake->stops == 1 && fake->configures == 2 && fake->last_freq == 107000000);
  assert(snap(h).stream_generation == generation + 1);
  assert(snap(h).center_frequency_hz == 107000000);
  sdr_destroy(h);
  printf("[ok] adapter without live tuning uses stop/configure/restart\n");
}

void test_live_failure_reports_async_error() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  fake->fail_live = true;
  const uint64_t errors = snap(h).error_sequence;
  const SdrV3Controls next = controls(107000000);
  assert(sdr_v3_set_controls(h, &next) == SDR_OK);  // accepted; applied async
  const SdrV3Snapshot s = wait_for(h, [](const SdrV3Snapshot& v) {
    return v.state == SDR_ERROR;
  });
  assert(s.state == SDR_ERROR && s.last_error == SDR_IO_ERROR);
  assert(s.error_sequence == errors + 1);
  assert(s.center_frequency_hz == 106000000);  // never advertise the failed tune
  assert(sdr_v3_stop(h) == SDR_OK);
  sdr_destroy(h);
  printf("[ok] live retune failure becomes async SDR_ERROR, old applied tune kept\n");
}

void test_stop_during_retune_cancels_pending() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  fake->tune_delay = std::chrono::milliseconds(80);
  const SdrV3Controls first = controls(106200000);
  const SdrV3Controls second = controls(106400000);
  assert(sdr_v3_set_controls(h, &first) == SDR_OK);
  for (int i = 0; i < 500 && !fake->tuning; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  assert(fake->tuning);
  assert(sdr_v3_set_controls(h, &second) == SDR_OK);  // queued behind `first`
  assert(sdr_v3_stop(h) == SDR_OK);
  // The in-flight I2C sequence finished before the stream was cancelled;
  // the queued request was dropped, not applied after Stop.
  assert(!fake->stop_during_tune);
  assert(fake->live_freqs == 1);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  assert(fake->live_freqs == 1 && fake->last_freq == 106200000);
  const SdrV3Snapshot s = snap(h);
  assert(s.state == SDR_OPEN);
  assert(s.center_frequency_hz == 106200000);  // what the hardware really has
  // Restart re-applies the newest accepted tune through configure().
  assert(sdr_v3_set_controls(h, &second) == SDR_OK);
  assert(fake->configures == 2 && fake->last_freq == 106400000);
  assert(!fake->close_during_tune);
  sdr_destroy(h);
  printf("[ok] Stop during a retune waits for the I2C write and drops the queue\n");
}

void test_destroy_during_retune() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  fake->tune_delay = std::chrono::milliseconds(60);
  const SdrV3Controls next = controls(106200000);
  assert(sdr_v3_set_controls(h, &next) == SDR_OK);
  for (int i = 0; i < 500 && !fake->tuning; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  sdr_destroy(h);  // must not race close() with the in-flight tune
  printf("[ok] destroy during a retune is serialized with the tuner worker\n");
}

// Every FFT row stamped with the new control_sequence must be computed from
// IQ captured after the tuner switched (the fake emits a loud tone only at
// kToneFreq), and rows of the old tune must never carry the new sequence.
void test_no_stale_rows_after_retune() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true, 106000000);
  // Long enough for several FFT rows (30/s) to fall inside the retune window.
  fake->tune_delay = std::chrono::milliseconds(200);
  std::vector<float> bins(SDR_V3_MAX_FFT_WIDTH);
  SdrV3Fft meta{};
  uint64_t last = 0;
  auto read_row = [&](float& peak) {
    meta = SdrV3Fft{};
    meta.size = sizeof(meta);
    meta.revision = SDR_V3_REVISION;
    const int rc = sdr_v3_read_fft(h, last, &meta, bins.data(), SDR_V3_MAX_FFT_WIDTH);
    if (rc != SDR_OK) return false;
    last = meta.sequence;
    peak = -1000;
    for (uint32_t i = 0; i < meta.width; ++i) peak = std::max(peak, bins[i]);
    return true;
  };
  // Baseline quiet rows at the old tune.
  int quiet_rows = 0;
  float peak = 0;
  for (int i = 0; i < 2000 && quiet_rows < 3; ++i) {
    if (read_row(peak)) { assert(peak < -20); ++quiet_rows; }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  assert(quiet_rows == 3);
  const SdrV3Controls next = controls(kToneFreq);
  assert(sdr_v3_set_controls(h, &next) == SDR_OK);
  const uint64_t sequence = snap(h).control_sequence;
  int new_rows = 0;
  const auto t0 = Clock::now();
  long first_row_ms = -1;
  for (int i = 0; i < 4000 && new_rows < 5; ++i) {
    if (read_row(peak) && meta.control_sequence == sequence) {
      if (first_row_ms < 0) first_row_ms = ms_since(t0);
      // A row of the new epoch with quiet content would be a stale row.
      assert(peak > -20);
      assert(meta.low_hz < static_cast<int64_t>(kToneFreq) &&
             meta.high_hz > static_cast<int64_t>(kToneFreq));
      ++new_rows;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  printf("  first new-tune FFT row %ld ms after set_controls\n", first_row_ms);
  assert(new_rows == 5);
  sdr_destroy(h);
  printf("[ok] no FFT row of the old tune carries the new control sequence\n");
}

// The old Dart engine and SDR++ never drop IQ on a retune; audio keeps
// flowing through the channel filters. Discarding the in-flight transfers
// (and flushing the ring) left an audible gap per retune. Every accepted IQ
// sample must still reach the demodulator (only display/squelch ignore the
// settle window).
void test_retune_keeps_audio_iq_flowing() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  fake->tune_delay = std::chrono::milliseconds(5);
  for (int i = 1; i <= 5; ++i) {
    const SdrV3Controls next = controls(106000000 + 100000ULL * i);
    assert(sdr_v3_set_controls(h, &next) == SDR_OK);
    wait_for(h, [&](const SdrV3Snapshot& s) {
      return s.center_frequency_hz == next.center_frequency_hz;
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  // stop() joins the producer, then the consumer drains every queued slot.
  assert(sdr_v3_stop(h) == SDR_OK);
  const SdrV3Snapshot s = snap(h);
  const uint64_t missing = s.input_samples - s.dropped_samples - s.processed_samples;
  printf("  IQ pairs not demodulated after 5 retunes: %llu\n",
         static_cast<unsigned long long>(missing));
  assert(missing == 0);
  assert(s.audio_frames > 0);
  sdr_destroy(h);
  printf("[ok] live retunes feed every IQ sample to the demodulator (no audio gap)\n");
}

}  // namespace

int main() {
  test_frequency_retune_does_not_block_caller();
  test_repeated_retunes_latest_wins();
  test_gain_change_is_live();
  test_vfo_only_change_is_synchronous();
  test_sample_rate_change_still_restarts();
  test_rate_change_after_pending_retune_keeps_latest();
  test_adapter_without_live_tuning_falls_back_to_restart();
  test_live_failure_reports_async_error();
  test_stop_during_retune_cancels_pending();
  test_destroy_during_retune();
  test_no_stale_rows_after_retune();
  test_retune_keeps_audio_iq_flowing();
  printf("live_retune_test: all passed\n");
  return 0;
}

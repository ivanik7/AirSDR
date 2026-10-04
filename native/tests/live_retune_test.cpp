// SPDX-License-Identifier: GPL-3.0-or-later
//
// Regression test for the retune freeze (kanban t_c364ac15).
//
// On the phone every LO retune (frequency digit/step/preset or drag end) ran
// sdr_v3_set_controls synchronously on the Flutter UI thread, and that call
// did a full stream restart: cancel USB async transfers, join producer and
// consumer, close AAudio, reconfigure sample rate + frequency + gain, reopen
// and restart AAudio. Logcat on SM-F936B showed ~420 ms (p50) of main-thread
// blocking and ~50 skipped Choreographer frames per retune
// (docs/retune-jank/).
//
// White-box: includes sdrcore.cpp and injects a fake UsbRxAdapter whose
// stop() is deliberately slow (stand-in for USB cancel + AAudio teardown).
// A frequency- or gain-only change on a RUNNING session must be applied live
// through the adapter, without stopping the stream, restarting audio or
// advancing stream_generation. Sample-rate changes and adapters without live
// tuning still take the full restart path.
#include "../src/sdrcore.cpp"

#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
constexpr auto kSlowStop = std::chrono::milliseconds(120);

// Streams zero IQ until stop(); stop() costs kSlowStop like the real
// rtlsdr_cancel_async + AAudio close/reopen on the phone.
class FakeAdapter : public UsbRxAdapter {
 public:
  explicit FakeAdapter(bool live) : live_(live) {}
  int open(int) override { return SDR_OK; }
  int configure(uint64_t f, uint32_t rate, int32_t gain) override {
    std::lock_guard<std::mutex> l(m_);
    ++configures;
    last_freq = f;
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
    std::vector<uint8_t> zeros(8192, 127);
    std::unique_lock<std::mutex> l(m_);
    while (!stopped_) {
      l.unlock();
      push(ctx, zeros.data(), zeros.size());
      l.lock();
      cv_.wait_for(l, std::chrono::milliseconds(3), [this] { return stopped_; });
    }
    return SDR_OK;
  }
  void stop() override {
    std::this_thread::sleep_for(kSlowStop);
    std::lock_guard<std::mutex> l(m_);
    ++stops;
    stopped_ = true;
    cv_.notify_all();
  }
  void close() override {}
  // Live tuning hooks (UsbRxAdapter::supports_live_tuning / set_*).
  bool supports_live_tuning() const override { return live_; }
  int set_frequency(uint64_t f) override {
    assert(live_);
    std::lock_guard<std::mutex> l(m_);
    ++live_freqs;
    last_freq = f;
    return fail_live ? SDR_IO_ERROR : SDR_OK;
  }
  int set_gain(int32_t gain) override {
    assert(live_);
    std::lock_guard<std::mutex> l(m_);
    ++live_gains;
    last_gain = gain;
    return SDR_OK;
  }
  size_t retune_settle_bytes() const override { return 2 * 8192; }

  int configures = 0, starts = 0, stops = 0, live_freqs = 0, live_gains = 0;
  uint64_t last_freq = 0;
  uint32_t last_rate = 0;
  int32_t last_gain = 0;
  bool fail_live = false;

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

// Builds a RUNNING v3 RTL session on a fake adapter (null audio sink on host).
SdrHandle* running(FakeAdapter*& fake, bool live) {
  auto* h = new SdrHandle;
  auto adapter = std::make_unique<FakeAdapter>(live);
  fake = adapter.get();
  h->usb_adapter = std::move(adapter);
  h->stats.state = SDR_OPEN;
  h->stats.source = SDR_RTLSDR;
  h->reset_v3_open();
  const SdrV3Controls c = controls(106000000);
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  assert(sdr_v3_start(h) == SDR_OK);
  // Let the fake producer enter start().
  for (int i = 0; i < 200 && snap(h).processed_samples == 0; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  assert(fake->starts == 1);
  assert(snap(h).processed_samples > 0);
  return h;
}

long ms_since(Clock::time_point t) {
  return static_cast<long>(std::chrono::duration_cast<std::chrono::milliseconds>(
      Clock::now() - t).count());
}

void test_frequency_retune_is_live_and_fast() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  const SdrV3Snapshot before = snap(h);
  const SdrV3Controls next = controls(106100000);
  const auto t0 = Clock::now();
  assert(sdr_v3_set_controls(h, &next) == SDR_OK);
  const long elapsed = ms_since(t0);
  const SdrV3Snapshot after = snap(h);
  printf("  LO retune set_controls: %ld ms (slow stop = %lld ms)\n", elapsed,
         static_cast<long long>(kSlowStop.count()));
  assert(elapsed < kSlowStop.count() / 2);
  assert(fake->stops == 0 && fake->starts == 1);
  assert(fake->live_freqs == 1 && fake->last_freq == 106100000);
  assert(fake->configures == 1);  // only the initial full configure
  assert(after.state == SDR_RUNNING);
  assert(after.stream_generation == before.stream_generation);
  assert(after.control_sequence == before.control_sequence + 1);
  assert(after.center_frequency_hz == 106100000);
  // Stream keeps flowing after the live retune.
  const uint64_t processed = after.processed_samples;
  for (int i = 0; i < 200 && snap(h).processed_samples == processed; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  assert(snap(h).processed_samples > processed);
  // Stop after a retune still tears the stream down exactly once.
  assert(sdr_v3_stop(h) == SDR_OK);
  assert(fake->stops == 1);
  assert(snap(h).state == SDR_OPEN);
  sdr_destroy(h);
  printf("[ok] RUNNING LO-only retune is applied live without stream restart\n");
}

void test_repeated_retunes_latest_wins() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  const uint64_t generation = snap(h).stream_generation;
  const auto t0 = Clock::now();
  for (int i = 1; i <= 20; ++i) {
    const SdrV3Controls next = controls(106000000 + 100000ULL * i);
    assert(sdr_v3_set_controls(h, &next) == SDR_OK);
  }
  const long elapsed = ms_since(t0);
  printf("  20 rapid retunes: %ld ms total\n", elapsed);
  assert(elapsed < kSlowStop.count());
  const SdrV3Snapshot s = snap(h);
  assert(s.center_frequency_hz == 108000000 && fake->last_freq == 108000000);
  assert(s.stream_generation == generation && fake->stops == 0);
  sdr_destroy(h);
  printf("[ok] rapid retunes stay live; last request wins\n");
}

void test_gain_change_is_live() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  const uint64_t generation = snap(h).stream_generation;
  const SdrV3Controls next = controls(106000000, 2400000, 280);
  assert(sdr_v3_set_controls(h, &next) == SDR_OK);
  assert(fake->live_gains == 1 && fake->last_gain == 280);
  assert(fake->live_freqs == 0 && fake->stops == 0);
  assert(snap(h).gain_tenths_db == 280 && snap(h).stream_generation == generation);
  sdr_destroy(h);
  printf("[ok] RUNNING gain-only change is applied live\n");
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

void test_live_failure_reports_error_state() {
  FakeAdapter* fake = nullptr;
  SdrHandle* h = running(fake, true);
  fake->fail_live = true;
  const SdrV3Controls next = controls(107000000);
  assert(sdr_v3_set_controls(h, &next) == SDR_IO_ERROR);
  const SdrV3Snapshot s = snap(h);
  assert(s.state == SDR_ERROR && s.last_error == SDR_IO_ERROR);
  assert(s.center_frequency_hz == 106000000);  // never advertise the failed tune
  assert(sdr_v3_stop(h) == SDR_OK);
  sdr_destroy(h);
  printf("[ok] live retune failure leaves SDR_ERROR and the old applied tune\n");
}

}  // namespace

int main() {
  test_frequency_retune_is_live_and_fast();
  test_repeated_retunes_latest_wins();
  test_gain_change_is_live();
  test_sample_rate_change_still_restarts();
  test_adapter_without_live_tuning_falls_back_to_restart();
  test_live_failure_reports_error_state();
  printf("live_retune_test: all passed\n");
  return 0;
}

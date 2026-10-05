// SPDX-License-Identifier: GPL-3.0-or-later
//
// Regression test for audio dropouts while scrolling (kanban t_c364ac15,
// iteration 3). DSP-only, white-box through sdrcore::dsp::Receiver.
//
// A waterfall drag sends a new VFO offset on every pointer move (60-120 Hz
// on the phone) and, every 250 ms, an LO recenter that the core applies with
// configure() (new offset) + retune() (new station). On 9a29cb9 each offset
// change ran reset_channel(): both decimator histories, the audio resampler,
// deemphasis and the squelch gate (gate_ = 0, even with squelch off) were
// zeroed, so every move punched a few-ms hole into the audio. The Blog V4
// host capture (tool/retune_jank/event_envelope.py) showed the audio RMS
// at 0.32x right after each move. SDR++ and the old Dart engine only change
// the VFO translator's NCO on an offset move (rx_vfo.setOffset), so the
// audio stays continuous.
#include "../src/dsp/receiver.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr uint32_t kRate = 2400000;
constexpr size_t kBlockPairs = 4096;  // One 8 KiB ring slot.
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

struct Carrier {
  double offset_hz;
  double tone_hz;
  double deviation_hz;
  double amplitude;
};

// Continuous CU8 IQ generator for FM carriers with sine modulation.
class Generator {
 public:
  explicit Generator(std::vector<Carrier> carriers)
      : carriers_(std::move(carriers)), phase_(carriers_.size(), 0.0) {}
  std::vector<uint8_t> next(size_t pairs) {
    std::vector<uint8_t> out(2 * pairs);
    for (size_t n = 0; n < pairs; ++n, ++t_) {
      const double t = static_cast<double>(t_) / kRate;
      double i = 0, q = 0;
      for (size_t k = 0; k < carriers_.size(); ++k) {
        const Carrier& c = carriers_[k];
        const double f = c.offset_hz + c.deviation_hz * std::sin(2 * kPi * c.tone_hz * t);
        phase_[k] = std::fmod(phase_[k] + 2 * kPi * f / kRate, 2 * kPi);
        i += c.amplitude * std::cos(phase_[k]);
        q += c.amplitude * std::sin(phase_[k]);
      }
      auto quant = [](double v) {
        return static_cast<uint8_t>(std::clamp(std::lround(127.5 + 127.5 * v), 0L, 255L));
      };
      out[2 * n] = quant(i);
      out[2 * n + 1] = quant(q);
    }
    return out;
  }

 private:
  std::vector<Carrier> carriers_;
  std::vector<double> phase_;
  uint64_t t_ = 0;
};

SdrV3Controls controls(uint32_t mode, uint32_t bandwidth, int64_t offset) {
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = 100000000;
  c.vfo_offset_hz = offset;
  c.sample_rate = kRate;
  c.mode = mode;
  c.bandwidth_hz = bandwidth;
  c.gain_tenths_db = 280;
  c.squelch = SDR_V3_SQUELCH_OFF;
  c.squelch_level_db = -50;
  c.volume = 1.0f;
  return c;
}

SdrV3Display display() {
  SdrV3Display d{};
  d.size = sizeof d;
  d.revision = SDR_V3_REVISION;
  d.view_bandwidth_hz = kRate;
  d.width = 512;
  return d;
}

// Left-channel RMS per 2 ms window (96 frames at 48 kHz).
std::vector<double> window_rms(const std::vector<float>& stereo) {
  std::vector<double> out;
  const size_t win = 96;
  for (size_t s = 0; s + win <= stereo.size() / 2; s += win) {
    double acc = 0;
    for (size_t i = s; i < s + win; ++i) acc += stereo[2 * i] * stereo[2 * i];
    out.push_back(std::sqrt(acc / win));
  }
  return out;
}

double rms(const std::vector<float>& stereo) {
  double acc = 0;
  for (size_t i = 0; i < stereo.size(); i += 2) acc += stereo[i] * stereo[i];
  return stereo.empty() ? 0 : std::sqrt(acc / (stereo.size() / 2));
}

// Goertzel power of `hz` in the left channel.
double tone_power(const std::vector<float>& stereo, double hz) {
  const double w = 2 * kPi * hz / 48000;
  double s1 = 0, s2 = 0;
  for (size_t i = 0; i < stereo.size(); i += 2) {
    const double s = stereo[i] + 2 * std::cos(w) * s1 - s2;
    s2 = s1;
    s1 = s;
  }
  return s1 * s1 + s2 * s2 - 2 * std::cos(w) * s1 * s2;
}

struct Run {
  std::vector<float> steady;  // audio before the first control change
  std::vector<float> moving;  // audio while control changes happen
};

// Streams `seconds_steady` of IQ, then `seconds_moving` during which
// `change(receiver, k)` runs before every `every_blocks`-th block.
template <typename Change>
Run stream(sdrcore::dsp::Receiver& rx, Generator& gen, double seconds_steady,
           double seconds_moving, size_t every_blocks, Change change) {
  Run run;
  sdrcore::dsp::ProcessResult result;
  const size_t steady_blocks = static_cast<size_t>(seconds_steady * kRate / kBlockPairs);
  const size_t moving_blocks = static_cast<size_t>(seconds_moving * kRate / kBlockPairs);
  for (size_t b = 0; b < steady_blocks; ++b) {
    const auto iq = gen.next(kBlockPairs);
    rx.process(iq.data(), iq.size(), result);
    // Skip the start-up transient (filters, deemphasis, pilot blend).
    if (b * kBlockPairs > kRate / 4)
      run.steady.insert(run.steady.end(), result.audio.begin(), result.audio.end());
  }
  for (size_t b = 0, k = 0; b < moving_blocks; ++b) {
    if (b % every_blocks == 0) change(rx, k++);
    const auto iq = gen.next(kBlockPairs);
    rx.process(iq.data(), iq.size(), result);
    run.moving.insert(run.moving.end(), result.audio.begin(), result.audio.end());
  }
  return run;
}

void check_continuous(const char* label, const Run& run, double floor_ratio) {
  const double steady = rms(run.steady);
  const auto windows = window_rms(run.moving);
  size_t holes = 0;
  double worst = 1e9;
  for (double w : windows) {
    worst = std::min(worst, w);
    if (w < floor_ratio * steady) ++holes;
  }
  CHECK(steady > 0.05, "%s: steady audio RMS %.3f", label, steady);
  CHECK(holes == 0,
        "%s: %zu of %zu 2 ms windows below %.0f%% of steady RMS %.3f (worst %.3f)",
        label, holes, windows.size(), floor_ratio * 100, steady, worst);
}

// Drag: the VFO follows the finger in 1 kHz steps every 2 blocks (~3.4 ms,
// faster than a 120 Hz touch stream) while the station stays in the channel.
void test_wfm_vfo_drag_keeps_audio() {
  for (const bool stereo : {false, true}) {
    auto rx = sdrcore::dsp::make_receiver();
    rx->configure(controls(SDR_V3_WFM, 200000, 100000), display());
    rx->set_wfm_stereo(stereo);
    Generator gen({{100000, 1000, 30000, 0.45}});
    const Run run = stream(*rx, gen, 0.6, 0.5, 2, [](sdrcore::dsp::Receiver& r, size_t k) {
      const int64_t walk[4] = {0, 1000, 2000, 1000};
      r.configure(controls(SDR_V3_WFM, 200000, 100000 + walk[k % 4]), display());
    });
    check_continuous(stereo ? "WFM stereo VFO drag" : "WFM mono VFO drag", run, 0.5);
  }
}

// LO recenter: the core calls retune() on the first block of a new LO. The
// station stays where it was, so audio must not dip.
void test_wfm_lo_retune_keeps_audio() {
  for (const bool stereo : {false, true}) {
    auto rx = sdrcore::dsp::make_receiver();
    rx->configure(controls(SDR_V3_WFM, 200000, 0), display());
    rx->set_wfm_stereo(stereo);
    Generator gen({{0, 1000, 30000, 0.45}});
    // A retune every 250 ms like the drag timer.
    const size_t every = static_cast<size_t>(0.25 * kRate / kBlockPairs);
    const Run run = stream(*rx, gen, 0.6, 1.0, every,
                           [](sdrcore::dsp::Receiver& r, size_t) { r.retune(); });
    check_continuous(stereo ? "WFM stereo LO retune" : "WFM mono LO retune", run, 0.5);
  }
}

// Manual squelch open on a strong NFM signal: VFO moves within the channel
// must not close the gate while the squelch metric re-settles.
void test_nfm_squelch_holds_during_drag() {
  auto rx = sdrcore::dsp::make_receiver();
  SdrV3Controls c = controls(SDR_V3_NFM, 12500, 50000);
  c.squelch = SDR_V3_SQUELCH_MANUAL;
  c.squelch_level_db = -25;  // carrier ~-7 dB, empty channel ~-40 dB
  rx->configure(c, display());
  Generator gen({{50000, 1000, 2500, 0.45}});
  const Run run = stream(*rx, gen, 0.6, 0.5, 2, [c](sdrcore::dsp::Receiver& r, size_t k) mutable {
    c.vfo_offset_hz = 50000 + ((k % 2) ? 200 : 0);
    r.configure(c, display());
  });
  check_continuous("NFM manual squelch VFO drag", run, 0.5);
}

// A move to another channel (ChannelScanner hop, more than half the
// bandwidth) still relearns the squelch: readiness drops at once and the
// empty channel ends up closed. A move within the channel keeps both.
void test_squelch_relearns_only_on_channel_change() {
  auto rx = sdrcore::dsp::make_receiver();
  SdrV3Controls c = controls(SDR_V3_NFM, 12500, 50000);
  c.squelch = SDR_V3_SQUELCH_MANUAL;
  c.squelch_level_db = -25;  // carrier ~-7 dB, empty channel ~-40 dB
  rx->configure(c, display());
  Generator gen({{50000, 1000, 2500, 0.45}});
  sdrcore::dsp::ProcessResult result;
  for (int b = 0; b < 200; ++b) {
    const auto iq = gen.next(kBlockPairs);
    rx->process(iq.data(), iq.size(), result);
  }
  CHECK(result.squelch_ready && result.squelch_open, "NFM squelch ready+open before move");
  c.vfo_offset_hz = 50200;
  rx->configure(c, display());
  auto iq = gen.next(256);
  rx->process(iq.data(), iq.size(), result);
  CHECK(result.squelch_ready && result.squelch_open, "in-channel move keeps squelch ready+open");
  c.vfo_offset_hz = 80000;  // empty channel, 30 kHz away
  rx->configure(c, display());
  iq = gen.next(256);
  rx->process(iq.data(), iq.size(), result);
  CHECK(!result.squelch_ready, "squelch_ready cleared right after a channel change");
  for (int b = 0; b < 50; ++b) {
    iq = gen.next(kBlockPairs);
    rx->process(iq.data(), iq.size(), result);
  }
  CHECK(result.squelch_ready && !result.squelch_open,
        "empty channel: squelch ready and closed (%.1f dB vs %.1f dB)", result.signal_db,
        result.squelch_threshold_db);
  c.vfo_offset_hz = 50000;
  rx->configure(c, display());
  for (int b = 0; b < 50; ++b) {
    iq = gen.next(kBlockPairs);
    rx->process(iq.data(), iq.size(), result);
  }
  CHECK(result.squelch_ready && result.squelch_open, "back on the carrier: ready and open");
}

// An LO change to another station defers the relearn to retune(), the first
// block captured under the new LO.
void test_lo_station_change_relearns_at_retune() {
  auto rx = sdrcore::dsp::make_receiver();
  SdrV3Controls c = controls(SDR_V3_NFM, 12500, 0);
  c.squelch = SDR_V3_SQUELCH_MANUAL;
  c.squelch_level_db = -25;  // carrier ~-7 dB, empty channel ~-40 dB
  rx->configure(c, display());
  Generator gen({{0, 1000, 2500, 0.45}});
  sdrcore::dsp::ProcessResult result;
  for (int b = 0; b < 200; ++b) {
    const auto iq = gen.next(kBlockPairs);
    rx->process(iq.data(), iq.size(), result);
  }
  CHECK(result.squelch_ready && result.squelch_open, "LO case: ready+open before");
  c.center_frequency_hz += 1000000;
  rx->configure(c, display());
  auto iq = gen.next(256);
  rx->process(iq.data(), iq.size(), result);
  CHECK(result.squelch_ready, "old-LO blocks after configure keep the old squelch state");
  rx->retune();
  iq = gen.next(256);
  rx->process(iq.data(), iq.size(), result);
  CHECK(!result.squelch_ready, "retune() after an LO station change clears readiness");
}

// The VFO fast path must really move the channel: two stations with
// different tones; after the move the second tone dominates.
void test_vfo_move_selects_new_station() {
  for (const uint32_t mode : {static_cast<uint32_t>(SDR_V3_WFM), static_cast<uint32_t>(SDR_V3_NFM)}) {
    const bool wfm = mode == SDR_V3_WFM;
    const uint32_t bw = wfm ? 200000 : 12500;
    const double dev = wfm ? 30000 : 2500;
    auto rx = sdrcore::dsp::make_receiver();
    rx->configure(controls(mode, bw, -300000), display());
    Generator gen({{-300000, 1000, dev, 0.3}, {400000, 3000, dev, 0.3}});
    sdrcore::dsp::ProcessResult result;
    std::vector<float> before, after;
    for (int b = 0; b < 300; ++b) {
      if (b == 150) rx->configure(controls(mode, bw, 400000), display());
      const auto iq = gen.next(kBlockPairs);
      rx->process(iq.data(), iq.size(), result);
      if (b >= 100 && b < 150) before.insert(before.end(), result.audio.begin(), result.audio.end());
      if (b >= 200) after.insert(after.end(), result.audio.begin(), result.audio.end());
    }
    const char* tag = wfm ? "WFM" : "NFM";
    CHECK(tone_power(before, 1000) > 20 * tone_power(before, 3000),
          "%s: 1 kHz station selected before the move", tag);
    CHECK(tone_power(after, 3000) > 20 * tone_power(after, 1000),
          "%s: 3 kHz station selected after the move", tag);
  }
}

// SSB passband edge offsets must match a fresh configure exactly.
void test_ssb_vfo_move_matches_fresh_configure() {
  for (const uint32_t mode : {static_cast<uint32_t>(SDR_V3_USB), static_cast<uint32_t>(SDR_V3_LSB)}) {
    auto moved = sdrcore::dsp::make_receiver();
    auto fresh = sdrcore::dsp::make_receiver();
    moved->configure(controls(mode, 2800, 10000), display());
    // Move first, then reset both so the comparison starts from equal state.
    moved->configure(controls(mode, 2800, 251000), display());
    fresh->configure(controls(mode, 2800, 251000), display());
    moved->reset();
    fresh->reset();
    Generator g1({{252000, 700, 0, 0.3}}), g2({{252000, 700, 0, 0.3}});
    sdrcore::dsp::ProcessResult r1, r2;
    std::vector<float> a, b;
    for (int k = 0; k < 120; ++k) {
      const auto i1 = g1.next(kBlockPairs), i2 = g2.next(kBlockPairs);
      moved->process(i1.data(), i1.size(), r1);
      fresh->process(i2.data(), i2.size(), r2);
      a.insert(a.end(), r1.audio.begin(), r1.audio.end());
      b.insert(b.end(), r2.audio.begin(), r2.audio.end());
    }
    double diff = 0;
    for (size_t i = 0; i < std::min(a.size(), b.size()); ++i)
      diff = std::max(diff, static_cast<double>(std::fabs(a[i] - b[i])));
    CHECK(a.size() == b.size() && diff < 1e-3, "%s: moved VFO output equals fresh configure (max diff %.2e)",
          mode == SDR_V3_USB ? "USB" : "LSB", diff);
  }
}

}  // namespace

int main() {
  test_wfm_vfo_drag_keeps_audio();
  test_wfm_lo_retune_keeps_audio();
  test_nfm_squelch_holds_during_drag();
  test_squelch_relearns_only_on_channel_change();
  test_lo_station_change_relearns_at_retune();
  test_vfo_move_selects_new_station();
  test_ssb_vfo_move_matches_fresh_configure();
  if (failures) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::printf("retune audio continuity: all passed\n");
  return 0;
}

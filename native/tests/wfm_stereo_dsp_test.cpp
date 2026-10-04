// SPDX-License-Identifier: GPL-3.0-or-later
//
// Standalone numeric test for the WFM 19 kHz pilot / 38 kHz subcarrier
// stereo decoder in src/dsp/receiver.cpp, driven only through the public
// sdrcore::dsp::Receiver interface (configure/set_wfm_stereo/reset/process)
// with deterministic synthetic FM multiplex (MPX) IQ -- no real hardware,
// no ABI layer, no Dart/FFI. This is a DSP correctness check, not the
// physical QA done separately on the RTL-SDR Blog V4.
//
// Multiplex convention matches broadcast FM / SDR++'s
// core/src/dsp/demod/broadcast_fm.h: mpx(t) = (L+R) + pilot*cos(2*pi*19000*t)
// + (L-R)*cos(2*pi*38000*t), FM-modulated onto the carrier with the same
// +-75 kHz full-scale deviation convention receiver.cpp uses to normalize
// its discriminator output (process_if(): value = discriminator * if_rate /
// (2*pi*75000)). Feeding deviation = 75000*mpx(t) therefore makes the
// decoder's recovered pre-filter MPX numerically equal to mpx(t) itself,
// which keeps the expected recovered L/R amplitudes easy to reason about.
#include "../src/dsp/receiver.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kCarrierDeviationHz = 75000.0;  // WFM full-scale deviation.
constexpr uint32_t kSampleRate = 1000000;        // Complex IQ pairs/s.
constexpr uint32_t kBandwidthHz = 150000;        // Matches n2_oracle.cpp WFM cases.
constexpr double kToneHz = 700.0;                // Well below the 15 kHz MPX cutoff.
constexpr double kSeconds = 2.0;
// Pilot PLL settle (~80 us, bandwidth-limited) plus the 200 ms mono<->stereo
// blend ramp in receiver.cpp's configure_pilot(); trim generously before
// taking any numeric measurement.
constexpr double kTrimSeconds = 0.5;

int failures = 0;

#define CHECK(cond, ...)                                                 \
  do {                                                                   \
    if (!(cond)) {                                                       \
      std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);          \
      std::fprintf(stderr, __VA_ARGS__);                                 \
      std::fprintf(stderr, "\n");                                        \
      ++failures;                                                        \
    } else {                                                             \
      std::printf("[ok] ");                                              \
      std::printf(__VA_ARGS__);                                          \
      std::printf("\n");                                                 \
    }                                                                    \
  } while (0)

// Generates CU8 IQ (centered at 127.5, matching the RTL-SDR/HackRF-normalized
// native ingress convention receiver.cpp consumes) for a carrier at the LO
// (zero VFO offset), FM-modulated by mpx_fn(t) with deviation scaled to the
// WFM full-scale convention above.
std::vector<uint8_t> make_wfm_cu8(uint32_t rate, double seconds,
                                   const std::function<double(double)>& mpx_fn) {
  const size_t pairs = static_cast<size_t>(seconds * rate);
  std::vector<uint8_t> out(2 * pairs);
  double phase = 0.0;
  for (size_t n = 0; n < pairs; ++n) {
    const double t = static_cast<double>(n) / rate;
    const double f = kCarrierDeviationHz * mpx_fn(t);
    phase += 2 * kPi * f / rate;
    if (phase > kPi) phase -= 2 * kPi;
    if (phase < -kPi) phase += 2 * kPi;
    const double i = std::cos(phase), q = std::sin(phase);
    auto quant = [](double v) {
      return static_cast<uint8_t>(std::clamp(std::lround(127.5 + 127.5 * v), 0L, 255L));
    };
    out[2 * n] = quant(i);
    out[2 * n + 1] = quant(q);
  }
  return out;
}

SdrV3Controls make_controls(bool wfm) {
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = 100000000;
  c.vfo_offset_hz = 0;
  c.sample_rate = kSampleRate;
  c.mode = wfm ? SDR_V3_WFM : SDR_V3_NFM;
  c.bandwidth_hz = wfm ? kBandwidthHz : 12500;
  c.gain_tenths_db = 200;
  c.squelch = SDR_V3_SQUELCH_OFF;
  c.squelch_level_db = -50;
  c.auto_squelch_offset_db = 0;
  c.volume = 1.0f;
  c.muted = 0;
  return c;
}

SdrV3Display make_display() {
  SdrV3Display d{};
  d.size = sizeof d;
  d.revision = SDR_V3_REVISION;
  d.view_offset_hz = 0;
  d.view_bandwidth_hz = kSampleRate;
  d.width = 0;  // No FFT row needed for this DSP-only test.
  return d;
}

// Runs the given MPX waveform through a freshly configured receiver and
// returns the interleaved stereo 48 kHz PCM, trimmed to drop the lock/blend
// transient described above.
std::vector<float> run_wfm(bool stereo_enabled, const std::function<double(double)>& mpx_fn) {
  auto receiver = sdrcore::dsp::make_receiver();
  const SdrV3Controls controls = make_controls(/*wfm=*/true);
  const SdrV3Display display = make_display();
  receiver->configure(controls, display);
  receiver->set_wfm_stereo(stereo_enabled);
  const std::vector<uint8_t> cu8 = make_wfm_cu8(kSampleRate, kSeconds, mpx_fn);
  sdrcore::dsp::ProcessResult result;
  receiver->process(cu8.data(), cu8.size(), result);
  const size_t trim_frames = static_cast<size_t>(kTrimSeconds * 48000);
  if (result.audio.size() / 2 <= trim_frames) return {};
  return std::vector<float>(result.audio.begin() + static_cast<std::ptrdiff_t>(2 * trim_frames),
                             result.audio.end());
}

struct Metrics {
  double rms_l = 0, rms_r = 0;
  double rms_sum = 0;    // RMS(L+R): crosstalk/leakage into the common channel.
  double rms_diff = 0;   // RMS(L-R): recovered channel separation.
  double dot_l = 0, dot_r = 0;  // Correlation of L, R with a +sin(2*pi*kToneHz*t) reference.
  size_t frames = 0;
};

Metrics measure(const std::vector<float>& audio, double trim_seconds) {
  Metrics m;
  m.frames = audio.size() / 2;
  double sum_sq = 0, sum_sq_diff = 0, sum_sq_l = 0, sum_sq_r = 0;
  for (size_t i = 0; i < m.frames; ++i) {
    const float l = audio[2 * i], r = audio[2 * i + 1];
    sum_sq_l += static_cast<double>(l) * l;
    sum_sq_r += static_cast<double>(r) * r;
    sum_sq += (static_cast<double>(l) + r) * (l + r);
    sum_sq_diff += (static_cast<double>(l) - r) * (l - r);
    const double t = trim_seconds + static_cast<double>(i) / 48000.0;
    const double reference = std::sin(2 * kPi * kToneHz * t);
    m.dot_l += l * reference;
    m.dot_r += r * reference;
  }
  if (m.frames > 0) {
    m.rms_l = std::sqrt(sum_sq_l / m.frames);
    m.rms_r = std::sqrt(sum_sq_r / m.frames);
    m.rms_sum = std::sqrt(sum_sq / m.frames);
    m.rms_diff = std::sqrt(sum_sq_diff / m.frames);
  }
  return m;
}

// --- Test cases -------------------------------------------------------

// Anti-symmetric content (L = +A*tone, R = -A*tone, so L+R == 0 and
// L-R == 2*A*tone) with a full-strength pilot: exercises coherent pilot
// lock, 38 kHz subcarrier recovery and that L/R land on the correct output
// channel (not swapped, not sign-inverted).
void case_stereo_separation_and_orientation() {
  constexpr double kToneAmplitude = 0.25, kPilotAmplitude = 0.08;
  auto mpx = [](double t) {
    const double l = kToneAmplitude * std::sin(2 * kPi * kToneHz * t);
    const double r = -l;
    return (l + r) + kPilotAmplitude * std::cos(2 * kPi * 19000.0 * t) +
           (l - r) * std::cos(2 * kPi * 38000.0 * t);
  };
  const std::vector<float> audio = run_wfm(/*stereo_enabled=*/true, mpx);
  CHECK(!audio.empty(), "stereo separation case produced audio after trim");
  if (audio.empty()) return;
  const Metrics m = measure(audio, kTrimSeconds);
  std::printf("    separation case: rms_l=%.4f rms_r=%.4f rms_sum(L+R)=%.4f "
              "rms_diff(L-R)=%.4f dot_l=%.2f dot_r=%.2f\n",
              m.rms_l, m.rms_r, m.rms_sum, m.rms_diff, m.dot_l, m.dot_r);
  // Expected recovered difference amplitude is 2*kToneAmplitude = 0.5 before
  // deemphasis roll-off (negligible at 700 Hz for a 50 us time constant).
  CHECK(m.rms_diff > 0.25, "locked pilot recovers a strong L-R component (rms_diff=%.4f)",
        m.rms_diff);
  // The true common-mode content is exactly zero; any leakage must stay far
  // below the recovered separation signal.
  CHECK(m.rms_sum < 0.2 * m.rms_diff,
        "L+R crosstalk (%.4f) stays well below the recovered separation (%.4f)",
        m.rms_sum, m.rms_diff);
  // Channel orientation: L must correlate positively with the reference
  // tone (it is literally +A*sin(...)) and R negatively (it is -A*sin(...));
  // a swapped or sign-inverted implementation would fail this.
  CHECK(m.dot_l > 0, "left channel is positively correlated with its source tone (dot_l=%.2f)",
        m.dot_l);
  CHECK(m.dot_r < 0, "right channel is negatively correlated, i.e. not swapped with L (dot_r=%.2f)",
        m.dot_r);
}

// True mono content (L == R) with a locked pilot: the coherent decoder must
// not hallucinate a stereo difference signal from content that has none.
void case_locked_pilot_true_mono_has_no_crosstalk() {
  constexpr double kToneAmplitude = 0.3, kPilotAmplitude = 0.08;
  auto mpx = [](double t) {
    const double mono = kToneAmplitude * std::sin(2 * kPi * kToneHz * t);
    return 2 * mono + kPilotAmplitude * std::cos(2 * kPi * 19000.0 * t);
    // No 38 kHz term: a real mono source carries none.
  };
  const std::vector<float> audio = run_wfm(/*stereo_enabled=*/true, mpx);
  CHECK(!audio.empty(), "true-mono-with-pilot case produced audio after trim");
  if (audio.empty()) return;
  const Metrics m = measure(audio, kTrimSeconds);
  std::printf("    true-mono case: rms_l=%.4f rms_r=%.4f rms_diff(L-R)=%.4f\n",
              m.rms_l, m.rms_r, m.rms_diff);
  CHECK(m.rms_l > 0.1, "mono program audio is actually recovered (rms_l=%.4f)", m.rms_l);
  CHECK(m.rms_diff < 0.08 * m.rms_l,
        "no spurious L-R separation is introduced for true mono content (rms_diff=%.4f, rms_l=%.4f)",
        m.rms_diff, m.rms_l);
}

// Pilot amplitude below the lock-on threshold (kPilotLockOnAmplitude in
// receiver.cpp): the stereo decoder must fall back to mono (stereo_blend_
// stays at 0) instead of exposing noisy or incorrect separation, even
// though the true L/R content differs strongly.
void case_weak_pilot_falls_back_to_mono() {
  constexpr double kToneAmplitude = 0.25, kWeakPilotAmplitude = 0.004;
  auto mpx = [](double t) {
    const double l = kToneAmplitude * std::sin(2 * kPi * kToneHz * t);
    const double r = -l;
    return (l + r) + kWeakPilotAmplitude * std::cos(2 * kPi * 19000.0 * t) +
           (l - r) * std::cos(2 * kPi * 38000.0 * t);
  };
  const std::vector<float> audio = run_wfm(/*stereo_enabled=*/true, mpx);
  CHECK(!audio.empty(), "weak pilot case produced audio after trim");
  if (audio.empty()) return;
  const Metrics m = measure(audio, kTrimSeconds);
  std::printf("    weak pilot case: rms_l=%.4f rms_r=%.4f rms_diff(L-R)=%.4f\n",
              m.rms_l, m.rms_r, m.rms_diff);
  // True L-R content has amplitude 0.5; a locked decoder would recover most
  // of it (see case_stereo_separation_and_orientation). An unlocked decoder
  // must suppress it to near silence (L+R == 0 here, so mono fallback audio
  // is near-silent too).
  CHECK(m.rms_diff < 0.1,
        "weak/absent pilot suppresses L-R separation instead of exposing it (rms_diff=%.4f)",
        m.rms_diff);
}

// Default/disabled preference: set_wfm_stereo() is never called (false by
// construction). Even with a strong pilot and strongly differing true L/R
// content, L and R must be bit-exact duplicates of the mono demodulation,
// matching the pre-stereo behavior exactly (AGENTS.md: "preserve exactly
// mono output when disabled").
void case_disabled_preference_is_bit_exact_mono() {
  constexpr double kPilotAmplitude = 0.08;
  auto mpx = [](double t) {
    const double l = 0.2 * std::sin(2 * kPi * kToneHz * t) + 0.05 * std::sin(2 * kPi * 1300.0 * t);
    const double r = 0.15 * std::sin(2 * kPi * kToneHz * t) - 0.05 * std::sin(2 * kPi * 1300.0 * t);
    return (l + r) + kPilotAmplitude * std::cos(2 * kPi * 19000.0 * t) +
           (l - r) * std::cos(2 * kPi * 38000.0 * t);
  };
  const std::vector<float> audio = run_wfm(/*stereo_enabled=*/false, mpx);
  CHECK(!audio.empty(), "disabled-preference case produced audio after trim");
  if (audio.empty()) return;
  bool bit_exact = true;
  for (size_t i = 0; i * 2 + 1 < audio.size(); ++i)
    if (audio[2 * i] != audio[2 * i + 1]) { bit_exact = false; break; }
  CHECK(bit_exact, "L and R are bit-exact duplicates when stereo is disabled (default)");
  const Metrics m = measure(audio, kTrimSeconds);
  std::printf("    disabled-preference case: rms_l=%.4f\n", m.rms_l);
  // Regression guard: a bug that zeroes audio instead of leaving it mono
  // would also pass the bit-exact check above, so assert real signal too.
  CHECK(m.rms_l > 0.1, "mono (disabled-stereo) audio is not silently dropped (rms_l=%.4f)", m.rms_l);
}

// reset() must re-arm the pilot/blend state exactly like a fresh receiver:
// feeding the same strongly-separated MPX again after reset() must recover
// the same strong separation, not a stale or stuck mono/half-locked state.
void case_reset_reacquires_pilot_lock() {
  constexpr double kToneAmplitude = 0.25, kPilotAmplitude = 0.08;
  auto mpx = [](double t) {
    const double l = kToneAmplitude * std::sin(2 * kPi * kToneHz * t);
    const double r = -l;
    return (l + r) + kPilotAmplitude * std::cos(2 * kPi * 19000.0 * t) +
           (l - r) * std::cos(2 * kPi * 38000.0 * t);
  };
  auto receiver = sdrcore::dsp::make_receiver();
  const SdrV3Controls controls = make_controls(/*wfm=*/true);
  const SdrV3Display display = make_display();
  receiver->configure(controls, display);
  receiver->set_wfm_stereo(true);
  const std::vector<uint8_t> cu8 = make_wfm_cu8(kSampleRate, kSeconds, mpx);
  sdrcore::dsp::ProcessResult first;
  receiver->process(cu8.data(), cu8.size(), first);
  receiver->reset();
  sdrcore::dsp::ProcessResult second;
  receiver->process(cu8.data(), cu8.size(), second);
  const size_t trim_frames = static_cast<size_t>(kTrimSeconds * 48000);
  CHECK(first.audio.size() / 2 > trim_frames && second.audio.size() / 2 > trim_frames,
        "both pre- and post-reset runs produced enough audio to measure");
  if (first.audio.size() / 2 <= trim_frames || second.audio.size() / 2 <= trim_frames) return;
  const std::vector<float> a(first.audio.begin() + static_cast<std::ptrdiff_t>(2 * trim_frames),
                              first.audio.end());
  const std::vector<float> b(second.audio.begin() + static_cast<std::ptrdiff_t>(2 * trim_frames),
                              second.audio.end());
  const Metrics ma = measure(a, kTrimSeconds), mb = measure(b, kTrimSeconds);
  std::printf("    reset case: rms_diff before=%.4f after=%.4f\n", ma.rms_diff, mb.rms_diff);
  CHECK(mb.rms_diff > 0.25, "pilot lock and separation reacquire after reset() (rms_diff=%.4f)",
        mb.rms_diff);
}

// Switching between WFM and NFM, and toggling set_wfm_stereo() mid-session,
// must not crash or leave non-WFM modes affected: NFM audio must still be
// plain mono (duplicated L/R), independent of the stereo preference.
void case_non_wfm_mode_is_unaffected_by_stereo_preference() {
  auto receiver = sdrcore::dsp::make_receiver();
  SdrV3Controls nfm = make_controls(/*wfm=*/false);
  const SdrV3Display display = make_display();
  receiver->configure(nfm, display);
  receiver->set_wfm_stereo(true);  // Preference retained, but NFM ignores it.
  std::vector<uint8_t> cu8 = make_wfm_cu8(kSampleRate, 0.3,
      [](double t) { return 0.3 * std::sin(2 * kPi * kToneHz * t); });
  sdrcore::dsp::ProcessResult result;
  receiver->process(cu8.data(), cu8.size(), result);
  bool bit_exact = true;
  for (size_t i = 0; i * 2 + 1 < result.audio.size(); ++i)
    if (result.audio[2 * i] != result.audio[2 * i + 1]) { bit_exact = false; break; }
  CHECK(bit_exact, "NFM output stays mono-duplicated even with the WFM stereo preference set");
}

}  // namespace

int main() {
  case_stereo_separation_and_orientation();
  case_locked_pilot_true_mono_has_no_crosstalk();
  case_weak_pilot_falls_back_to_mono();
  case_disabled_preference_is_bit_exact_mono();
  case_reset_reacquires_pilot_lock();
  case_non_wfm_mode_is_unaffected_by_stereo_preference();
  if (failures) {
    std::fprintf(stderr, "%d check(s) failed.\n", failures);
    return 1;
  }
  std::printf("All WFM stereo DSP checks passed.\n");
  return 0;
}

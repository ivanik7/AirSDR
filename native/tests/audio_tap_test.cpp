// SPDX-License-Identifier: GPL-3.0-or-later
//
// DSP-only tests for the Receiver's Input::audio data-decoder tap (receiver.h
// set_decoder() doc comment), driven only through the public
// sdrcore::dsp::Receiver interface -- no ABI layer, no Dart/FFI, no real
// hardware. Models wfm_stereo_dsp_test.cpp / retune_audio_continuity_test.cpp
// in style: a probe Decoder subclass records what the receiver calls, and
// deterministic synthetic CU8 IQ drives measurable tap output.
#include "../src/dsp/receiver.h"
#include "../src/dsp/csdr_nfm_deemphasis_24000.h"
#include "decoder.hpp"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;
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

// --- Probe decoder ------------------------------------------------------

// Records every call the receiver makes on an Input::audio-attached
// decoder: set_tuning()/reset() order, and the samples/rate passed to
// process(). accept_usb_lsb_nfm_ mirrors the contract SSTV-style backends
// are expected to use (USB/LSB/NFM only); flip it to false to simulate a
// decoder that rejects every mode, for the gating test.
class Probe final : public sdrcore::decoder::Decoder {
 public:
  bool configure(std::string_view) override { return true; }
  void reset() override { ++resets; }
  void process(const float* samples, size_t frames, uint32_t rate) override {
    rates.push_back(rate);
    total_frames += frames;
    audio.insert(audio.end(), samples, samples + frames);
  }
  bool take_event(sdrcore::decoder::Event&) override { return false; }
  bool accepts_mode(uint32_t mode) const override {
    if (!accept_usb_lsb_nfm_) return false;
    return mode == SDR_V3_USB || mode == SDR_V3_LSB || mode == SDR_V3_NFM;
  }
  void set_tuning(uint64_t tuned_frequency_hz, uint32_t mode) override {
    tuning_calls.emplace_back(tuned_frequency_hz, mode);
  }

  int resets = 0;
  bool accept_usb_lsb_nfm_ = true;
  std::vector<std::pair<uint64_t, uint32_t>> tuning_calls;
  std::vector<uint32_t> rates;
  std::vector<float> audio;
  size_t total_frames = 0;
};

// --- Controls/display builders ------------------------------------------

SdrV3Controls make_controls(uint32_t mode, uint32_t bandwidth, uint32_t sample_rate,
                             uint64_t center_hz, int64_t vfo_offset_hz) {
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = center_hz;
  c.vfo_offset_hz = vfo_offset_hz;
  c.sample_rate = sample_rate;
  c.mode = mode;
  c.bandwidth_hz = bandwidth;
  c.gain_tenths_db = 200;
  c.squelch = SDR_V3_SQUELCH_OFF;
  c.squelch_level_db = -50;
  c.auto_squelch_offset_db = 0;
  c.volume = 1.0f;
  c.muted = 0;
  return c;
}

SdrV3Display make_display(uint32_t sample_rate) {
  SdrV3Display d{};
  d.size = sizeof d;
  d.revision = SDR_V3_REVISION;
  d.view_offset_hz = 0;
  d.view_bandwidth_hz = sample_rate;
  d.width = 0;  // No FFT row needed for these DSP-only checks.
  return d;
}

// --- Synthetic IQ generators ---------------------------------------------

// A single complex tone at `offset_hz` from the tuner's RF center, CU8
// quantized at 127.5 (matching the native ingress convention). Used for
// USB/LSB: process_if()'s sideband correction makes the demodulated tone
// frequency equal |offset_hz - vfo_offset_hz| regardless of USB/LSB, so the
// caller places the RF tone at vfo_offset_hz + tone_hz (USB) or
// vfo_offset_hz - tone_hz (LSB) to get a `tone_hz` tap tone.
std::vector<uint8_t> make_tone_cu8(uint32_t sample_rate, double seconds, double offset_hz,
                                    double amplitude = 0.3) {
  const size_t pairs = static_cast<size_t>(seconds * sample_rate);
  std::vector<uint8_t> out(2 * pairs);
  double phase = 0.0;
  const double step = 2 * kPi * offset_hz / sample_rate;
  for (size_t n = 0; n < pairs; ++n) {
    const double i = amplitude * std::cos(phase), q = amplitude * std::sin(phase);
    auto quant = [](double v) { return static_cast<uint8_t>(std::clamp(std::lround(127.5 + 127.5 * v), 0L, 255L)); };
    out[2 * n] = quant(i);
    out[2 * n + 1] = quant(q);
    phase += step;
    if (phase > kPi) phase -= 2 * kPi;
    if (phase < -kPi) phase += 2 * kPi;
  }
  return out;
}

// FM-modulated carrier at `carrier_offset_hz` (the tuned frequency), tone
// modulation at `tone_hz` with peak deviation `deviation_hz`. Matches
// wfm_stereo_dsp_test.cpp's make_wfm_cu8 convention, generalized to any
// deviation (that test is fixed at the WFM 75 kHz full-scale convention).
std::vector<uint8_t> make_fm_cu8(uint32_t sample_rate, double seconds, double carrier_offset_hz,
                                  double tone_hz, double deviation_hz, double amplitude = 0.3) {
  const size_t pairs = static_cast<size_t>(seconds * sample_rate);
  std::vector<uint8_t> out(2 * pairs);
  double phase = 0.0;
  for (size_t n = 0; n < pairs; ++n) {
    const double t = static_cast<double>(n) / sample_rate;
    const double f = carrier_offset_hz + deviation_hz * std::sin(2 * kPi * tone_hz * t);
    phase += 2 * kPi * f / sample_rate;
    if (phase > kPi) phase -= 2 * kPi;
    if (phase < -kPi) phase += 2 * kPi;
    const double i = amplitude * std::cos(phase), q = amplitude * std::sin(phase);
    auto quant = [](double v) { return static_cast<uint8_t>(std::clamp(std::lround(127.5 + 127.5 * v), 0L, 255L)); };
    out[2 * n] = quant(i);
    out[2 * n + 1] = quant(q);
  }
  return out;
}

// --- FFT-based tone frequency / THD+N estimator --------------------------

using Complex = std::complex<double>;

void fft(std::vector<Complex>& data) {
  const size_t n = data.size();
  for (size_t i = 1, j = 0; i < n; ++i) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(data[i], data[j]);
  }
  for (size_t len = 2; len <= n; len <<= 1) {
    const Complex step = std::polar(1.0, -2 * kPi / static_cast<double>(len));
    for (size_t base = 0; base < n; base += len) {
      Complex w{1, 0};
      for (size_t j = 0; j < len / 2; ++j) {
        const Complex a = data[base + j], b = data[base + j + len / 2] * w;
        data[base + j] = a + b;
        data[base + j + len / 2] = a - b;
        w *= step;
      }
    }
  }
}

struct ToneMeasurement {
  double frequency_hz = 0;
  double thdn_db = 0;
  bool ok = false;
};

// Hann-windowed FFT with quadratic (log-magnitude parabolic) peak
// interpolation for sub-bin frequency accuracy, plus a power-domain THD+N
// estimate (ratio of everything outside a small window around the
// fundamental to the total spectral power). `samples` should already
// exclude any startup filter transient.
ToneMeasurement measure_tone(const std::vector<float>& samples, double sample_rate) {
  ToneMeasurement result;
  if (samples.size() < 256) return result;
  size_t n = 1;
  while (n * 2 <= samples.size()) n *= 2;
  std::vector<Complex> data(n);
  for (size_t i = 0; i < n; ++i) {
    const double w = 0.5 - 0.5 * std::cos(2 * kPi * i / (n - 1));  // Hann.
    data[i] = Complex(samples[i] * w, 0.0);
  }
  fft(data);
  std::vector<double> mag(n / 2);
  for (size_t k = 0; k < n / 2; ++k) mag[k] = std::abs(data[k]);
  size_t peak = 1;
  for (size_t k = 2; k < n / 2; ++k) if (mag[k] > mag[peak]) peak = k;
  if (peak == 0 || peak >= n / 2 - 1 || mag[peak] <= 0) return result;
  const double a = std::log(std::max(mag[peak - 1], 1e-12)),
               b = std::log(std::max(mag[peak], 1e-12)),
               c = std::log(std::max(mag[peak + 1], 1e-12));
  const double denom = a - 2 * b + c;
  const double delta = denom != 0 ? 0.5 * (a - c) / denom : 0.0;
  result.frequency_hz = (static_cast<double>(peak) + delta) * sample_rate / n;
  double total_power = 0, signal_power = 0;
  const size_t window = 3;
  for (size_t k = 1; k < n / 2; ++k) {
    const double power = mag[k] * mag[k];
    total_power += power;
    if (k + window >= peak && k <= peak + window) signal_power += power;
  }
  const double noise_power = std::max(0.0, total_power - signal_power);
  result.thdn_db = 10 * std::log10(std::max(noise_power, 1e-20) / std::max(signal_power, 1e-20));
  result.ok = true;
  return result;
}

// --- Processing helpers ---------------------------------------------------

// Feeds `iq` to the receiver in realistic-sized blocks (like the real DSP
// owner does) instead of one giant call, exercising the tap's per-call
// batching (receiver.h: "collect tap samples during process() and call
// decoder->process() once per process() call").
void feed(sdrcore::dsp::Receiver& rx, const std::vector<uint8_t>& iq, sdrcore::dsp::ProcessResult& result,
          size_t block_pairs = 8192) {
  const size_t block_bytes = 2 * block_pairs;
  for (size_t off = 0; off < iq.size(); off += block_bytes) {
    const size_t n = std::min(block_bytes, iq.size() - off);
    rx.process(iq.data() + off, n, result);
  }
}

// --- Test cases -----------------------------------------------------------

// USB/LSB tone frequency accuracy and THD+N across sample rates and
// bandwidths (receiver.h / task spec: <=1 Hz error, THD+N <= -40 dB).
void test_ssb_tone_accuracy() {
  const uint32_t rates[] = {250000, 1024000, 2048000, 2400000};
  const uint32_t bandwidths[] = {2800, 6000};
  const double tones[] = {1100, 1500, 1900, 2300};
  const uint32_t modes[] = {static_cast<uint32_t>(SDR_V3_USB), static_cast<uint32_t>(SDR_V3_LSB)};
  constexpr int64_t kVfoOffset = 40000;
  constexpr double kSeconds = 1.5, kDiscardSeconds = 0.5;
  for (uint32_t sample_rate : rates) {
    for (uint32_t bw : bandwidths) {
      for (uint32_t mode : modes) {
        for (double tone : tones) {
          auto rx = sdrcore::dsp::make_receiver();
          Probe probe;
          const SdrV3Controls c = make_controls(mode, bw, sample_rate, 14000000, kVfoOffset);
          rx->configure(c, make_display(sample_rate));
          rx->set_decoder(&probe, sdrcore::decoder::Input::audio);
          const double rf_offset = kVfoOffset + (mode == SDR_V3_USB ? tone : -tone);
          const auto iq = make_tone_cu8(sample_rate, kSeconds, rf_offset);
          sdrcore::dsp::ProcessResult result;
          feed(*rx, iq, result);
          const size_t discard = static_cast<size_t>(kDiscardSeconds * 24000);
          CHECK(probe.audio.size() > discard + 12000,
                "USB/LSB sr=%u bw=%u mode=%u tone=%.0f: enough tap samples (%zu)",
                sample_rate, bw, mode, tone, probe.audio.size());
          if (probe.audio.size() <= discard + 12000) continue;
          const std::vector<float> trimmed(probe.audio.begin() + static_cast<std::ptrdiff_t>(discard),
                                            probe.audio.end());
          const ToneMeasurement m = measure_tone(trimmed, 24000);
          CHECK(m.ok, "sr=%u bw=%u mode=%s tone=%.0f: tone measurement produced a result",
                sample_rate, bw, mode == SDR_V3_USB ? "USB" : "LSB", tone);
          if (!m.ok) continue;
          CHECK(std::fabs(m.frequency_hz - tone) <= 1.0,
                "sr=%u bw=%u mode=%s tone=%.0f: measured %.3f Hz (err %.3f Hz)",
                sample_rate, bw, mode == SDR_V3_USB ? "USB" : "LSB", tone, m.frequency_hz,
                m.frequency_hz - tone);
          CHECK(m.thdn_db <= -40.0,
                "sr=%u bw=%u mode=%s tone=%.0f: THD+N %.1f dB <= -40 dB",
                sample_rate, bw, mode == SDR_V3_USB ? "USB" : "LSB", tone, m.thdn_db);
        }
      }
    }
  }
}

// NFM tone accuracy after the csdr 24 kHz deemphasis FIR, plus a direct
// check that the FIR table matches csdr-plus's (count + known samples).
void test_nfm_tone_accuracy_and_deemphasis_table() {
  CHECK(sdrcore::dsp::kCsdrNfmDeemphasis24000Taps == 201,
        "NFM deemphasis FIR has the full 201-element csdr-plus table (not truncated to 199)");
  bool symmetric = true;
  for (int i = 0; i < sdrcore::dsp::kCsdrNfmDeemphasis24000Taps; ++i) {
    if (sdrcore::dsp::kCsdrNfmDeemphasis24000Fir[i] !=
        sdrcore::dsp::kCsdrNfmDeemphasis24000Fir[sdrcore::dsp::kCsdrNfmDeemphasis24000Taps - 1 - i]) {
      symmetric = false;
      break;
    }
  }
  CHECK(symmetric, "NFM deemphasis FIR is symmetric (linear phase), matching a firls design");
  CHECK(std::fabs(sdrcore::dsp::kCsdrNfmDeemphasis24000Fir[100] - 0.325263f) < 1e-5f,
        "NFM deemphasis FIR center tap matches csdr-plus's predefined.h literal (0.325263)");
  CHECK(std::fabs(sdrcore::dsp::kCsdrNfmDeemphasis24000Fir[0] - (-0.000889951f)) < 1e-8f,
        "NFM deemphasis FIR first tap matches csdr-plus's predefined.h literal (-0.000889951)");

  const uint32_t rates[] = {250000, 1024000, 2400000};
  const double tones[] = {1000, 1500, 2000};
  constexpr uint32_t kBandwidth = 12500;
  constexpr double kDeviation = 3000.0;
  constexpr double kSeconds = 1.5, kDiscardSeconds = 0.5;
  for (uint32_t sample_rate : rates) {
    for (double tone : tones) {
      auto rx = sdrcore::dsp::make_receiver();
      Probe probe;
      const SdrV3Controls c = make_controls(SDR_V3_NFM, kBandwidth, sample_rate, 446000000, 0);
      rx->configure(c, make_display(sample_rate));
      rx->set_decoder(&probe, sdrcore::decoder::Input::audio);
      const auto iq = make_fm_cu8(sample_rate, kSeconds, /*carrier_offset_hz=*/0, tone, kDeviation);
      sdrcore::dsp::ProcessResult result;
      feed(*rx, iq, result);
      const size_t discard = static_cast<size_t>(kDiscardSeconds * 24000);
      CHECK(probe.audio.size() > discard + 12000, "NFM sr=%u tone=%.0f: enough tap samples (%zu)",
            sample_rate, tone, probe.audio.size());
      if (probe.audio.size() <= discard + 12000) continue;
      const std::vector<float> trimmed(probe.audio.begin() + static_cast<std::ptrdiff_t>(discard),
                                        probe.audio.end());
      const ToneMeasurement m = measure_tone(trimmed, 24000);
      CHECK(m.ok, "NFM sr=%u tone=%.0f: tone measurement produced a result", sample_rate, tone);
      if (!m.ok) continue;
      CHECK(std::fabs(m.frequency_hz - tone) <= 1.0, "NFM sr=%u tone=%.0f: measured %.3f Hz (err %.3f Hz)",
            sample_rate, tone, m.frequency_hz, m.frequency_hz - tone);
    }
  }
}

// Long-term output sample count must not drift, for any if_rate_ the
// receiver's own channel-reshape logic may derive (receiver.h / task spec:
// 240000 +/- 2 over 10 s, for several source sample rates).
void test_exact_output_rate_and_decoder_rate_hz() {
  const uint32_t rates[] = {250000, 1024000, 2048000, 2400000};
  for (uint32_t sample_rate : rates) {
    auto rx = sdrcore::dsp::make_receiver();
    Probe probe;
    const SdrV3Controls c = make_controls(SDR_V3_USB, 2800, sample_rate, 14000000, 40000);
    rx->configure(c, make_display(sample_rate));
    CHECK(rx->decoder_rate_hz() == 0, "sr=%u: decoder_rate_hz()==0 before attach", sample_rate);
    const uint32_t rate = rx->set_decoder(&probe, sdrcore::decoder::Input::audio);
    CHECK(rate == 24000, "sr=%u: set_decoder() returns 24000 for Input::audio", sample_rate);
    CHECK(rx->decoder_rate_hz() == 24000, "sr=%u: decoder_rate_hz()==24000 while attached", sample_rate);
    const auto iq = make_tone_cu8(sample_rate, 10.0, 41500.0);
    sdrcore::dsp::ProcessResult result;
    feed(*rx, iq, result);
    CHECK(probe.total_frames >= 239998 && probe.total_frames <= 240002,
          "sr=%u: 10 s of IQ yields 240000 +/- 2 tap samples (got %zu)", sample_rate,
          probe.total_frames);
    bool all_24000 = !probe.rates.empty();
    for (uint32_t r : probe.rates) if (r != 24000) all_24000 = false;
    CHECK(all_24000, "sr=%u: every process() call to the decoder reports rate=24000", sample_rate);
    rx->set_decoder(nullptr);
    CHECK(rx->decoder_rate_hz() == 0, "sr=%u: decoder_rate_hz()==0 after detach", sample_rate);
  }
}

// Reset/set_tuning semantics exactly as specified in receiver.h.
void test_reset_semantics() {
  constexpr uint32_t kRate = 2048000;
  auto rx = sdrcore::dsp::make_receiver();
  Probe probe;
  SdrV3Controls c = make_controls(SDR_V3_USB, 2800, kRate, 14000000, 40000);
  rx->configure(c, make_display(kRate));

  // Attach: set_tuning(tuned) then reset().
  rx->set_decoder(&probe, sdrcore::decoder::Input::audio);
  CHECK(probe.resets == 1 && probe.tuning_calls.size() == 1,
        "attach: exactly one set_tuning()+reset() pair (resets=%d, tunings=%zu)",
        probe.resets, probe.tuning_calls.size());
  const uint64_t tuned0 = static_cast<uint64_t>(static_cast<int64_t>(c.center_frequency_hz) + c.vfo_offset_hz);
  CHECK(!probe.tuning_calls.empty() && probe.tuning_calls.back().first == tuned0 &&
            probe.tuning_calls.back().second == static_cast<uint32_t>(SDR_V3_USB),
        "attach: set_tuning() received the applied tuned frequency and mode");

  // Tuned-frequency (VFO) change -> set_tuning(new)+reset().
  const int resets_before_vfo = probe.resets;
  c.vfo_offset_hz = 45000;
  rx->configure(c, make_display(kRate));
  CHECK(probe.resets == resets_before_vfo + 1, "VFO change: exactly one more reset (resets=%d)",
        probe.resets);
  const uint64_t tuned1 = static_cast<uint64_t>(static_cast<int64_t>(c.center_frequency_hz) + c.vfo_offset_hz);
  CHECK(probe.tuning_calls.back().first == tuned1, "VFO change: set_tuning() received the new tuned frequency");

  // Mode change USB->LSB -> set_tuning(new)+reset().
  const int resets_before_mode = probe.resets;
  c.mode = SDR_V3_LSB;
  rx->configure(c, make_display(kRate));
  CHECK(probe.resets == resets_before_mode + 1, "mode change: exactly one more reset (resets=%d)",
        probe.resets);
  CHECK(probe.tuning_calls.back().second == static_cast<uint32_t>(SDR_V3_LSB),
        "mode change: set_tuning() received the new mode");

  // Bandwidth-only change -> no reset, tap continues.
  const int resets_before_bw = probe.resets;
  const size_t tuning_calls_before_bw = probe.tuning_calls.size();
  c.bandwidth_hz = 6000;
  rx->configure(c, make_display(kRate));
  CHECK(probe.resets == resets_before_bw, "bandwidth-only change: no reset (resets=%d)", probe.resets);
  CHECK(probe.tuning_calls.size() == tuning_calls_before_bw,
        "bandwidth-only change: no set_tuning() call either");
  {
    const auto iq = make_tone_cu8(kRate, 0.3, c.vfo_offset_hz - 1200.0);  // LSB: offset - tone.
    sdrcore::dsp::ProcessResult result;
    feed(*rx, iq, result);
    CHECK(probe.total_frames > 0, "bandwidth-only change: tap still produces samples afterward");
  }

  // LO recenter keeping the tuned frequency unchanged -> no reset in configure().
  const int resets_before_lo = probe.resets;
  const size_t tuning_calls_before_lo = probe.tuning_calls.size();
  c.center_frequency_hz += 1000;
  c.vfo_offset_hz -= 1000;  // Same tuned frequency (center+offset) as before.
  rx->configure(c, make_display(kRate));
  CHECK(probe.resets == resets_before_lo, "LO recenter (same tuned freq): no reset in configure() (resets=%d)",
        probe.resets);
  CHECK(probe.tuning_calls.size() == tuning_calls_before_lo,
        "LO recenter (same tuned freq): no set_tuning() call in configure() either");

  // retune(): always set_tuning(current)+reset(), even with no pending
  // station change (unlike the baseband/voice chain's conditional path).
  const int resets_before_retune = probe.resets;
  rx->retune();
  CHECK(probe.resets == resets_before_retune + 1, "retune(): exactly one more reset (resets=%d)", probe.resets);
  const uint64_t tuned_now = static_cast<uint64_t>(static_cast<int64_t>(c.center_frequency_hz) + c.vfo_offset_hz);
  CHECK(probe.tuning_calls.back().first == tuned_now, "retune(): set_tuning() received the current tuned frequency");

  // reset(): same guarantee.
  const int resets_before_reset = probe.resets;
  rx->reset();
  CHECK(probe.resets == resets_before_reset + 1, "reset(): exactly one more reset (resets=%d)", probe.resets);

  // Sample-rate change -> set_tuning(new)+reset().
  const int resets_before_rate = probe.resets;
  c.sample_rate = 2400000;
  rx->configure(c, make_display(c.sample_rate));
  CHECK(probe.resets == resets_before_rate + 1, "sample-rate change: exactly one more reset (resets=%d)",
        probe.resets);

  // Detach: no further calls on the old decoder.
  const int resets_at_detach = probe.resets;
  const size_t tunings_at_detach = probe.tuning_calls.size();
  rx->set_decoder(nullptr);
  const auto iq = make_tone_cu8(c.sample_rate, 0.3, c.vfo_offset_hz - 1200.0);
  sdrcore::dsp::ProcessResult result;
  feed(*rx, iq, result);
  CHECK(probe.resets == resets_at_detach && probe.tuning_calls.size() == tunings_at_detach,
        "detach: the old decoder receives no further reset()/set_tuning()/process() calls");
}

// Gating: mode not accepted by the decoder, squelch closed, squelch off.
void test_gating() {
  constexpr uint32_t kRate = 1024000;
  // Mode not accepted (probe only accepts USB/LSB/NFM; WFM is rejected).
  {
    auto rx = sdrcore::dsp::make_receiver();
    Probe probe;
    SdrV3Controls c = make_controls(SDR_V3_WFM, 150000, kRate, 100000000, 0);
    rx->configure(c, make_display(kRate));
    rx->set_decoder(&probe, sdrcore::decoder::Input::audio);
    const auto iq = make_fm_cu8(kRate, 0.5, 0, 1000, 30000);
    sdrcore::dsp::ProcessResult result;
    feed(*rx, iq, result);
    CHECK(probe.total_frames == 0, "unaccepted mode (WFM): no tap samples delivered (got %zu)",
          probe.total_frames);
  }
  // Squelch MANUAL with a threshold far above the signal: gate stays closed.
  {
    auto rx = sdrcore::dsp::make_receiver();
    Probe probe;
    SdrV3Controls c = make_controls(SDR_V3_NFM, 12500, kRate, 100000000, 0);
    c.squelch = SDR_V3_SQUELCH_MANUAL;
    c.squelch_level_db = 50.0f;  // Unreachable: closes the gate permanently.
    rx->configure(c, make_display(kRate));
    rx->set_decoder(&probe, sdrcore::decoder::Input::audio);
    const auto iq = make_fm_cu8(kRate, 0.5, 0, 1000, 3000);
    sdrcore::dsp::ProcessResult result;
    feed(*rx, iq, result);
    CHECK(probe.total_frames == 0, "squelch closed (threshold above signal): no tap samples (got %zu)",
          probe.total_frames);
  }
  // Squelch OFF: samples flow.
  {
    auto rx = sdrcore::dsp::make_receiver();
    Probe probe;
    SdrV3Controls c = make_controls(SDR_V3_NFM, 12500, kRate, 100000000, 0);
    c.squelch = SDR_V3_SQUELCH_OFF;
    rx->configure(c, make_display(kRate));
    rx->set_decoder(&probe, sdrcore::decoder::Input::audio);
    const auto iq = make_fm_cu8(kRate, 0.5, 0, 1000, 3000);
    sdrcore::dsp::ProcessResult result;
    feed(*rx, iq, result);
    CHECK(probe.total_frames > 0, "squelch off: tap samples flow (got %zu)", probe.total_frames);
  }
}

// Voice audio (ProcessResult.audio) must be bit-identical with and without
// an attached audio decoder, for both a non-FM (USB) and an FM (NFM) mode.
void test_voice_audio_bit_identical_with_and_without_tap() {
  constexpr uint32_t kRate = 2048000;
  struct Case { uint32_t mode; uint32_t bandwidth; double tone_offset; };
  const Case cases[] = {
      {static_cast<uint32_t>(SDR_V3_USB), 2800u, 1500.0},
      {static_cast<uint32_t>(SDR_V3_NFM), 12500u, 0.0},
  };
  for (const Case& tc : cases) {
    auto rx_plain = sdrcore::dsp::make_receiver();
    auto rx_tapped = sdrcore::dsp::make_receiver();
    Probe probe;
    const SdrV3Controls c = make_controls(tc.mode, tc.bandwidth, kRate, 100000000, 40000);
    rx_plain->configure(c, make_display(kRate));
    rx_tapped->configure(c, make_display(kRate));
    rx_tapped->set_decoder(&probe, sdrcore::decoder::Input::audio);
    const auto iq = tc.mode == SDR_V3_NFM
        ? make_fm_cu8(kRate, 0.6, c.vfo_offset_hz, 1000.0, 3000.0)
        : make_tone_cu8(kRate, 0.6, c.vfo_offset_hz + tc.tone_offset);
    sdrcore::dsp::ProcessResult plain, tapped;
    feed(*rx_plain, iq, plain);
    feed(*rx_tapped, iq, tapped);
    const bool same_size = plain.audio.size() == tapped.audio.size();
    bool bit_identical = same_size;
    if (same_size)
      for (size_t i = 0; i < plain.audio.size(); ++i)
        if (plain.audio[i] != tapped.audio[i]) { bit_identical = false; break; }
    CHECK(same_size, "mode=%u: voice audio has the same length with/without the tap (%zu vs %zu)",
          tc.mode, plain.audio.size(), tapped.audio.size());
    CHECK(bit_identical, "mode=%u: voice audio is bit-identical with/without an attached audio decoder",
          tc.mode);
    CHECK(!plain.audio.empty(), "mode=%u: voice audio is non-empty (sanity)", tc.mode);
  }
}

}  // namespace

int main() {
  test_ssb_tone_accuracy();
  test_nfm_tone_accuracy_and_deemphasis_table();
  test_exact_output_rate_and_decoder_rate_hz();
  test_reset_semantics();
  test_gating();
  test_voice_audio_bit_identical_with_and_without_tap();
  if (failures) {
    std::fprintf(stderr, "%d check(s) failed.\n", failures);
    return 1;
  }
  std::printf("All audio tap checks passed.\n");
  return 0;
}

// SPDX-License-Identifier: GPL-3.0-or-later
#include "receiver.h"
#include "decoder.hpp"
#include "../rds/rds.h"
#include "csdr_nfm_deemphasis_24000.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <cstdint>
#include <limits>
#include <vector>

namespace sdrcore {
namespace dsp {
namespace {
constexpr double kPi = 3.14159265358979323846;
// Input::audio data-decoder tap (see receiver.h set_decoder doc). Fixed
// output rate matching OpenWebRX+'s digimodes.py SSTV chain (24000 S/s
// real mono). Independent of the 48 kHz voice audio resampler below: a
// dedicated RealResampler/NfmTapDeemphasis instance owns its own state so
// attaching/detaching a data decoder cannot perturb voice audio output.
constexpr uint32_t kAudioTapRateHz = 24000;
// Anti-alias passband edge for the tap resampler. csdr-plus's own chain
// (openwebrx-plus csdr/chain/analog.py Ssb/NFm) channel-filters to 24 kS/s
// *before* FmDemod/RealPart, so its downstream SSTV/audio stages never see
// content above that chain's own channel filter. We instead demodulate at
// if_rate_ (>=24 kS/s, see receiver.h) and apply the anti-alias filter
// during the tap's own rate conversion to 24000 S/s, so the choice of
// cutoff here stands in for that upstream channel filter. 10.5 kHz leaves
// a safety margin below the 12 kHz output Nyquist while easily passing the
// SSTV VIS/tone range (1100-2300 Hz) flat. NFM capture bandwidth (12500 Hz
// default) benefits from the full range; SSB's narrower default bandwidth
// (2800 Hz) does not need it, and a lower cutoff gives the resampler a
// wider guard band against the real-projection's frequency-doubled image,
// so SSB uses a deliberately lower cutoff per the task's explicit allowance.
constexpr double kAudioTapCutoffNfmHz = 10500.0;
constexpr double kAudioTapCutoffSsbHz = 9500.0;
// pycsdr's Limit() module default maxAmplitude (pycsdr/src/limit.cpp
// Limit_init: "|f", default 1.0f) -- csdr-plus's NFm chain applies Limit()
// with no explicit argument between FmDemod and NfmDeemphasis.
constexpr float kAudioTapLimitMaxAmplitude = 1.0f;

// Tuned frequency per receiver.h/decoder.hpp: hardware LO plus the VFO
// reference-point displacement, matching sdrcore.cpp's own application of
// these two fields. Computed as int64 then reinterpreted per the frozen
// Decoder::set_tuning(uint64_t, ...) signature.
uint64_t tuned_frequency_hz(const SdrV3Controls& c) {
  return static_cast<uint64_t>(static_cast<int64_t>(c.center_frequency_hz) + c.vfo_offset_hz);
}

// Band-limited fractional-rate resampler dedicated to the Input::audio tap.
// Structurally mirrors the shared 48 kHz voice audio resampler further down
// in this file (phase-interpolated windowed-sinc polyphase bank driven by a
// double-precision fractional time accumulator, which is what keeps the
// long-term output sample count from drifting for an arbitrary, possibly
// non-integer input/output rate ratio) but owns separate coefficients and
// ring-buffer state so it never reads or mutates the voice chain's.
// Filter length scales with the input rate so the *absolute* transition
// bandwidth in Hz (and thus stopband attenuation) stays roughly constant
// regardless of if_rate_, instead of widening as if_rate_ grows (see
// ComplexDecimator::configure() above for the same scaling idea, applied
// there to integer decimation instead of phase-interpolated resampling).
class RealResampler {
 public:
  void configure(double input_rate, double output_rate, double cutoff_hz) {
    input_rate_ = input_rate;
    output_rate_ = output_rate;
    // Stopband edge is the true output Nyquist: content folding back from
    // above that frequency is what aliases into the resampled band, so the
    // filter only needs to have fully attenuated by the time it gets there
    // (not some tighter, arbitrary guard below it -- an earlier version of
    // this function subtracted an extra 10%-of-rate guard here, which
    // forced a needlessly narrow transition band and a correspondingly
    // oversized filter whenever input_rate was already close to
    // output_rate, as this receiver's own IF-rate selection logic tends to
    // produce for narrow-bandwidth USB/LSB channels).
    const double stop_hz = 0.5 * output_rate;
    const double transition_hz = std::max(100.0, stop_hz - cutoff_hz);
    // 5.5/N is the standard approximation for a Blackman-family window's
    // main-lobe transition width as a fraction of the sample rate; a factor
    // of 6.5 adds margin so the measured THD+N stays under -40 dB with
    // room to spare rather than sitting right at the edge of spec.
    const size_t raw_count = static_cast<size_t>(std::ceil(6.5 * input_rate / transition_hz));
    const size_t count = std::min(kMaxTaps, std::max<size_t>(9, raw_count | 1u));
    tap_count_ = count;
    const double fc = std::min(cutoff_hz, 0.5 * output_rate - 50.0) / input_rate;
    for (size_t phase = 0; phase < kPhases; ++phase) {
      const double fraction = static_cast<double>(phase) / kPhases;
      double sum = 0;
      for (size_t tap = 0; tap < count; ++tap) {
        const double x = static_cast<double>(tap) - static_cast<double>(count - 1) / 2 - fraction;
        const double sinc = x == 0 ? 2 * fc : std::sin(2 * kPi * fc * x) / (kPi * x);
        const double window = 0.42 - 0.5 * std::cos(2 * kPi * tap / (count - 1)) +
                              0.08 * std::cos(4 * kPi * tap / (count - 1));
        taps_[phase][tap] = static_cast<float>(sinc * window);
        sum += taps_[phase][tap];
      }
      for (size_t tap = 0; tap < count; ++tap) taps_[phase][tap] = static_cast<float>(taps_[phase][tap] / sum);
    }
    reset_state();
  }
  // Clears ring-buffer/phase-accumulator state without touching coefficients
  // (used on tuned-frequency/mode/sample-rate resets where the filter design
  // itself is unchanged); configure() above also calls this after a redesign.
  void reset_state() {
    history_.fill(0);
    index_ = 0;
    input_count_ = 0;
    next_output_time_ = 0;
  }
  void put(float sample, std::vector<float>& out) {
    history_[index_ & kHistoryMask] = sample;
    ++index_;
    ++input_count_;
    const double spacing = input_rate_ / output_rate_;
    while (next_output_time_ <= static_cast<double>(input_count_ - 1)) {
      const double lag = static_cast<double>(input_count_ - 1) - next_output_time_;
      if (lag < 0 || lag >= 1) break;
      const size_t phase = std::min<size_t>(kPhases - 1, static_cast<size_t>(lag * kPhases));
      float value = 0;
      size_t idx = index_ - 1;
      for (size_t tap = 0; tap < tap_count_; ++tap) {
        value += history_[idx & kHistoryMask] * taps_[phase][tap];
        --idx;
      }
      out.push_back(value);
      next_output_time_ += spacing;
    }
  }
 private:
  static constexpr size_t kPhases = 128;
  static constexpr size_t kMaxTaps = 401;
  static constexpr size_t kHistorySize = 512;  // power of 2, >= kMaxTaps.
  static constexpr size_t kHistoryMask = kHistorySize - 1;
  double input_rate_ = 24000, output_rate_ = 24000;
  size_t tap_count_ = kMaxTaps;
  std::array<std::array<float, kMaxTaps>, kPhases> taps_{};
  std::array<float, kHistorySize> history_{};
  size_t index_ = 0, input_count_ = 0;
  double next_output_time_ = 0;
};

// Direct-form FIR applying csdr-plus's NfmDeemphasis 24 kHz coefficients
// (see csdr_nfm_deemphasis_24000.h) to an already-24000 S/s stream. Runs
// once per *output* (24 kHz) sample, never per if_rate_ input sample, so
// its cost is independent of the receiver's IF rate.
class NfmTapDeemphasis {
 public:
  void reset() { history_.fill(0); index_ = 0; }
  float put(float sample) {
    history_[index_ & kMask] = sample;
    float sum = 0;
    for (int tap = 0; tap < kCsdrNfmDeemphasis24000Taps; ++tap)
      sum += kCsdrNfmDeemphasis24000Fir[tap] * history_[(index_ - static_cast<size_t>(tap)) & kMask];
    ++index_;
    return sum;
  }
 private:
  static constexpr size_t kHistorySize = 256;  // power of 2, >= kCsdrNfmDeemphasis24000Taps (201).
  static constexpr size_t kMask = kHistorySize - 1;
  std::array<float, kHistorySize> history_{};
  size_t index_ = 0;
};

// Constant-envelope limiter for the NFM audio tap, applied after
// NfmTapDeemphasis. The csdr NFM deemphasis FIR is not flat across the SSTV
// tone range (+1.0 dB at 1200 Hz, -1.4 dB at 1900 Hz, -3.2 dB at 2300 Hz,
// relative to 1500 Hz). For a transmitter without matching pre-emphasis
// that tilt becomes amplitude modulation at every tone step, and csdr's
// FFT-peak sync/pixel estimator, which looks at windows spanning a step,
// then favours the louder (lower) tone: the sync end is found late and
// PD-90 shifts about 2 px. A tone decoder only needs the instantaneous
// frequency, so the tap divides the signal by its analytic-signal envelope
// (127-tap Blackman Hilbert FIR, flat to +-0.001 dB from 900 Hz to 11 kHz;
// in-phase path delayed by the same 63 samples). This removes the tilt for
// any transmitter pre-emphasis, keeps the deemphasis' out-of-band noise
// rejection and does not touch the USB/LSB tap.
class ToneEnvelopeLimiter {
 public:
  ToneEnvelopeLimiter() {
    for (size_t k = 0; k < kTaps; ++k) {
      const long m = static_cast<long>(k) - static_cast<long>(kMid);
      if (m % 2 == 0) continue;
      const double w = 0.42 - 0.5 * std::cos(2 * kPi * k / (kTaps - 1)) +
                       0.08 * std::cos(4 * kPi * k / (kTaps - 1));
      taps_[k] = static_cast<float>(2.0 / (kPi * m) * w);
    }
  }
  void reset() { history_.fill(0); index_ = 0; }
  float put(float sample) {
    history_[index_ & kMask] = sample;
    float q = 0;
    // Only taps at an odd distance from the centre are non-zero (type-III
    // Hilbert FIR); kMid is odd, so those are the even k.
    for (size_t k = 0; k < kTaps; k += 2) q += taps_[k] * history_[(index_ - k) & kMask];
    const float i = history_[(index_ - kMid) & kMask];
    ++index_;
    const float envelope = std::sqrt(i * i + q * q);
    return envelope > kFloor ? i / envelope : 0.0f;
  }
 private:
  static constexpr size_t kTaps = 127, kMid = kTaps / 2;
  static constexpr size_t kHistorySize = 128;  // power of 2, >= kTaps.
  static constexpr size_t kMask = kHistorySize - 1;
  // Discriminator units (1.0 = 12 kHz deviation): far below any real tone,
  // so only digital silence maps to 0.
  static constexpr float kFloor = 1e-6f;
  std::array<float, kTaps> taps_{};
  std::array<float, kHistorySize> history_{};
  size_t index_ = 0;
};

// Dart IQFrontEnd default FFT size (8192, Nuttall, power / N^2) so that the
// native rows use the same dBFS convention as RadioController.FftRow. Lower
// sample rates use a smaller power-of-two size to keep >= 20 rows/s.
constexpr size_t kMaxFft = 8192;
constexpr size_t kMinFft = 256;
constexpr size_t kHistory = 1024;
constexpr float kFloor = 1.0e-12f;
// SDR++ CW demodulator default beat tone (cw.dart / cw.h: tone = 800).
constexpr double kCwToneHz = 800.0;
// SDR++ AGC set point for AM/SSB/CW audio (am.h/ssb.h/cw.h: AGC(1.0, ...)).
constexpr float kAgcSetPoint = 1.0f;
// Discriminator-domain pilot amplitude hysteresis for the stereo/mono
// fallback. The discriminator is normalized so a full +-75 kHz deviation
// WFM signal gives unit peak audio; a pilot injection of ~8-10% of peak
// deviation (the common broadcast practice) lands near 0.1. Separate
// on/off thresholds give hysteresis so a borderline pilot does not chatter
// the stereo_blend_ ramp target every envelope update.
constexpr float kPilotLockOnAmplitude = 0.02f;
constexpr float kPilotLockOffAmplitude = 0.012f;
using Complex = std::complex<float>;

// FIR histories are fixed-size; coefficients are regenerated only on configure().
class ComplexDecimator {
 public:
  void configure(double input_rate, double cutoff, unsigned factor, size_t max_taps = 511) {
    factor_ = std::max(1u, factor);
    const double transition = std::max(500.0, std::min(cutoff * 0.4, input_rate / factor_ * 0.12));
    const size_t count = std::min(max_taps, std::max<size_t>(63,
        static_cast<size_t>(std::ceil(3.5 * input_rate / transition)) | 1u));
    taps_.resize(count);
    const double fc = std::min(cutoff, 0.46 * input_rate / factor_) / input_rate;
    double sum = 0;
    for (size_t i = 0; i < count; ++i) {
      const double x = static_cast<double>(i) - static_cast<double>(count - 1) / 2;
      const double sinc = x == 0 ? 2 * fc : std::sin(2 * kPi * fc * x) / (kPi * x);
      const double window = 0.42 - 0.5 * std::cos(2 * kPi * i / (count - 1)) +
                            0.08 * std::cos(4 * kPi * i / (count - 1));
      taps_[i] = static_cast<float>(sinc * window);
      sum += taps_[i];
    }
    for (float& tap : taps_) tap = static_cast<float>(tap / sum);
    reset();
  }
  void reset() {
    history_.fill({});
    index_ = 0;
    phase_ = 0;
  }
  bool put(Complex sample, Complex& output) {
    history_[index_] = sample;
    index_ = (index_ + 1) & (kHistory - 1);
    if (++phase_ != factor_) return false;
    phase_ = 0;
    Complex sum{};
    size_t j = (index_ - 1) & (kHistory - 1);
    for (float tap : taps_) {
      sum += history_[j] * tap;
      j = (j - 1) & (kHistory - 1);
    }
    output = sum;
    return true;
  }
 private:
  std::array<Complex, kHistory> history_{};
  std::vector<float> taps_;
  size_t index_ = 0;
  unsigned phase_ = 0, factor_ = 1;
};

// Streaming rational converter for the ADS-B full-band tap. The 128 phases
// share a 48-tap, 1.05 MHz low-pass; history/clock persist across IQ blocks.
class AdsbResampler {
 public:
  void configure(uint32_t input_rate) {
    step_ = static_cast<double>(input_rate) / 2400000.0;
    constexpr size_t taps = 48, phases = 128;
    const double fc = 1050000.0 / input_rate;
    for (size_t p = 0; p < phases; ++p) {
      const double delay = static_cast<double>(p) / phases;
      double total = 0;
      for (size_t k = 0; k < taps; ++k) {
        const double x = static_cast<double>(k) - delay;
        const double sinc = x == 0 ? 2 * fc : std::sin(2 * kPi * fc * x) / (kPi * x);
        const double window = 0.42 - 0.5 * std::cos(2 * kPi * k / (taps - 1)) +
                              0.08 * std::cos(4 * kPi * k / (taps - 1));
        coeffs_[p][k] = static_cast<float>(sinc * window);
        total += coeffs_[p][k];
      }
      for (float& tap : coeffs_[p]) tap = static_cast<float>(tap / total);
    }
    reset();
  }
  void reset() {
    history_.fill({});
    count_ = index_ = 0;
    next_time_ = 0;
  }
  template <class Emit>
  void put(Complex sample, Emit&& emit) {
    history_[index_] = sample;
    index_ = (index_ + 1) & 63;
    ++count_;
    while (next_time_ <= static_cast<double>(count_ - 1)) {
      const double delay = static_cast<double>(count_ - 1) - next_time_;
      const size_t whole = static_cast<size_t>(delay);
      const size_t phase = std::min<size_t>(127,
          static_cast<size_t>((delay - whole) * 128));
      Complex output{};
      size_t j = (index_ - 1 - whole) & 63;
      for (const float tap : coeffs_[phase]) {
        output += history_[j] * tap;
        j = (j - 1) & 63;
      }
      emit(output);
      next_time_ += step_;
    }
  }
 private:
  std::array<Complex, 64> history_{};
  std::array<std::array<float, 48>, 128> coeffs_{};
  size_t count_ = 0, index_ = 0;
  double next_time_ = 0, step_ = 1;
};

void fft(Complex* data, size_t n) {
  for (size_t i = 1, j = 0; i < n; ++i) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(data[i], data[j]);
  }
  for (size_t len = 2; len <= n; len <<= 1) {
    const Complex step = std::polar(1.0f, static_cast<float>(-2 * kPi / len));
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

size_t fft_size_for(uint32_t sample_rate) {
  size_t n = kMaxFft;
  while (n > kMinFft && n > sample_rate / 20u) n >>= 1;
  return n;
}

class ReceiverImpl final : public Receiver {
 public:
  ReceiverImpl() : fft_input_(kMaxFft), fft_work_(kMaxFft), window_(kMaxFft) {
    set_fft_size(kMaxFft);
  }

  void configure(const SdrV3Controls& controls, const SdrV3Display& display) override {
    // The ABI owner validates the request. Guard against zero rate in standalone use.
    const bool initial = !configured_;
    // A VFO offset or LO move is not a channel change (see tune_change).
    const bool channel_change = initial || controls.sample_rate != controls_.sample_rate ||
        controls.mode != controls_.mode ||
        controls.bandwidth_hz != controls_.bandwidth_hz;
    const bool squelch_change = initial || channel_change || controls.squelch != controls_.squelch ||
        controls.squelch_level_db != controls_.squelch_level_db ||
        controls.auto_squelch_offset_db != controls_.auto_squelch_offset_db;
    const bool display_change = initial || display.width != display_.width ||
        display.view_bandwidth_hz != display_.view_bandwidth_hz ||
        display.view_offset_hz != display_.view_offset_hz ||
        controls.center_frequency_hz != controls_.center_frequency_hz ||
        controls.sample_rate != controls_.sample_rate;
    // Tuned-frequency move without a channel reshape (waterfall drag, step,
    // LO recenter). SDR++ and the old Dart engine only retarget the VFO
    // translator here (rx_vfo.setOffset); resetting the filters, resampler,
    // deemphasis and squelch gate punched a hole into the audio on every
    // drag event (t_c364ac15).
    const bool tune_change = !channel_change &&
        (controls.vfo_offset_hz != controls_.vfo_offset_hz ||
         controls.center_frequency_hz != controls_.center_frequency_hz);
    const bool lo_change = !initial &&
        controls.center_frequency_hz != controls_.center_frequency_hz;
    const bool decoder_tune_change = initial || controls.sample_rate != controls_.sample_rate ||
        controls.mode != controls_.mode ||
        controls.vfo_offset_hz != controls_.vfo_offset_hz ||
        controls.center_frequency_hz != controls_.center_frequency_hz;
    // Input::audio tap reset rule (receiver.h): reset only on an actual
    // tuned-frequency move (center+offset, not either field individually --
    // an LO recenter that keeps the sum must NOT reset), a mode change, or a
    // sample-rate change. Deliberately narrower than decoder_tune_change
    // above (which resets rtl_433's baseband branch on any LO/VFO field
    // change, even one that nets to the same tuned frequency).
    const bool audio_tuned_change = tuned_frequency_hz(controls) != tuned_frequency_hz(controls_);
    const bool audio_mode_change = controls.mode != controls_.mode;
    const bool audio_rate_change = controls.sample_rate != controls_.sample_rate;
    const bool rds_tune_change = !initial &&
        (static_cast<int64_t>(controls.center_frequency_hz) + controls.vfo_offset_hz !=
         static_cast<int64_t>(controls_.center_frequency_hz) + controls_.vfo_offset_hz);
    // A move by more than half the channel puts another signal into it:
    // the squelch and stereo pilot state of the old one no longer apply.
    const double tuned_delta = std::fabs(
        (static_cast<double>(controls.center_frequency_hz) + controls.vfo_offset_hz) -
        (static_cast<double>(controls_.center_frequency_hz) + controls_.vfo_offset_hz));
    const bool station_change = tune_change && 2 * tuned_delta > controls.bandwidth_hz;
    controls_ = controls;
    display_ = display;
    configured_ = controls.sample_rate > 0;
    if (!configured_) return;
    const double sr = controls.sample_rate;
    if (display_change && fft_size_for(controls.sample_rate) != fft_n_)
      set_fft_size(fft_size_for(controls.sample_rate));
    if (tune_change) {
      // Phase-continuous NCO retarget; the IQ for the new LO (if any) is
      // still behind blocks of the old one, retune() marks that boundary.
      oscillator_step_ = std::polar(1.0f, static_cast<float>(-2 * kPi * channel_offset_hz(controls) / sr));
      if (station_change) {
        if (lo_change) {
          station_change_pending_ = true;  // applied by retune()
        } else {
          reset_squelch();
          reacquire_pilot();
        }
      }
    }
    if (channel_change) {
      // SSB offsets name the lower/upper passband edge, not its center.
      // Note: bandwidth_hz is unsigned; scale before negating.
      const double half_bw = 0.5 * static_cast<double>(controls.bandwidth_hz);
      const double angle = -2 * kPi * channel_offset_hz(controls) / sr;
      oscillator_step_ = std::polar(1.0f, static_cast<float>(angle));
      oscillator_ = {1, 0};
      oscillator_count_ = 0;
      station_change_pending_ = false;
      const bool wide = controls.bandwidth_hz >= 80000;
      first_factor_ = std::max(1u, std::min(wide ? 4u : 8u,
          static_cast<unsigned>(sr / (wide ? 550000.0 : 280000.0))));
      const double first_rate = sr / first_factor_;
      const double target = std::max(wide ? 48000.0 : 24000.0,
          std::max(static_cast<double>(controls.bandwidth_hz) * (wide ? 2.8 : 3.0),
                   controls.mode <= SDR_V3_WFM ? 50000.0 : 0.0));
      second_factor_ = std::max(1u, static_cast<unsigned>(first_rate / target));
      if_rate_ = first_rate / second_factor_;
      if (controls.mode == SDR_V3_WFM && controls.bandwidth_hz >= 120000 &&
          if_rate_ >= 128000) {
        if (!rds_) rds_ = std::make_unique<sdrcore::rds::Sink>();
        rds_->configure(static_cast<uint32_t>(std::lround(if_rate_)), rbds_);
        rds_->reset();
      } else {
        rds_.reset();
      }
      power_alpha_ = static_cast<float>(1 - std::exp(-1.0 / (if_rate_ * 0.02)));
      noise_alpha_ = static_cast<float>(1 - std::exp(-1.0 / (if_rate_ * 0.01)));
      noise_lp_alpha_ = static_cast<float>(std::exp(-2 * kPi *
          std::min(5000.0, controls.bandwidth_hz * 0.4) / if_rate_));
      am_alpha_ = static_cast<float>(1 - std::exp(-1.0 / (if_rate_ * 0.25)));
      deemphasis_alpha_ = static_cast<float>(1 - std::exp(-1.0 /
          (48000 * (controls.mode == SDR_V3_WFM ? 50e-6 : 75e-6))));
      metric_interval_ = std::max<size_t>(1, static_cast<size_t>(if_rate_ / 1000));
      if (controls.mode == SDR_V3_WFM) configure_pilot(if_rate_);
      const double sideband_offset = controls.mode == SDR_V3_USB ?
          half_bw : controls.mode == SDR_V3_LSB ? -half_bw : 0.0;
      sideband_step_ = std::polar(1.0f, static_cast<float>(2 * kPi * sideband_offset / if_rate_));
      cw_step_ = std::polar(1.0f, static_cast<float>(2 * kPi * kCwToneHz / if_rate_));
      first_.configure(sr, first_rate * 0.40, first_factor_, 127);
      second_.configure(first_rate, controls.bandwidth_hz * 0.5, second_factor_);
      // Anti-alias audio bandwidth for the shared polyphase audio resampler.
      // WFM stereo additionally applies its own explicit 15 kHz MPX lowpass
      // in process_pilot() ahead of this resampler (see configure_pilot()).
      audio_cutoff_ = controls.mode == SDR_V3_WFM ? 15000.0 :
          controls.mode == SDR_V3_NFM ? std::min(4500.0, controls.bandwidth_hz * 0.32) :
          std::min(8000.0, controls.bandwidth_hz * 0.48);
      audio_cutoff_ = std::min(audio_cutoff_, 18000.0);
      for (size_t phase = 0; phase < kPhases; ++phase) {
        const double fraction = static_cast<double>(phase) / kPhases;
        double sum = 0;
        for (size_t tap = 0; tap < kAudioTaps; ++tap) {
          const double x = static_cast<double>(tap) - 15.0 - fraction;
          const double fc = std::min(audio_cutoff_ / if_rate_, 0.45 * 48000.0 / if_rate_);
          const double sinc = x == 0 ? 2 * fc : std::sin(2 * kPi * fc * x) / (kPi * x);
          const double window = 0.5 - 0.5 * std::cos(2 * kPi * tap / (kAudioTaps - 1));
          audio_taps_[phase][tap] = static_cast<float>(sinc * window);
          sum += audio_taps_[phase][tap];
        }
        for (float& tap : audio_taps_[phase]) tap = static_cast<float>(tap / sum);
      }
      reset_channel();
    }
    // The audio tap's rate conversion depends only on if_rate_/mode, which
    // channel_change may have just redesigned above (even for a
    // bandwidth-only change, see receiver.h): keep the resampler current
    // whenever the channel is reshaped, independent of the decoder-reset
    // decision below (a bandwidth-only change intentionally skips that).
    if (channel_change && decoder_input_ == sdrcore::decoder::Input::audio)
      configure_audio_tap_branch();
    if (squelch_change && !channel_change) reset_squelch();
    if (display_change) fft_count_ = 0;
    if (decoder_ && (decoder_input_ == sdrcore::decoder::Input::baseband ||
                     decoder_input_ == sdrcore::decoder::Input::raw_iq) && decoder_tune_change) {
      configure_decoder_branch();
      decoder_->reset();
    }
    // Input::audio tap reset rule (receiver.h): tuned-frequency, mode or
    // sample-rate change resets the attached data decoder and clears tap
    // filter/resampler state; a bandwidth-only channel_change (handled by
    // configure_audio_tap_branch() above) and a same-tuned-frequency LO
    // recenter do not reach here.
    if (decoder_ && decoder_input_ == sdrcore::decoder::Input::audio &&
        (initial || audio_tuned_change || audio_mode_change || audio_rate_change)) {
      decoder_->set_tuning(tuned_frequency_hz(controls_), controls_.mode);
      decoder_->reset();
      audio_tap_resampler_.reset_state();
      audio_tap_deemphasis_.reset();
      audio_tap_limiter_.reset();
    }
    if (rds_ && rds_tune_change && !channel_change) rds_->reset();
  }

  // Preference only; separation additionally requires a locked 19 kHz pilot
  // (see process_if()). Re-arms pilot acquisition on every toggle so the
  // PLL/blend state always starts clean instead of resuming mid-transient.
  void set_wfm_stereo(bool enabled) override {
    if (enabled && !stereo_enabled_) {
      // The right chain was not fed while stereo was off: continue it from
      // the (mono) left chain instead of stale or zeroed state (no click).
      audio_history_r_ = audio_history_;
      deemphasis_r_ = deemphasis_;
      audio_dc_in_r_ = audio_dc_in_;
      audio_dc_out_r_ = audio_dc_out_;
    }
    stereo_enabled_ = enabled;
    reacquire_pilot();
  }

  void set_rds_rbds(bool enabled) override {
    if (rbds_ == enabled) return;
    rbds_ = enabled;
    if (rds_) rds_->configure(static_cast<uint32_t>(std::lround(if_rate_)), rbds_);
  }
  void set_rds_suspended(bool suspended) override {
    if (rds_suspended_ == suspended) return;
    rds_suspended_ = suspended;
    if (rds_) rds_->reset();
  }
  bool take_rds_group(std::string& json) override {
    return rds_ && rds_->take_group(json);
  }
  bool rds_synced() const override { return rds_ && rds_->synced(); }

  uint32_t set_decoder(sdrcore::decoder::Decoder* decoder,
                       sdrcore::decoder::Input input) override {
    // Same pointer AND same input: no-op (receiver.h). A pointer swap or an
    // input-type swap on the same pointer both count as a change below.
    if (decoder_ == decoder && decoder_input_ == input) return decoder_rate_hz();
    decoder_ = decoder;
    decoder_input_ = input;
    if (input == sdrcore::decoder::Input::audio) {
      decoder_rate_ = 0;  // baseband-only counter; audio uses kAudioTapRateHz.
      decoder_samples_.clear();
      if (decoder_) {
        configure_audio_tap_branch();
        decoder_->set_tuning(tuned_frequency_hz(controls_), controls_.mode);
        decoder_->reset();
      }
    } else {
      configure_decoder_branch();
      if (decoder_) decoder_->reset();
    }
    return decoder_rate_hz();
  }

  uint32_t decoder_rate_hz() const override {
    if (!decoder_) return 0;
    return decoder_input_ == sdrcore::decoder::Input::audio ? kAudioTapRateHz : decoder_rate_;
  }

  void reset() override {
    if (rds_) rds_->reset();
    rds_suspended_ = false;
    decoder_decimator_.reset();
    adsb_resampler_.reset();
    decoder_oscillator_ = {1, 0};
    if (decoder_ && decoder_input_ == sdrcore::decoder::Input::audio) {
      // Stream reset (receiver.h): set_tuning(current) then reset(), and
      // clear the tap's own filter/resampler state.
      decoder_->set_tuning(tuned_frequency_hz(controls_), controls_.mode);
      decoder_->reset();
      audio_tap_resampler_.reset_state();
      audio_tap_deemphasis_.reset();
      audio_tap_limiter_.reset();
    } else if (decoder_) {
      decoder_->reset();
    }
    first_.reset();
    second_.reset();
    oscillator_ = {1, 0};
    oscillator_count_ = 0;
    fft_count_ = 0;
    fft_since_row_ = 0;
    station_change_pending_ = false;
    reset_channel();
    reset_squelch();
  }

  void retune() override {
    if (rds_) rds_->reset();
    decoder_decimator_.reset();
    adsb_resampler_.reset();
    decoder_oscillator_ = {1, 0};
    if (decoder_ && decoder_input_ == sdrcore::decoder::Input::audio) {
      // retune() (receiver.h): set_tuning(current) then reset(), and clear
      // the tap's own filter/resampler state, unconditionally (unlike the
      // station_change_pending_ gate below, which only applies to the
      // squelch/pilot state of the baseband/voice chain).
      decoder_->set_tuning(tuned_frequency_hz(controls_), controls_.mode);
      decoder_->reset();
      audio_tap_resampler_.reset_state();
      audio_tap_deemphasis_.reset();
      audio_tap_limiter_.reset();
    } else if (decoder_) {
      decoder_->reset();
    }
    fft_count_ = 0;
    fft_since_row_ = 0;
    // Same station under a new LO (drag recenter): nothing else changes.
    if (!station_change_pending_) return;
    station_change_pending_ = false;
    reset_squelch();
    reacquire_pilot();
  }

  void process(const uint8_t* cu8, size_t bytes, ProcessResult& result) override {
    result.audio.clear();
    result.fft.clear();
    result.signal_db = -100;
    result.squelch_threshold_db = -100;
    result.squelch_open = false;
    result.squelch_ready = false;
    if (!configured_ || !cu8 || !controls_.sample_rate) return;
    const size_t pairs = bytes / 2;
    // One allocation at most per call, never in the per-sample loop.
    const size_t estimate = static_cast<size_t>(std::ceil(pairs * 48000.0 / controls_.sample_rate)) + 4;
    result.audio.reserve(2 * estimate);
    if (rds_ && !rds_suspended_) {
      rds_mpx_.clear();
      rds_mpx_.reserve(pairs / std::max(1u, first_factor_ * second_factor_) + 2);
    }
    const bool audio_tap_active = decoder_ && decoder_input_ == sdrcore::decoder::Input::audio;
    audio_tap_mode_accepted_ = audio_tap_active && decoder_->accepts_mode(controls_.mode);
    if (audio_tap_active) {
      audio_tap_samples_.clear();
      // Output count is bounded by pairs * (24000 / sample_rate) + a small
      // margin for phase slack; reserved once per call, never per sample.
      const size_t tap_estimate = static_cast<size_t>(
          std::ceil(pairs * static_cast<double>(kAudioTapRateHz) / controls_.sample_rate)) + 8;
      audio_tap_samples_.reserve(tap_estimate);
    }
    if (decoder_ && (decoder_input_ == sdrcore::decoder::Input::baseband ||
                     decoder_input_ == sdrcore::decoder::Input::raw_iq) && decoder_rate_)
      process_decoder(cu8, pairs);
    const size_t row_period = std::max<size_t>(fft_n_, (controls_.sample_rate + 29u) / 30u);
    for (size_t i = 0; i < pairs; ++i) {
      const Complex iq{(static_cast<float>(cu8[2 * i]) - 127.5f) / 127.5f,
                       (static_cast<float>(cu8[2 * i + 1]) - 127.5f) / 127.5f};
      fft_input_[fft_count_] = iq * window_[fft_count_];
      ++fft_count_;
      if (fft_count_ == fft_n_) {
        if (fft_since_row_ >= row_period && display_.width > 0 &&
            display_.width <= SDR_V3_MAX_FFT_WIDTH) {
          make_fft(result.fft);
          fft_since_row_ = 0;
        }
        fft_count_ = 0;
      }
      ++fft_since_row_;
      Complex stage;
      if (first_.put(iq * oscillator_, stage)) {
        Complex filtered;
        if (second_.put(stage, filtered)) process_if(filtered, result.audio);
      }
      oscillator_ *= oscillator_step_;
      if (++oscillator_count_ == 4096) {
        const float mag = std::abs(oscillator_);
        if (mag > 0) oscillator_ /= mag;
        oscillator_count_ = 0;
      }
    }
    if (rds_ && !rds_suspended_ && !rds_mpx_.empty())
      rds_->process(rds_mpx_.data(), rds_mpx_.size());
    if (audio_tap_active && !audio_tap_samples_.empty()) {
      decoder_->process(audio_tap_samples_.data(), audio_tap_samples_.size(), kAudioTapRateHz);
    }
    if (decoder_ && decoder_->provides_audio()) replace_with_decoder_audio(result.audio);
    result.signal_db = controls_.squelch == SDR_V3_SQUELCH_AUTO &&
        controls_.mode == SDR_V3_NFM ? metric_db_ :
        static_cast<float>(10 * std::log10(std::max(power_smooth_, kFloor)));
    result.squelch_threshold_db = threshold_db_;
    result.squelch_ready = controls_.squelch == SDR_V3_SQUELCH_OFF || squelch_ready_;
    result.squelch_open = controls_.squelch == SDR_V3_SQUELCH_OFF || squelch_open_;
  }

 private:
  // Voice decoders (DMR): the attached backend's 48 kHz mono PCM replaces the
  // demodulator output sample for sample, so the block keeps exactly the
  // frame count the normal chain produced and the AudioSink/AAudio clock is
  // undisturbed. Only the ordinary volume*volume / mute stage applies; the
  // squelch gate does not (OpenWebRX+ DMR: supportsSquelch() = False).
  // Underrun -> silence. No mixing with the analog demodulator output.
  void replace_with_decoder_audio(std::vector<float>& audio) {
    const size_t frames = audio.size() / 2;
    decoder_audio_.assign(frames, 0.0f);
    const size_t got = frames ? std::min(frames, decoder_->read_audio(decoder_audio_.data(), frames)) : 0;
    const float gain = controls_.muted ? 0.0f : controls_.volume * controls_.volume;
    for (size_t i = 0; i < frames; ++i) {
      const float pcm = i < got ? std::clamp(decoder_audio_[i] * gain, -1.0f, 1.0f) : 0.0f;
      audio[2 * i] = pcm;
      audio[2 * i + 1] = pcm;
    }
  }
  void process_decoder(const uint8_t* cu8, size_t pairs) {
    decoder_samples_.clear();
    decoder_samples_.reserve(2 * (pairs * static_cast<size_t>(decoder_rate_) /
        controls_.sample_rate + 2));
    for (size_t i = 0; i < pairs; ++i) {
      const Complex iq{(static_cast<float>(cu8[2*i]) - 127.5f) / 127.5f,
                       (static_cast<float>(cu8[2*i+1]) - 127.5f) / 127.5f};
      const Complex shifted = iq * decoder_oscillator_;
      auto append = [this](Complex value) {
        decoder_samples_.push_back(value.real());
        decoder_samples_.push_back(value.imag());
      };
      if (decoder_input_ == sdrcore::decoder::Input::raw_iq) {
        if (controls_.sample_rate == 2400000) append(shifted);
        else adsb_resampler_.put(shifted, append);
      } else {
        Complex filtered;
        if (decoder_decimator_.put(shifted, filtered)) append(filtered);
      }
      decoder_oscillator_ *= decoder_step_;
      if ((i & 4095u) == 4095u) {
        const float mag = std::abs(decoder_oscillator_);
        if (mag > 0) decoder_oscillator_ /= mag;
      }
    }
    if (!decoder_samples_.empty())
      decoder_->process(decoder_samples_.data(), decoder_samples_.size()/2, decoder_rate_);
  }
  void configure_decoder_branch() {
    decoder_rate_ = 0;
    decoder_samples_.clear();
    decoder_decimator_.reset();
    adsb_resampler_.reset();
    if (!decoder_) return;
    if (decoder_input_ == sdrcore::decoder::Input::raw_iq) {
      // The +/-1.2 MHz decoder window must fit inside the user's tuned
      // source bandwidth. A low rate or an offset near an edge is not ready.
      const int64_t half = static_cast<int64_t>(controls_.sample_rate) / 2;
      if (controls_.sample_rate < 2400000 ||
          std::abs(static_cast<int64_t>(controls_.vfo_offset_hz)) + 1200000 > half)
        return;
      decoder_rate_ = 2400000;
      if (controls_.sample_rate != decoder_rate_)
        adsb_resampler_.configure(controls_.sample_rate);
      decoder_step_ = std::polar(1.0f, static_cast<float>(
          -2 * kPi * controls_.vfo_offset_hz / controls_.sample_rate));
      decoder_oscillator_ = {1, 0};
      return;
    }
    if (controls_.sample_rate < 200000) return;
    // Choose the integer ratio nearest rtl_433's 250 kS/s reference rate.
    const unsigned factor = std::max(1u, (controls_.sample_rate + 125000u) / 250000u);
    const uint32_t rate = controls_.sample_rate / factor;
    if (rate < 200000 || rate > 300000) return;
    decoder_rate_ = rate;
    decoder_decimator_.configure(controls_.sample_rate, rate * 0.40, factor);
    decoder_step_ = std::polar(1.0f, static_cast<float>(
        -2 * kPi * controls_.vfo_offset_hz / controls_.sample_rate));
    decoder_oscillator_ = {1, 0};
  }
  // (Re)derives the tap resampler for the current if_rate_/mode. Called on
  // every channel_change (including a bandwidth-only change, per
  // receiver.h -- unlike configure_decoder_branch() above, this must NOT
  // reset the attached decoder itself; the caller handles that separately).
  // Cutoff differs by mode: see kAudioTapCutoffNfmHz/kAudioTapCutoffSsbHz.
  void configure_audio_tap_branch() {
    if (decoder_input_ != sdrcore::decoder::Input::audio) return;
    const double cutoff = controls_.mode == SDR_V3_NFM ? kAudioTapCutoffNfmHz : kAudioTapCutoffSsbHz;
    audio_tap_resampler_.configure(if_rate_, kAudioTapRateHz, cutoff);
    audio_tap_deemphasis_.reset();
    audio_tap_limiter_.reset();
  }
  static constexpr size_t kAudioTaps = 32, kPhases = 64;
  // NCO frequency: SSB offsets name the lower/upper passband edge.
  static double channel_offset_hz(const SdrV3Controls& c) {
    const double half_bw = 0.5 * static_cast<double>(c.bandwidth_hz);
    double offset = static_cast<double>(c.vfo_offset_hz);
    if (c.mode == SDR_V3_USB) offset += half_bw;
    if (c.mode == SDR_V3_LSB) offset -= half_bw;
    return offset;
  }
  void reset_squelch() {
    squelch_ready_ = false;
    squelch_open_ = false;
    threshold_db_ = -100;
    metric_db_ = -100;
    power_smooth_ = 0;
    noise_smooth_ = 0;
    noise_lp_ = 0;
    floor_db_ = -100;
    floor_segments_.fill(-100);
    floor_count_ = floor_index_ = settle_count_ = segment_count_ = open_count_ = hang_count_ = 0;
    metric_count_ = 0;
    segment_power_ = 0;
    // Without squelch the gate is always open; ramping it from zero after
    // every tune would be an audible dip.
    gate_ = controls_.squelch == SDR_V3_SQUELCH_OFF ? 1.0f : 0.0f;
  }
  void reset_channel() {
    previous_ = {};
    sideband_ = cw_ = {1, 0};
    previous_valid_ = false;
    am_dc_ = 0;
    agc_envelope_ = 0.15f;
    audio_dc_in_ = audio_dc_out_ = deemphasis_ = 0;
    audio_history_.fill(0);
    audio_index_ = 0;
    audio_input_count_ = 0;
    next_audio_time_ = 0;
    reset_pilot();
    reset_squelch();
  }
  // New station: re-lock the 19 kHz pilot from scratch (mono until locked)
  // but keep the right channel's resampler/deemphasis/DC state running, so
  // the stereo->mono collapse does not add a hole or click.
  void reacquire_pilot() {
    nominal_angle_ = 0;
    tracked_phase_ = 0;
    tracked_freq_ = 0;
    pilot_bb1_ = pilot_bb2_ = {0, 0};
    pilot_mag_smooth_ = 0;
    pilot_locked_ = false;
    stereo_blend_ = 0;
    lmr_lp1_ = lmr_lp2_ = 0;
  }
  // Re-arms the 19 kHz pilot PLL and the stereo-only filter/deemphasis state.
  // Called on every retune/mode change, and on every set_wfm_stereo() toggle
  // so a weak or noisy pilot is always reacquired from a clean start rather
  // than resuming a possibly stale lock.
  void reset_pilot() {
    nominal_angle_ = 0;
    tracked_phase_ = 0;
    tracked_freq_ = 0;
    pilot_bb1_ = pilot_bb2_ = {0, 0};
    pilot_mag_smooth_ = 0;
    pilot_locked_ = false;
    stereo_blend_ = 0;
    lpr_lp1_ = lpr_lp2_ = 0;
    lmr_lp1_ = lmr_lp2_ = 0;
    audio_history_r_.fill(0);
    deemphasis_r_ = 0;
    audio_dc_in_r_ = audio_dc_out_r_ = 0;
  }
  // (Re)derives the pilot tracking-loop gains, lowpass alphas and the 19 kHz
  // search range for the current if_rate_. Follows SDR++'s structure (core/
  // src/dsp/demod/broadcast_fm.h, core/src/dsp/loop/pll.h,
  // phase_control_loop.h): a frequency-selective filter first isolates the
  // pilot near 19 kHz, then a phase-locked loop tracks only the slow
  // residual drift within that narrow band -- NOT a single loop that both
  // down-converts and tracks: feeding the loop's own corrected phase back
  // into the down-mix adds enough loop delay (the 300 Hz filter plus
  // control feedback in series) that a loop bandwidth wide enough to pull
  // in from zero produces limit-cycle frequency slips instead of a stable
  // lock (verified empirically against this file's synthetic weak-pilot
  // test case).
  // SDR++ gets the same separation using a dedicated bandpass FIR ahead of
  // its PLL; this implementation reaches the same two-stage structure with
  // a fixed-frequency down-mix + cascaded lowpass (the filter) feeding a
  // narrow-bandwidth tracker (the loop) instead of a separate FIR stage.
  void configure_pilot(double if_rate) {
    constexpr double kPilotHz = 19000.0;
    // Fixed down-mix frequency: never adjusted by the tracker, so the
    // cascaded lowpass below sees a slowly rotating (not actively
    // corrected) baseband signal and cannot destabilize the tracking loop.
    nominal_step_ = static_cast<float>(2 * kPi * kPilotHz / if_rate);
    // ~300 Hz one-pole lowpass, cascaded twice (~-72 dB far from DC),
    // isolating the down-mixed pilot from the much stronger 38 kHz L-R
    // subcarrier, which after mix-down by the fixed 19 kHz NCO lands at
    // +-19 kHz baseband -- comfortably outside this passband even for a
    // weak (near-threshold) real pilot.
    pilot_bb_alpha_ = static_cast<float>(1 - std::exp(-2 * kPi * 300.0 / if_rate));
    // Narrow tracking loop: broadcast FM pilots stay within +-250 Hz of
    // 19 kHz (the same capture range SDR++ uses), so a loop bandwidth well
    // under that residual range stays stable while still following slow
    // drift; critically damped per SDR++'s
    // dsp::loop::PhaseControlLoop::criticallyDamped.
    constexpr double kLoopBandwidthHz = 50.0;
    const double normalized_bw = kLoopBandwidthHz / if_rate;
    const double damping = std::sqrt(2.0) / 2.0;
    const double denom = 1.0 + 2.0 * damping * normalized_bw + normalized_bw * normalized_bw;
    tracked_alpha_ = static_cast<float>(4.0 * damping * normalized_bw / denom);
    tracked_beta_ = static_cast<float>(4.0 * normalized_bw * normalized_bw / denom);
    tracked_max_freq_ = static_cast<float>(2 * kPi * 250.0 / if_rate);
    // Two cascaded one-pole 15 kHz stages for both L+R and L-R (~12 dB/oct;
    // steeper than the shared mono/audio polyphase anti-alias filter so the
    // 19 kHz pilot and 38 kHz subcarrier do not bleed into program audio).
    mpx_cutoff_alpha_ = static_cast<float>(1 - std::exp(-2 * kPi * 15000.0 / if_rate));
    // ~20 ms pilot-amplitude envelope, matching power_alpha_'s time constant.
    pilot_envelope_alpha_ = static_cast<float>(1 - std::exp(-1.0 / (if_rate * 0.02)));
    // Full mono<->stereo ramp over ~200 ms: long enough to avoid audible
    // pumping on a fading pilot, short enough to feel responsive on lock.
    blend_step_ = static_cast<float>(1.0 / (0.2 * if_rate));
    reset_pilot();
  }
  // Coherent pilot/MPX stereo recovery for one discriminator (MPX) sample.
  // Produces the 15 kHz-lowpassed L+R and L-R components; the caller blends
  // them by stereo_blend_ before feeding the existing mono resampler/
  // deemphasis chain for L, and a parallel chain (audio_history_r_,
  // deemphasis_r_) for R. See SDR++ core/src/dsp/demod/broadcast_fm.h for
  // the reference pilot-PLL/doubled-phase architecture this follows, and
  // configure_pilot() above for why the down-mix and the phase tracker are
  // deliberately two separate stages instead of one combined loop.
  void process_pilot(float mpx, float& lpr_out, float& lmr_out) {
    // Step 1 (fixed-frequency filter): mix down by the uncorrected nominal
    // 19 kHz NCO and lowpass; a perfectly on-frequency pilot settles to a
    // constant phasor, while a real pilot's small frequency error appears
    // as slow residual rotation -- never fast enough to destabilize the
    // narrow tracker in step 2.
    const Complex mix = Complex(mpx, 0.0f) * std::polar(1.0f, -nominal_angle_);
    pilot_bb1_ += pilot_bb_alpha_ * (mix - pilot_bb1_);
    pilot_bb2_ += pilot_bb_alpha_ * (pilot_bb1_ - pilot_bb2_);
    nominal_angle_ += nominal_step_;
    if (nominal_angle_ > static_cast<float>(kPi)) nominal_angle_ -= static_cast<float>(2 * kPi);

    // Step 2 (narrow tracking loop): follow only the slow residual phase of
    // the already-filtered baseband signal from step 1.
    float error = std::atan2(pilot_bb2_.imag(), pilot_bb2_.real()) - tracked_phase_;
    if (error > static_cast<float>(kPi)) error -= static_cast<float>(2 * kPi);
    else if (error < -static_cast<float>(kPi)) error += static_cast<float>(2 * kPi);
    tracked_freq_ = std::clamp(tracked_freq_ + tracked_beta_ * error, -tracked_max_freq_, tracked_max_freq_);
    tracked_phase_ += tracked_freq_ + tracked_alpha_ * error;
    if (tracked_phase_ > static_cast<float>(kPi)) tracked_phase_ -= static_cast<float>(2 * kPi);
    else if (tracked_phase_ < -static_cast<float>(kPi)) tracked_phase_ += static_cast<float>(2 * kPi);
    // Full pilot phase on the original MPX = the uncorrected NCO's angle
    // (always advancing at exactly 19 kHz) plus the tracked residual.
    const float pilot_angle = nominal_angle_ + tracked_phase_;

    // Lock/fallback: a smoothed pilot amplitude with hysteresis drives a
    // slow crossfade so a weak or fading pilot degrades to mono instead of
    // snapping or exposing raw, noisy L-R separation.
    const float pilot_amplitude = 2.0f * std::abs(pilot_bb2_);
    pilot_mag_smooth_ += pilot_envelope_alpha_ * (pilot_amplitude - pilot_mag_smooth_);
    const float on_threshold = pilot_locked_ ? kPilotLockOffAmplitude : kPilotLockOnAmplitude;
    pilot_locked_ = pilot_mag_smooth_ > on_threshold;
    const float blend_target = pilot_locked_ ? 1.0f : 0.0f;
    stereo_blend_ = std::clamp(stereo_blend_ +
        std::clamp(blend_target - stereo_blend_, -blend_step_, blend_step_), 0.0f, 1.0f);

    // L+R: explicit 15 kHz lowpass of the full MPX (removes pilot/subcarrier
    // before the audio resampler, independent of that resampler's own
    // anti-alias cutoff).
    lpr_lp1_ += mpx_cutoff_alpha_ * (mpx - lpr_lp1_);
    lpr_lp2_ += mpx_cutoff_alpha_ * (lpr_lp1_ - lpr_lp2_);
    lpr_out = lpr_lp2_;

    // L-R: the 38 kHz DSB-SC subcarrier is phase-locked at exactly twice the
    // pilot frequency by the transmitter; cos(2*pilot_angle) is therefore a
    // coherent demodulation reference once the tracker has settled. The
    // factor of 2 undoes the cos^2 self-mixing loss (cos^2(x) = (1+cos2x)/2).
    const float carrier38 = std::cos(2.0f * pilot_angle);
    const float raw_lmr = 2.0f * mpx * carrier38;
    lmr_lp1_ += mpx_cutoff_alpha_ * (raw_lmr - lmr_lp1_);
    lmr_lp2_ += mpx_cutoff_alpha_ * (lmr_lp1_ - lmr_lp2_);
    lmr_out = lmr_lp2_;
  }
  void make_fft(std::vector<float>& row) {
    std::copy(fft_input_.begin(), fft_input_.begin() + static_cast<std::ptrdiff_t>(fft_n_),
              fft_work_.begin());
    fft(fft_work_.data(), fft_n_);
    row.assign(display_.width, -120.0f);
    const double low = static_cast<double>(display_.view_offset_hz) - display_.view_bandwidth_hz * 0.5;
    const double bandwidth = display_.view_bandwidth_hz;
    const double rate = controls_.sample_rate;
    const float inv_n = 1.0f / static_cast<float>(fft_n_);
    for (size_t i = 0; i < fft_n_; ++i) {
      const double offset = (static_cast<double>(i) / fft_n_ - 0.5) * rate;
      const double position = (offset - low) / bandwidth;
      if (position < 0 || position >= 1) continue;
      const size_t column = std::min<size_t>(display_.width - 1,
          static_cast<size_t>(position * display_.width));
      // Dart IQFrontEnd.powerSpectrum: 10*log10(|X/N|^2), floored at 1e-20.
      const float power = std::norm(fft_work_[(i + fft_n_ / 2) & (fft_n_ - 1)] * inv_n);
      row[column] = std::max(row[column], 10.0f * std::log10(std::max(power, 1.0e-20f)));
    }
  }
  void set_fft_size(size_t n) {
    // SDR++ Nuttall window (window/nuttall.h), same as the Dart IQFrontEnd default.
    fft_n_ = n;
    const double coefs[4] = {0.355768, 0.487396, 0.144232, 0.012604};
    for (size_t i = 0; i < n; ++i) {
      double w = 0, sign = 1;
      for (size_t k = 0; k < 4; ++k, sign = -sign)
        w += sign * coefs[k] * std::cos(static_cast<double>(k) * 2 * kPi * i / n);
      window_[i] = static_cast<float>(w);
    }
    fft_count_ = 0;
  }
  void update_squelch(float power, float discriminator) {
    power_smooth_ += power_alpha_ * (power - power_smooth_);
    if (controls_.squelch == SDR_V3_SQUELCH_OFF) return;
    ++settle_count_;
    if (controls_.squelch == SDR_V3_SQUELCH_AUTO && controls_.mode == SDR_V3_NFM) {
      noise_lp_ = noise_lp_alpha_ * noise_lp_ + (1 - noise_lp_alpha_) * discriminator;
      noise_smooth_ += noise_alpha_ * (std::abs(discriminator - noise_lp_) - noise_smooth_);
    } else if (controls_.squelch == SDR_V3_SQUELCH_AUTO) {
      segment_power_ += power;
      if (++segment_count_ >= static_cast<size_t>(if_rate_ * 0.05)) {
        if (settle_count_ >= static_cast<size_t>(if_rate_ * 0.5) &&
            (!squelch_open_ || open_count_ > static_cast<size_t>(if_rate_ * 8))) {
          floor_segments_[floor_index_] = static_cast<float>(10 * std::log10(
              std::max(segment_power_ / segment_count_, static_cast<double>(kFloor))));
          floor_index_ = (floor_index_ + 1) % floor_segments_.size();
          floor_count_ = std::min(floor_count_ + 1, floor_segments_.size());
          if (floor_count_ >= 4) {
            auto sorted = floor_segments_;
            std::sort(sorted.begin(), sorted.begin() + static_cast<std::ptrdiff_t>(floor_count_));
            floor_db_ = sorted[(floor_count_ - 1) / 5];
            squelch_ready_ = true;
          }
        }
        segment_power_ = 0;
        segment_count_ = 0;
      }
    }
    if (++metric_count_ < metric_interval_) return;
    metric_count_ = 0;
    if (controls_.squelch == SDR_V3_SQUELCH_MANUAL) {
      squelch_ready_ = settle_count_ >= static_cast<size_t>(if_rate_ * 0.02);
      threshold_db_ = controls_.squelch_level_db;
    } else if (controls_.mode == SDR_V3_NFM) {
      // The discriminator noise reference scales with channel occupancy.
      const double occupancy = std::min(1.0, static_cast<double>(controls_.bandwidth_hz) / if_rate_);
      const float reference = static_cast<float>(1.3 * occupancy);
      const float quieting = static_cast<float>(20 * std::log10(
          std::max(reference, 0.001f) / std::max(noise_smooth_, 0.001f)));
      metric_db_ = quieting;
      threshold_db_ = 6 + controls_.auto_squelch_offset_db;
      squelch_ready_ = settle_count_ >= static_cast<size_t>(if_rate_ * 0.03);
    } else {
      // A fixed-size 2 s, 50 ms low-percentile noise-floor tracker.
      metric_db_ = static_cast<float>(10 * std::log10(std::max(power_smooth_, kFloor)));
      threshold_db_ = floor_db_ + 6 + controls_.auto_squelch_offset_db;
    }
    if (controls_.squelch == SDR_V3_SQUELCH_MANUAL)
      metric_db_ = static_cast<float>(10 * std::log10(std::max(power_smooth_, kFloor)));
    bool wants_open = squelch_ready_ && metric_db_ >= threshold_db_ +
        (squelch_open_ ? 0.0f : 2.5f);
    if (squelch_open_ && !wants_open) {
      hang_count_ += metric_interval_;
      if (hang_count_ < static_cast<size_t>(if_rate_ * 0.25)) wants_open = true;
    } else if (wants_open) {
      hang_count_ = 0;
    }
    squelch_open_ = wants_open;
    open_count_ = wants_open ? open_count_ + metric_interval_ : 0;
  }
  void process_if(Complex sample, std::vector<float>& audio) {
    const float power = std::norm(sample);
    float discriminator = 0;
    if (previous_valid_ && (controls_.mode == SDR_V3_NFM || controls_.mode == SDR_V3_WFM)) {
      const Complex difference = sample * std::conj(previous_);
      discriminator = std::atan2(difference.imag(), difference.real());
    }
    previous_ = sample;
    previous_valid_ = true;
    update_squelch(power, discriminator);
    if (controls_.mode == SDR_V3_USB || controls_.mode == SDR_V3_LSB) {
      sample *= sideband_;
      sideband_ *= sideband_step_;
    }
    float value = 0;
    switch (controls_.mode) {
      case SDR_V3_NFM:
      case SDR_V3_WFM:
        // SDR++ FM: Quadrature deviation = bandwidth / 2 (fm.h); WFM 75 kHz.
        value = discriminator * static_cast<float>(if_rate_ /
            (2 * kPi * (controls_.mode == SDR_V3_WFM ? 75000.0 :
                            std::max(250.0, controls_.bandwidth_hz * 0.5))));
        break;
      case SDR_V3_AM: {
        const float envelope = std::abs(sample);
        am_dc_ += am_alpha_ * (envelope - am_dc_);
        value = (envelope - am_dc_) * 2;
        break;
      }
      case SDR_V3_CW: {
        value = 2 * (sample * cw_).real();
        cw_ *= cw_step_;
        break;
      }
      case SDR_V3_LSB:
      default: // DSB, USB and RAW (real component) use the same real projection.
        value = 2 * sample.real();
        break;
    }
    if (decoder_ && decoder_input_ == sdrcore::decoder::Input::audio && audio_tap_mode_accepted_ &&
        (controls_.squelch == SDR_V3_SQUELCH_OFF || squelch_open_)) {
      // Tap point: the demodulated mono sample before the 48 kHz resampler,
      // deemphasis, DC block, AGC, squelch gate, volume and mute (receiver.h).
      // USB/LSB feed the sideband-shifted sample's real part (csdr
      // RealPart); NFM feeds the raw discriminator rescaled to csdr's
      // FmDemod convention (2*f/24000) and amplitude-limited like
      // csdr-plus's NFm chain (FmDemod -> Limit() -> NfmDeemphasis(24000))
      // before the same rate conversion. Other modes are outside this
      // receiver's documented audio-tap contract even if a (hypothetical)
      // decoder's accepts_mode() claimed them.
      float tap_input = 0;
      bool tap_supported = true;
      if (controls_.mode == SDR_V3_NFM) {
        tap_input = std::clamp(discriminator * static_cast<float>(if_rate_ / (kPi * kAudioTapRateHz)),
                               -kAudioTapLimitMaxAmplitude, kAudioTapLimitMaxAmplitude);
      } else if (controls_.mode == SDR_V3_USB || controls_.mode == SDR_V3_LSB) {
        tap_input = sample.real();
      } else {
        tap_supported = false;
      }
      if (tap_supported) {
        const size_t before = audio_tap_samples_.size();
        audio_tap_resampler_.put(tap_input, audio_tap_samples_);
        if (controls_.mode == SDR_V3_NFM) {
          for (size_t k = before; k < audio_tap_samples_.size(); ++k) {
            audio_tap_samples_[k] = audio_tap_deemphasis_.put(audio_tap_samples_[k]);
            audio_tap_samples_[k] = audio_tap_limiter_.put(audio_tap_samples_[k]);
          }
        }
      }
    }
    if ((audio_input_count_ & 4095) == 0) {
      const float sideband_mag = std::abs(sideband_), cw_mag = std::abs(cw_);
      if (sideband_mag > 0) sideband_ /= sideband_mag;
      if (cw_mag > 0) cw_ /= cw_mag;
    }
    audio_history_[audio_index_] = value;
    if (rds_ && !rds_suspended_ && controls_.mode == SDR_V3_WFM)
      rds_mpx_.push_back(value);  // Before stereo/audio filtering and deemphasis.
    if (controls_.mode == SDR_V3_WFM && stereo_enabled_) {
      float lpr = value, lmr = 0.0f;
      process_pilot(value, lpr, lmr);
      audio_history_[audio_index_] = lpr + stereo_blend_ * lmr;
      audio_history_r_[audio_index_] = lpr - stereo_blend_ * lmr;
    }
    audio_index_ = (audio_index_ + 1) & (kAudioTaps - 1);
    ++audio_input_count_;
    const double spacing = if_rate_ / 48000.0;
    // Only WFM with an enabled preference and audible blend carries a second
    // channel history; all other modes resample a single mono buffer and
    // mirror it to both outputs exactly as before (audio_history_r_ holds
    // stale/zero data and must not be read in that case).
    const bool stereo_active = controls_.mode == SDR_V3_WFM && stereo_enabled_;
    while (next_audio_time_ <= static_cast<double>(audio_input_count_ - 1)) {
      const double lag = static_cast<double>(audio_input_count_ - 1) - next_audio_time_;
      if (lag < 0 || lag >= 1) break;
      const size_t phase = std::min<size_t>(kPhases - 1,
          static_cast<size_t>(lag * kPhases));
      float out = 0, out_r = 0;
      size_t index = (audio_index_ - 1) & (kAudioTaps - 1);
      for (float tap : audio_taps_[phase]) {
        out += audio_history_[index] * tap;
        if (stereo_active) out_r += audio_history_r_[index] * tap;
        index = (index - 1) & (kAudioTaps - 1);
      }
      next_audio_time_ += spacing;
      // FM deemphasis and a gentle DC/high-pass for all modes.
      if (controls_.mode == SDR_V3_WFM || controls_.mode == SDR_V3_NFM) {
        deemphasis_ += deemphasis_alpha_ * (out - deemphasis_);
        out = deemphasis_;
        if (stereo_active) {
          deemphasis_r_ += deemphasis_alpha_ * (out_r - deemphasis_r_);
          out_r = deemphasis_r_;
        }
      }
      const float hp = out - audio_dc_in_ + 0.995f * audio_dc_out_;
      audio_dc_in_ = out;
      audio_dc_out_ = hp;
      float hp_r = hp;
      if (stereo_active) {
        hp_r = out_r - audio_dc_in_r_ + 0.995f * audio_dc_out_r_;
        audio_dc_in_r_ = out_r;
        audio_dc_out_r_ = hp_r;
      }
      float leveled = hp, leveled_r = hp_r;
      if (controls_.mode != SDR_V3_NFM && controls_.mode != SDR_V3_WFM &&
          controls_.mode != SDR_V3_RAW) {
        // Peak-following AGC to the SDR++ set point (1.0), fast attack/slow decay.
        const float alpha = std::abs(hp) > agc_envelope_ ? 0.0021f : 0.000042f;
        agc_envelope_ += alpha * (std::abs(hp) - agc_envelope_);
        leveled *= std::clamp(kAgcSetPoint / std::max(agc_envelope_, 1.0e-5f), 0.01f, 1.0e4f);
      }
      const float target = controls_.squelch == SDR_V3_SQUELCH_OFF || squelch_open_ ? 1.0f : 0.0f;
      gate_ += std::clamp(target - gate_, -1.0f / 240, 1.0f / 240);
      const float gain = controls_.muted ? 0.0f : controls_.volume * controls_.volume * gate_;
      const float pcm = std::clamp(leveled * gain, -1.0f, 1.0f);
      if (stereo_active) {
        const float pcm_r = std::clamp(leveled_r * gain, -1.0f, 1.0f);
        audio.push_back(pcm);
        audio.push_back(pcm_r);
      } else {
        audio.push_back(pcm);
        audio.push_back(pcm);
      }
    }
  }
  SdrV3Controls controls_{};
  SdrV3Display display_{};
  bool configured_ = false;
  // An LO change moved the tuned frequency to another channel; retune()
  // (first block of the new LO) resets squelch learning and pilot lock.
  bool station_change_pending_ = false;
  ComplexDecimator first_, second_;
  sdrcore::decoder::Decoder* decoder_ = nullptr;
  // The requested Input kind of decoder_ (set_decoder()'s second argument);
  // selects which of the two independent branches below is scheduled.
  sdrcore::decoder::Input decoder_input_ = sdrcore::decoder::Input::baseband;
  std::unique_ptr<sdrcore::rds::Sink> rds_;
  std::vector<float> rds_mpx_;
  bool rbds_ = false;
  bool rds_suspended_ = false;
  ComplexDecimator decoder_decimator_;
  AdsbResampler adsb_resampler_;
  uint32_t decoder_rate_ = 0;
  Complex decoder_oscillator_{1, 0}, decoder_step_{1, 0};
  std::vector<float> decoder_samples_;
  std::vector<float> decoder_audio_;  // replace_with_decoder_audio() scratch
  // Input::audio tap state (see receiver.h, process_if()). Independent of
  // the baseband branch above and of the 48 kHz voice chain below:
  // RealResampler/NfmTapDeemphasis instances with their own ring buffers.
  RealResampler audio_tap_resampler_;
  NfmTapDeemphasis audio_tap_deemphasis_;
  ToneEnvelopeLimiter audio_tap_limiter_;
  std::vector<float> audio_tap_samples_;
  // Cached once per process() call (decoder_->accepts_mode() may not be
  // cheap/pure); avoids calling it per-sample in the hot loop.
  bool audio_tap_mode_accepted_ = false;
  unsigned first_factor_ = 1, second_factor_ = 1;
  double if_rate_ = 48000, audio_cutoff_ = 15000;
  Complex oscillator_{1, 0}, oscillator_step_{1, 0}, previous_{};
  Complex sideband_{1, 0}, sideband_step_{1, 0}, cw_{1, 0}, cw_step_{1, 0};
  unsigned oscillator_count_ = 0;
  bool previous_valid_ = false;
  // Sized once to kMaxFft in the constructor; never reallocated while streaming.
  std::vector<Complex> fft_input_, fft_work_;
  std::vector<float> window_;
  size_t fft_n_ = kMaxFft, fft_count_ = 0, fft_since_row_ = 0;
  std::array<std::array<float, kAudioTaps>, kPhases> audio_taps_{};
  std::array<float, kAudioTaps> audio_history_{};
  size_t audio_index_ = 0, audio_input_count_ = 0;
  double next_audio_time_ = 0;
  float am_dc_ = 0, audio_dc_in_ = 0, audio_dc_out_ = 0, deemphasis_ = 0;
  float agc_envelope_ = 0.15f;
  // WFM stereo (MPX pilot/subcarrier decode): preference set by
  // set_wfm_stereo(), separate from whether a pilot is actually locked.
  // Right-channel resampler history/deemphasis/DC-block state mirrors the
  // existing mono (left) members above; both are always filled for WFM so a
  // mid-stream toggle cannot read stale data, but only read when
  // stereo_active (process_if()) to keep non-WFM/disabled-stereo paths
  // byte-for-byte identical to the pre-stereo mono implementation.
  bool stereo_enabled_ = false;
  std::array<float, kAudioTaps> audio_history_r_{};
  float audio_dc_in_r_ = 0, audio_dc_out_r_ = 0, deemphasis_r_ = 0;
  // Pilot tracking state: a fixed 19 kHz down-mix NCO (nominal_angle_,
  // nominal_step_) feeds the cascaded lowpass (pilot_bb1_/pilot_bb2_); a
  // separate narrow-bandwidth tracker (tracked_phase_/tracked_freq_) then
  // follows only the slow residual drift. See configure_pilot().
  float nominal_angle_ = 0, nominal_step_ = 0;
  float tracked_phase_ = 0, tracked_freq_ = 0;
  float tracked_alpha_ = 0, tracked_beta_ = 0, tracked_max_freq_ = 0;
  Complex pilot_bb1_{0, 0}, pilot_bb2_{0, 0};
  float pilot_bb_alpha_ = 0;
  float pilot_mag_smooth_ = 0;
  bool pilot_locked_ = false;
  float pilot_envelope_alpha_ = 0;
  float stereo_blend_ = 0, blend_step_ = 0;
  float mpx_cutoff_alpha_ = 0;
  float lpr_lp1_ = 0, lpr_lp2_ = 0, lmr_lp1_ = 0, lmr_lp2_ = 0;
  float power_smooth_ = 0, noise_lp_ = 0, noise_smooth_ = 0;
  float power_alpha_ = 0, noise_alpha_ = 0, noise_lp_alpha_ = 0;
  float am_alpha_ = 0, deemphasis_alpha_ = 0;
  float metric_db_ = -100, threshold_db_ = -100, floor_db_ = -100, gate_ = 0;
  bool squelch_ready_ = false, squelch_open_ = false;
  std::array<float, 40> floor_segments_{};
  size_t floor_count_ = 0, floor_index_ = 0, settle_count_ = 0;
  size_t segment_count_ = 0, open_count_ = 0, hang_count_ = 0;
  size_t metric_count_ = 0, metric_interval_ = 1;
  double segment_power_ = 0;
};
}  // namespace

std::unique_ptr<Receiver> make_receiver() {
  return std::make_unique<ReceiverImpl>();
}
}  // namespace dsp
}  // namespace sdrcore

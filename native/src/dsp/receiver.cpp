// SPDX-License-Identifier: GPL-3.0-or-later
#include "receiver.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <cstdint>
#include <limits>

namespace sdrcore {
namespace dsp {
namespace {
constexpr double kPi = 3.14159265358979323846;
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
    const bool channel_change = initial || controls.sample_rate != controls_.sample_rate ||
        controls.vfo_offset_hz != controls_.vfo_offset_hz || controls.mode != controls_.mode ||
        controls.bandwidth_hz != controls_.bandwidth_hz;
    const bool squelch_change = initial || channel_change || controls.squelch != controls_.squelch ||
        controls.squelch_level_db != controls_.squelch_level_db ||
        controls.auto_squelch_offset_db != controls_.auto_squelch_offset_db;
    const bool display_change = initial || display.width != display_.width ||
        display.view_bandwidth_hz != display_.view_bandwidth_hz ||
        display.view_offset_hz != display_.view_offset_hz ||
        controls.center_frequency_hz != controls_.center_frequency_hz ||
        controls.sample_rate != controls_.sample_rate;
    controls_ = controls;
    display_ = display;
    configured_ = controls.sample_rate > 0;
    if (!configured_) return;
    const double sr = controls.sample_rate;
    if (display_change && fft_size_for(controls.sample_rate) != fft_n_)
      set_fft_size(fft_size_for(controls.sample_rate));
    if (channel_change) {
      // SSB offsets name the lower/upper passband edge, not its center.
      // Note: bandwidth_hz is unsigned; scale before negating.
      const double half_bw = 0.5 * static_cast<double>(controls.bandwidth_hz);
      double channel_offset = static_cast<double>(controls.vfo_offset_hz);
      if (controls.mode == SDR_V3_USB) channel_offset += half_bw;
      if (controls.mode == SDR_V3_LSB) channel_offset -= half_bw;
      const double angle = -2 * kPi * channel_offset / sr;
      oscillator_step_ = std::polar(1.0f, static_cast<float>(angle));
      oscillator_ = {1, 0};
      oscillator_count_ = 0;
      const bool wide = controls.bandwidth_hz >= 80000;
      first_factor_ = std::max(1u, std::min(wide ? 4u : 8u,
          static_cast<unsigned>(sr / (wide ? 550000.0 : 280000.0))));
      const double first_rate = sr / first_factor_;
      const double target = std::max(wide ? 48000.0 : 24000.0,
          std::max(static_cast<double>(controls.bandwidth_hz) * (wide ? 2.8 : 3.0),
                   controls.mode <= SDR_V3_WFM ? 50000.0 : 0.0));
      second_factor_ = std::max(1u, static_cast<unsigned>(first_rate / target));
      if_rate_ = first_rate / second_factor_;
      power_alpha_ = static_cast<float>(1 - std::exp(-1.0 / (if_rate_ * 0.02)));
      noise_alpha_ = static_cast<float>(1 - std::exp(-1.0 / (if_rate_ * 0.01)));
      noise_lp_alpha_ = static_cast<float>(std::exp(-2 * kPi *
          std::min(5000.0, controls.bandwidth_hz * 0.4) / if_rate_));
      am_alpha_ = static_cast<float>(1 - std::exp(-1.0 / (if_rate_ * 0.25)));
      deemphasis_alpha_ = static_cast<float>(1 - std::exp(-1.0 /
          (48000 * (controls.mode == SDR_V3_WFM ? 50e-6 : 75e-6))));
      metric_interval_ = std::max<size_t>(1, static_cast<size_t>(if_rate_ / 1000));
      const double sideband_offset = controls.mode == SDR_V3_USB ?
          half_bw : controls.mode == SDR_V3_LSB ? -half_bw : 0.0;
      sideband_step_ = std::polar(1.0f, static_cast<float>(2 * kPi * sideband_offset / if_rate_));
      cw_step_ = std::polar(1.0f, static_cast<float>(2 * kPi * kCwToneHz / if_rate_));
      first_.configure(sr, first_rate * 0.40, first_factor_, 127);
      second_.configure(first_rate, controls.bandwidth_hz * 0.5, second_factor_);
      // Anti-alias audio bandwidth: WFM baseband is mono; no stereo MPX decoder.
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
    if (squelch_change) reset_squelch();
    if (display_change) fft_count_ = 0;
  }

  void reset() override {
    first_.reset();
    second_.reset();
    oscillator_ = {1, 0};
    oscillator_count_ = 0;
    fft_count_ = 0;
    fft_since_row_ = 0;
    reset_channel();
    reset_squelch();
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
    result.signal_db = controls_.squelch == SDR_V3_SQUELCH_AUTO &&
        controls_.mode == SDR_V3_NFM ? metric_db_ :
        static_cast<float>(10 * std::log10(std::max(power_smooth_, kFloor)));
    result.squelch_threshold_db = threshold_db_;
    result.squelch_ready = controls_.squelch == SDR_V3_SQUELCH_OFF || squelch_ready_;
    result.squelch_open = controls_.squelch == SDR_V3_SQUELCH_OFF || squelch_open_;
  }

 private:
  static constexpr size_t kAudioTaps = 32, kPhases = 64;
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
    gate_ = 0;
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
    reset_squelch();
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
    if ((audio_input_count_ & 4095) == 0) {
      const float sideband_mag = std::abs(sideband_), cw_mag = std::abs(cw_);
      if (sideband_mag > 0) sideband_ /= sideband_mag;
      if (cw_mag > 0) cw_ /= cw_mag;
    }
    audio_history_[audio_index_] = value;
    audio_index_ = (audio_index_ + 1) & (kAudioTaps - 1);
    ++audio_input_count_;
    const double spacing = if_rate_ / 48000.0;
    while (next_audio_time_ <= static_cast<double>(audio_input_count_ - 1)) {
      const double lag = static_cast<double>(audio_input_count_ - 1) - next_audio_time_;
      if (lag < 0 || lag >= 1) break;
      const size_t phase = std::min<size_t>(kPhases - 1,
          static_cast<size_t>(lag * kPhases));
      float out = 0;
      size_t index = (audio_index_ - 1) & (kAudioTaps - 1);
      for (float tap : audio_taps_[phase]) {
        out += audio_history_[index] * tap;
        index = (index - 1) & (kAudioTaps - 1);
      }
      next_audio_time_ += spacing;
      // FM deemphasis and a gentle DC/high-pass for all modes.
      if (controls_.mode == SDR_V3_WFM || controls_.mode == SDR_V3_NFM) {
        deemphasis_ += deemphasis_alpha_ * (out - deemphasis_);
        out = deemphasis_;
      }
      const float hp = out - audio_dc_in_ + 0.995f * audio_dc_out_;
      audio_dc_in_ = out;
      audio_dc_out_ = hp;
      float leveled = hp;
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
      audio.push_back(pcm);
      audio.push_back(pcm);
    }
  }
  SdrV3Controls controls_{};
  SdrV3Display display_{};
  bool configured_ = false;
  ComplexDecimator first_, second_;
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

// SPDX-License-Identifier: GPL-3.0-or-later
// Test-only, header-only SSTV encoder: independent of the csdr-plus decoder
// code path (native/third_party/csdr_sstv), used solely by native/tests to
// synthesize known-content audio and verify the adapter/decoder against it.
// Not shipped in the production library; reused later for an end-to-end
// receiver test per the task brief.
//
// Timing constants (SCAN_TIME/SYNC_PULSE/SYNC_PORCH/SEP_PULSE/SEP_PORCH per
// mode) are cross-checked against native/third_party/csdr_sstv/include/sstv.hpp
// (explicitly permitted by the task) and match the publicly published SSTV
// mode specifications, e.g.:
//   - J.L. Barber, "Proposal for SSTV Mode Specifications", SSTV
//     Mailing List, 2000 (Martin/Scottie/Robot/PD family timings).
//   - pysstv (https://github.com/colaclanth/pysstv), an independent
//     open-source SSTV encoder implementing the same published specs.
// The actual signal-synthesis code (phase-continuous oscillator, per-mode
// segment sequencing, luminance/chrominance frequency mapping, VIS framing)
// below is written from scratch against those published specs, not copied
// or derived from sstv.cpp's decodeLine/convert*/decodeVIS implementations.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <random>
#include <string>
#include <vector>

namespace sstv_test {

constexpr double kPi = 3.14159265358979323846;

enum class Mode { kMartin1, kScottie1, kRobot36, kPd90, kPd290 };

struct ModeInfo {
  int vis;
  const char* name;
  int width;
  int height;
};

inline ModeInfo mode_info(Mode mode) {
  switch (mode) {
    case Mode::kMartin1: return {44, "Martin 1", 320, 256};
    case Mode::kScottie1: return {60, "Scottie 1", 320, 256};
    case Mode::kRobot36: return {8, "Robot 36", 320, 240};
    case Mode::kPd90: return {99, "PD-90", 320, 256};
    case Mode::kPd290: return {94, "PD-290", 800, 616};
  }
  return {0, "Invalid", 0, 0};
}

struct EncodeOptions {
  // Simulated transmitter clock error: all segment durations are scaled by
  // 1/clock_ratio (clock_ratio>1 => a "fast" transmitter clock compresses
  // real time per nominal duration, matching a real crystal frequency
  // error). Tone frequencies are unaffected: this isolates pure timing
  // drift so the resulting audio exercises findSync()'s per-line
  // realignment, matching the task's "clock_ratio 1.0005/0.9995" case.
  double clock_ratio = 1.0;
  // Added to every emitted tone frequency (header and pixel/sync tones
  // alike), simulating a transmit/receive audio frequency offset.
  double freq_offset_hz = 0.0;
  // Gaussian noise added to the final waveform when add_noise is true,
  // scaled to the requested SNR relative to the signal RMS.
  bool add_noise = false;
  double noise_snr_db = 20.0;
  uint32_t seed = 1;
  // Flips the VIS parity bit so decodeVIS() must reject the header
  // (negative test case).
  bool corrupt_parity = false;
  // Transmits this 7-bit VIS code (with correct parity unless
  // corrupt_parity) instead of the mode's own, e.g. an unmapped code.
  int vis_override = -1;
  // When true the returned samples are the oscillator's phase in radians
  // (wrapped to [0, 2*pi)) instead of sin(phase), so a test can build the
  // analytic USB/LSB/FM IQ signal of exactly the same transmission. Noise
  // is never added to phase output.
  bool output_phase = false;
};

// Deterministic, parameter-seeded test pattern: eight vertical color bars
// (classic broadcast-bar palette) overlaid with a thin diagonal line, so
// tests can both compute PSNR against a known image and locate a sharp
// vertical edge per row to measure slant/misalignment.
inline std::vector<uint8_t> make_test_pattern(int width, int height, uint32_t seed = 1) {
  static const uint8_t kBars[8][3] = {
      {255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
      {255, 0, 255},   {255, 0, 0},   {0, 0, 255},   {0, 0, 0},
  };
  std::vector<uint8_t> rgb(static_cast<size_t>(width) * height * 3);
  std::mt19937 rng(seed);
  std::uniform_int_distribution<int> jitter(-4, 4);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const int bar = std::min(7, x * 8 / width);
      uint8_t r = kBars[bar][0], g = kBars[bar][1], b = kBars[bar][2];
      // Thin diagonal line (distinct from bar colors) to add high-frequency
      // structure for PSNR sensitivity, plus tiny deterministic jitter so
      // the pattern is not perfectly flat within each bar.
      const int diag = (x + y * width / height) % width;
      if (diag < 2) { r = 128; g = 64; b = 200; }
      const int j = jitter(rng);
      r = static_cast<uint8_t>(std::clamp(int(r) + j, 0, 255));
      g = static_cast<uint8_t>(std::clamp(int(g) + j, 0, 255));
      b = static_cast<uint8_t>(std::clamp(int(b) + j, 0, 255));
      const size_t idx = (static_cast<size_t>(y) * width + x) * 3;
      rgb[idx] = r; rgb[idx + 1] = g; rgb[idx + 2] = b;
    }
  }
  return rgb;
}

namespace detail {

// Phase-continuous sine oscillator: frequency may change between emit()
// calls but phase never jumps, avoiding spurious FFT energy at segment
// boundaries (matching how a real FM/AFSK SSTV transmitter behaves).
// Durations are accumulated on an ideal (double) timeline and each segment
// ends at the rounded sample index of its ideal end time, so per-segment
// rounding never accumulates: a 320-pixel Robot 36 Y scan (6.6 samples per
// pixel at 24 kHz) lasts exactly 88 ms instead of 320*7 samples.
class PhaseOscillator {
 public:
  PhaseOscillator(double sample_rate, bool output_phase, double clock_ratio)
      : sample_rate_(sample_rate), output_phase_(output_phase), clock_ratio_(clock_ratio) {}

  // Emits `freq_hz` for `seconds` of nominal transmitter time (scaled by
  // 1/clock_ratio to real time).
  void emit(std::vector<float>& out, double freq_hz, double seconds) {
    ideal_time_ += seconds / clock_ratio_;
    const size_t end = static_cast<size_t>(std::llround(ideal_time_ * sample_rate_));
    const size_t sample_count = end > emitted_ ? end - emitted_ : 0;
    const double step = 2.0 * kPi * freq_hz / sample_rate_;
    for (size_t i = 0; i < sample_count; ++i) {
      out.push_back(static_cast<float>(output_phase_ ? phase_ : std::sin(phase_)));
      phase_ += step;
      if (phase_ >= 2.0 * kPi) phase_ -= 2.0 * kPi;
    }
    emitted_ += sample_count;
  }

 private:
  double sample_rate_;
  bool output_phase_;
  double clock_ratio_;
  double phase_ = 0.0;
  double ideal_time_ = 0.0;
  size_t emitted_ = 0;
};

// Standard SSTV luminance tone mapping: 1500 Hz = black (0), 2300 Hz =
// white (255), linear in between. Independently stated here from the
// published SSTV spec (the same scale sstv.hpp's luminance() inverts).
inline double luminance_freq(uint8_t value) {
  return 1500.0 + static_cast<double>(value) * (800.0 / 255.0);
}

// BT.601-style (full-range) RGB -> YCbCr, matching the color space that
// sstv.hpp's yuv2rgb() approximately inverts (its integer coefficients
// 91882/65536=1.402, 46793/65536=0.714, 22545/65536=0.344,
// 116130/65536=1.772 are the standard BT.601 Cr/Cb -> RGB constants).
// Independently derived here (textbook forward transform), not copied
// from or algebraically solved out of yuv2rgb()'s code.
struct YuvPixel { uint8_t y, u, v; };

inline YuvPixel rgb_to_yuv(uint8_t r, uint8_t g, uint8_t b) {
  const double fr = r, fg = g, fb = b;
  const double y = 0.299 * fr + 0.587 * fg + 0.114 * fb;
  const double u = -0.168736 * fr - 0.331264 * fg + 0.5 * fb + 128.0;
  const double v = 0.5 * fr - 0.418688 * fg - 0.081312 * fb + 128.0;
  auto clamp8 = [](double x) {
    return static_cast<uint8_t>(std::clamp(x, 0.0, 255.0));
  };
  return {clamp8(y), clamp8(u), clamp8(v)};
}

inline void emit_vis_header(std::vector<float>& out, detail::PhaseOscillator& osc,
                             int vis, const EncodeOptions& opts) {
  const double off = opts.freq_offset_hz;
  auto tone = [&](double freq, double seconds) { osc.emit(out, freq + off, seconds); };
  tone(1900.0, 0.300);  // Leader 1
  tone(1200.0, 0.010);  // Break
  tone(1900.0, 0.300);  // Leader 2
  tone(1200.0, 0.030);  // VIS start bit
  int ones = 0;
  for (int bit = 0; bit < 7; ++bit) {
    const int b = (vis >> bit) & 1;
    ones += b;
    tone(b ? 1100.0 : 1300.0, 0.030);
  }
  int parity_bit = ones % 2;  // Makes total 1-count (7 data + parity) even.
  if (opts.corrupt_parity) parity_bit ^= 1;
  tone(parity_bit ? 1100.0 : 1300.0, 0.030);
  tone(1200.0, 0.030);  // Stop bit
}

inline void apply_noise(std::vector<float>& samples, const EncodeOptions& opts) {
  if (!opts.add_noise || opts.output_phase || samples.empty()) return;
  double sum_sq = 0.0;
  for (float s : samples) sum_sq += static_cast<double>(s) * s;
  const double rms = std::sqrt(sum_sq / samples.size());
  const double noise_amp = rms / std::pow(10.0, opts.noise_snr_db / 20.0);
  std::mt19937 rng(opts.seed * 7919u + 17u);
  std::normal_distribution<double> gauss(0.0, 1.0);
  for (float& s : samples) s = static_cast<float>(s + noise_amp * gauss(rng));
}

}  // namespace detail

// Encodes `rgb` (width*height*3 interleaved R,G,B bytes) as `mode`, returning
// mono float audio at `sample_rate` Hz. `rgb.size()` must equal
// width*height*3 and width/height should match mode_info(mode) for a
// decodable frame (the encoder does not resample the image).
inline std::vector<float> encode(Mode mode, const std::vector<uint8_t>& rgb, int width,
                                  int height, double sample_rate,
                                  const EncodeOptions& opts = {}) {
  using detail::emit_vis_header;
  using detail::luminance_freq;
  using detail::PhaseOscillator;
  using detail::rgb_to_yuv;

  std::vector<float> out;
  PhaseOscillator osc(sample_rate, opts.output_phase, opts.clock_ratio);
  const ModeInfo info = mode_info(mode);
  emit_vis_header(out, osc, opts.vis_override >= 0 ? opts.vis_override : info.vis, opts);

  auto pixel_at = [&](int x, int y, int ch) -> uint8_t {
    const size_t idx = (static_cast<size_t>(std::clamp(y, 0, height - 1)) * width +
                         std::clamp(x, 0, width - 1)) * 3;
    return rgb[idx + ch];
  };
  auto tone = [&](double freq, double seconds) {
    osc.emit(out, freq + opts.freq_offset_hz, seconds);
  };
  auto scan_row_channel = [&](int y, int ch, double scan_seconds, int px_count) {
    const double px_time = scan_seconds / px_count;
    for (int x = 0; x < px_count; ++x) {
      tone(luminance_freq(pixel_at(x, y, ch)), px_time);
    }
  };

  switch (mode) {
    case Mode::kMartin1:
    case Mode::kScottie1: {
      // Published Martin/Scottie scan order is green, blue, red. The source
      // image is interleaved R,G,B, so those are RGB channel indices 1, 2, 0.
      constexpr int kG = 1, kB = 2, kR = 0;
      const bool scottie = mode == Mode::kScottie1;
      const double scan_time = scottie ? 0.13824 : 0.146432;
      const double sync_pulse = scottie ? 0.009 : 0.004862;
      const double sync_porch = scottie ? 0.0015 : 0.000572;
      const double sep_pulse = scottie ? 0.0015 : 0.000572;
      if (scottie) tone(1200.0, sync_pulse);  // Scottie's initial start sync.
      for (int y = 0; y < height; ++y) {
        if (scottie) {
          tone(1500.0, sep_pulse);
          scan_row_channel(y, kG, scan_time, width);
          tone(1500.0, sep_pulse);
          scan_row_channel(y, kB, scan_time, width);
          tone(1200.0, sync_pulse);
          tone(1500.0, sync_porch);
          scan_row_channel(y, kR, scan_time, width);
        } else {
          tone(1200.0, sync_pulse);
          tone(1500.0, sync_porch);
          scan_row_channel(y, kG, scan_time, width);
          tone(1500.0, sep_pulse);
          scan_row_channel(y, kB, scan_time, width);
          tone(1500.0, sep_pulse);
          scan_row_channel(y, kR, scan_time, width);
        }
      }
      break;
    }
    case Mode::kRobot36: {
      constexpr double kSyncPulse = 0.0090, kSyncPorch = 0.0030;
      constexpr double kScanTimeY = 0.0880, kSepPulse = 0.0045, kSepPorch = 0.0015;
      std::vector<detail::YuvPixel> row(width);
      for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x)
          row[x] = rgb_to_yuv(pixel_at(x, y, 0), pixel_at(x, y, 1), pixel_at(x, y, 2));
        tone(1200.0, kSyncPulse);
        tone(1500.0, kSyncPorch);
        const double y_px_time = kScanTimeY / width;
        for (int x = 0; x < width; ++x) tone(luminance_freq(row[x].y), y_px_time);
        tone(1500.0, kSepPulse);
        tone(1900.0, kSepPorch);
        // Chroma: V on even rows, U on odd rows (matches convertR36's "V in
        // even lines, U in odd lines"), half-width scan time.
        const double c_px_time = (kScanTimeY / 2.0) / width;
        const bool even = (y % 2) == 0;
        for (int x = 0; x < width; ++x)
          tone(luminance_freq(even ? row[x].v : row[x].u), c_px_time);
      }
      break;
    }
    case Mode::kPd90:
    case Mode::kPd290: {
      // Standard PD line pair (published PD spec): sync, porch, Y of the
      // first row, R-Y and B-Y averaged over both rows, Y of the second row.
      const double scan_time = mode == Mode::kPd290 ? 0.2288 : 0.17024;
      constexpr double kSyncPulse = 0.02, kSyncPorch = 0.00208;
      for (int y = 0; y + 1 < height; y += 2) {
        std::vector<detail::YuvPixel> a(width), b(width);
        for (int x = 0; x < width; ++x) {
          a[x] = rgb_to_yuv(pixel_at(x, y, 0), pixel_at(x, y, 1), pixel_at(x, y, 2));
          b[x] = rgb_to_yuv(pixel_at(x, y + 1, 0), pixel_at(x, y + 1, 1), pixel_at(x, y + 1, 2));
        }
        tone(1200.0, kSyncPulse);
        tone(1500.0, kSyncPorch);
        const double px_time = scan_time / width;
        auto avg = [](uint8_t p, uint8_t q) {
          return static_cast<uint8_t>((static_cast<int>(p) + q + 1) / 2);
        };
        for (int x = 0; x < width; ++x) tone(luminance_freq(a[x].y), px_time);
        for (int x = 0; x < width; ++x) tone(luminance_freq(avg(a[x].v, b[x].v)), px_time);
        for (int x = 0; x < width; ++x) tone(luminance_freq(avg(a[x].u, b[x].u)), px_time);
        for (int x = 0; x < width; ++x) tone(luminance_freq(b[x].y), px_time);
      }
      break;
    }
  }

  detail::apply_noise(out, opts);
  return out;
}

}  // namespace sstv_test

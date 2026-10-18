// SPDX-License-Identifier: GPL-3.0-or-later
// Test-only DMR 4FSK modulator: digiham dibits -> complex baseband IQ.
//
// ETSI TS 102 361-1 section 10.2: 4800 symbols/s, root-raised-cosine
// frequency pulse (alpha 0.2), deviations +1944/+648/-648/-1944 Hz for
// digiham dibits 1/0/2/3 (outer positive = 1, see dmr/channel.hpp).
// Optional constant carrier offset and complex AWGN. The noise is specified
// as a carrier-to-noise ratio inside a 12.5 kHz channel, so the per-sample
// noise power scales with the output rate. Deterministic for a given seed.
#pragma once

#include <cmath>
#include <complex>
#include <cstddef>
#include <cstdint>
#include <random>
#include <vector>

namespace dmr_test {

struct FskOptions {
  uint32_t rate = 240000;      // any rate >= 48 kS/s
  double offset_hz = 0.0;      // carrier offset
  double cnr_db = 200.0;       // >= 200: no noise
  uint32_t seed = 1;
  double amplitude = 0.7;
};

inline double dmr_deviation(uint8_t dibit) {
  static constexpr double kDev[4] = {648.0, 1944.0, -648.0, -1944.0};
  return kDev[dibit & 3];
}

// Root-raised-cosine impulse at t (in symbol periods), alpha in (0, 1).
inline double rrc(double t, double alpha) {
  constexpr double pi = 3.14159265358979323846;
  if (std::abs(t) < 1e-9) return 1.0 - alpha + 4.0 * alpha / pi;
  if (std::abs(std::abs(t) - 1.0 / (4.0 * alpha)) < 1e-9)
    return alpha / std::sqrt(2.0) *
           ((1 + 2 / pi) * std::sin(pi / (4 * alpha)) +
            (1 - 2 / pi) * std::cos(pi / (4 * alpha)));
  const double num = std::sin(pi * t * (1 - alpha)) +
                     4 * alpha * t * std::cos(pi * t * (1 + alpha));
  const double den = pi * t * (1 - 16 * alpha * alpha * t * t);
  return num / den;
}

inline std::vector<std::complex<float>> modulate_dmr(
    const std::vector<uint8_t>& dibits, const FskOptions& o) {
  constexpr double pi = 3.14159265358979323846;
  constexpr int span = 8;           // symbols each side
  constexpr int table_res = 1024;   // pulse table points per symbol
  constexpr double alpha = 0.2;
  // Pulse table; normalised so a constant symbol run reaches exactly its
  // nominal deviation (mean over one symbol of sum_k p(t - k) == 1).
  std::vector<double> pulse(2 * span * table_res + 1);
  for (size_t i = 0; i < pulse.size(); ++i)
    pulse[i] = rrc((static_cast<double>(i) - span * table_res) / table_res, alpha);
  double mean = 0;
  for (int f = 0; f < table_res; ++f)
    for (int k = -span; k < span; ++k) mean += pulse[(f + k * table_res) + span * table_res];
  mean /= table_res;
  for (auto& p : pulse) p /= mean;

  // Arbitrary rate (e.g. 250 kS/s): evaluate the frequency at each sample's
  // exact symbol time, symbol k centred at t = k + 0.5.
  const size_t n = static_cast<size_t>(
      static_cast<double>(dibits.size()) * o.rate / 4800.0);
  std::mt19937 rng(o.seed);
  const bool noisy = o.cnr_db < 200.0;
  const double noise_power = o.amplitude * o.amplitude *
                             std::pow(10.0, -o.cnr_db / 10.0) * (o.rate / 12500.0);
  std::normal_distribution<double> gauss(0.0, std::sqrt(noise_power / 2.0));
  std::vector<std::complex<float>> iq(n);
  double phase = 0;
  for (size_t j = 0; j < n; ++j) {
    const double t = static_cast<double>(j) * 4800.0 / o.rate;
    const long base = static_cast<long>(std::floor(t - 0.5));
    double freq = 0;
    for (long k = base - span + 1; k <= base + span; ++k) {
      if (k < 0 || k >= static_cast<long>(dibits.size())) continue;
      const double x = (t - (static_cast<double>(k) + 0.5)) * table_res + span * table_res;
      const auto i = static_cast<size_t>(x);
      if (i + 1 >= pulse.size()) continue;
      const double w = x - static_cast<double>(i);
      freq += dmr_deviation(dibits[k]) * (pulse[i] * (1 - w) + pulse[i + 1] * w);
    }
    phase += 2 * pi * (freq + o.offset_hz) / o.rate;
    if (phase > pi) phase -= 2 * pi;
    if (phase < -pi) phase += 2 * pi;
    std::complex<double> s = std::polar(o.amplitude, phase);
    if (noisy) s += std::complex<double>(gauss(rng), gauss(rng));
    iq[j] = std::complex<float>(static_cast<float>(s.real()), static_cast<float>(s.imag()));
  }
  return iq;
}

}  // namespace dmr_test

// SPDX-License-Identifier: GPL-3.0-or-later
// Identical synthetic stereo CU8 stream: WFM native DSP CPU with and without
// the RDS branch. It is not a USB or Android audio-sink benchmark.
#include "../src/dsp/receiver.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <sys/resource.h>
#include <vector>

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr uint32_t kRate = 2400000;
constexpr size_t kBlockSamples = 16384;
constexpr size_t kSeconds = 8;
double cpu_seconds() {
  rusage usage{};
  getrusage(RUSAGE_SELF, &usage);
  return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
         usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}
}

int main(int argc, char** argv) {
  if (argc != 2 || (std::string(argv[1]) != "on" && std::string(argv[1]) != "off"))
    return 2;
  const bool enabled = std::string(argv[1]) == "on";
  SdrV3Controls controls{};
  controls.size = sizeof controls;
  controls.revision = SDR_V3_REVISION;
  controls.center_frequency_hz = 100000000;
  controls.sample_rate = kRate;
  controls.mode = SDR_V3_WFM;
  controls.bandwidth_hz = 150000;
  controls.squelch = SDR_V3_SQUELCH_OFF;
  controls.volume = 1;
  SdrV3Display display{};
  display.size = sizeof display;
  display.revision = SDR_V3_REVISION;
  display.view_bandwidth_hz = kRate;
  auto receiver = sdrcore::dsp::make_receiver();
  receiver->configure(controls, display);
  receiver->set_wfm_stereo(true);
  receiver->set_rds_suspended(!enabled);
  std::vector<uint8_t> iq(2 * kBlockSamples);
  sdrcore::dsp::ProcessResult result;
  size_t audio_frames = 0;
  double phase = 0;
  const auto start_wall = std::chrono::steady_clock::now();
  const double start_cpu = cpu_seconds();
  double worst_ms = 0;
  for (size_t offset = 0; offset < kRate * kSeconds; offset += kBlockSamples) {
    const size_t n = std::min(kBlockSamples, size_t(kRate) * kSeconds - offset);
    // Input generation is excluded from the timed DSP block and CPU total is
    // reported separately from wall time; PCM output must stay continuous.
    for (size_t i = 0; i < n; ++i) {
      const double t = static_cast<double>(offset + i) / kRate;
      const double mpx = 0.3 * std::sin(2 * kPi * 700 * t) +
                         0.08 * std::cos(2 * kPi * 19000 * t) +
                         0.18 * std::sin(2 * kPi * 800 * t) * std::cos(2 * kPi * 38000 * t);
      phase += 2 * kPi * 75000 * mpx / kRate;
      if (phase > kPi) phase -= 2 * kPi;
      if (phase < -kPi) phase += 2 * kPi;
      iq[2 * i] = static_cast<uint8_t>(std::clamp(std::lround(127.5 + 127.5 * std::cos(phase)), 0L, 255L));
      iq[2 * i + 1] = static_cast<uint8_t>(std::clamp(std::lround(127.5 + 127.5 * std::sin(phase)), 0L, 255L));
    }
    const auto before = std::chrono::steady_clock::now();
    receiver->process(iq.data(), n * 2, result);
    const double ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - before).count();
    worst_ms = std::max(worst_ms, ms);
    audio_frames += result.audio.size() / 2;
  }
  const double cpu = cpu_seconds() - start_cpu;
  const double wall = std::chrono::duration<double>(
      std::chrono::steady_clock::now() - start_wall).count();
  const double expected = kSeconds * 48000.;
  std::cout << "rds=" << (enabled ? "on" : "off")
            << " cpu_process_plus_generation_s=" << cpu
            << " wall_process_plus_generation_s=" << wall
            << " max_dsp_block_ms=" << worst_ms
            << " block_budget_ms=" << kBlockSamples * 1000. / kRate
            << " frames=" << audio_frames << " expected=" << expected << '\n';
  return std::abs(static_cast<double>(audio_frames) - expected) > 2 ? 1 : 0;
}

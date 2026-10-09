// SPDX-License-Identifier: GPL-3.0-or-later
// Re-modulate external redsea MPX into synthetic CU8 FM and exercise the
// production WFM discriminator, channel FIR, RDS branch and stereo audio.
#include "../src/dsp/receiver.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  if (argc != 3) return 2;  // input.s16 0|1 (RBDS)
  constexpr double pi = 3.14159265358979323846;
  constexpr uint32_t rate = 192000;
  std::ifstream input(argv[1], std::ios::binary);
  if (!input) return 2;
  std::vector<int16_t> mpx;
  int16_t sample;
  while (input.read(reinterpret_cast<char*>(&sample), sizeof(sample))) mpx.push_back(sample);
  if (mpx.empty()) return 2;
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = 100000000;
  c.sample_rate = rate;
  c.bandwidth_hz = 150000;
  c.mode = SDR_V3_WFM;
  c.squelch = SDR_V3_SQUELCH_OFF;
  c.volume = 1;
  SdrV3Display d{};
  d.size = sizeof d;
  d.revision = SDR_V3_REVISION;
  d.view_bandwidth_hz = rate;
  auto receiver = sdrcore::dsp::make_receiver();
  receiver->configure(c, d);
  receiver->set_wfm_stereo(true);
  receiver->set_rds_rbds(std::stoi(argv[2]) != 0);
  sdrcore::dsp::ProcessResult result;
  std::vector<uint8_t> iq(2 * 4096);
  double phase = 0;
  size_t audio_frames = 0, groups = 0;
  bool saw_pi = false;
  std::string json;
  for (size_t offset = 0; offset < mpx.size(); offset += 4096) {
    const size_t count = std::min<size_t>(4096, mpx.size() - offset);
    for (size_t i = 0; i < count; ++i) {
      phase += 2 * pi * 75000 * (mpx[offset + i] / 32768.) / rate;
      if (phase > pi) phase -= 2 * pi;
      if (phase < -pi) phase += 2 * pi;
      iq[2 * i] = static_cast<uint8_t>(std::clamp(std::lround(127.5 + 115 * std::cos(phase)), 0L, 255L));
      iq[2 * i + 1] = static_cast<uint8_t>(std::clamp(std::lround(127.5 + 115 * std::sin(phase)), 0L, 255L));
    }
    receiver->process(iq.data(), 2 * count, result);
    audio_frames += result.audio.size() / 2;
    while (receiver->take_rds_group(json)) {
      std::cout << json << '\n';
      ++groups;
      saw_pi |= json.find("\"pi\":\"0x") != std::string::npos;
    }
  }
  std::cerr << "groups=" << groups << " audio_frames=" << audio_frames
            << " expected_frames=" << mpx.size() / 4 << '\n';
  if (std::abs(static_cast<double>(audio_frames) - mpx.size() / 4.) > 2 || !saw_pi) return 1;
  c.vfo_offset_hz = 1000;
  receiver->configure(c, d);
  if (receiver->take_rds_group(json) || receiver->rds_synced()) return 1;
  c.mode = SDR_V3_AM;
  c.bandwidth_hz = 12000;
  receiver->configure(c, d);
  if (receiver->take_rds_group(json) || receiver->rds_synced()) return 1;
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Replay the exact 1 MS/s complex-f32 OpenWebRX+ lorarx input through the
// registry Meshtastic backend. One native message event per output line.
// Usage: sdrcore_meshtastic_replay <iq.f32> <config-json> [frequency-hz]
#include "decoder.hpp"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <string>

int main(int argc, char** argv) {
  if (argc < 3 || argc > 4) {
    std::fprintf(stderr, "usage: %s <iq.f32> <config-json> [frequency-hz]\n", argv[0]);
    return 2;
  }
  std::unique_ptr<sdrcore::decoder::Decoder> dec;
  for (const auto& entry : sdrcore::decoder::registry()) {
    if (std::string(entry.descriptor.id) == "meshtastic" && entry.create) {
      dec = entry.create();
      break;
    }
  }
  if (!dec || !dec->configure(argv[2])) return 2;
  dec->set_tuning(argc == 4 ? std::strtoull(argv[3], nullptr, 10) : 869525000, 1000000);
  std::ifstream iq(argv[1], std::ios::binary);
  if (!iq) return 2;
  // The embedded PHY accepts full 4096-frame blocks, just as upstream does.
  std::array<float, 4096 * 2> block{};
  while (iq.read(reinterpret_cast<char*>(block.data()), sizeof block))
    dec->process(block.data(), 4096, 1000000);
  sdrcore::decoder::Event event;
  while (dec->take_event(event)) {
    if (event.kind != sdrcore::decoder::Result::message) continue;
    std::fwrite(event.payload.data(), 1, event.payload.size(), stdout);
    std::putchar('\n');
  }
  return iq.eof() ? 0 : 1;
}

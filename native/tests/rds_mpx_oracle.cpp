// SPDX-License-Identifier: GPL-3.0-or-later
// Host-only same-MPX comparison: original redsea core versus embedded Sink.
#include "../src/rds/rds.h"
#include "src/channel.hh"
#include "src/dsp/subcarrier.hh"
#include "src/io/input.hh"
#include "src/options.hh"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  if (argc != 5 || (std::string(argv[1]) != "redsea" &&
                    std::string(argv[1]) != "embedded")) {
    std::cerr << "usage: rds_mpx_oracle redsea|embedded input.s16 rate rbds(0|1)\n";
    return 2;
  }
  const int rate = std::stoi(argv[3]);
  const bool rbds = std::stoi(argv[4]) != 0;
  if (rate < 128000 || rate > 3000000) return 2;
  std::ifstream input(argv[2], std::ios::binary);
  if (!input) throw std::runtime_error("Cannot open MPX recording");
  // Redsea's raw input is signed 16-bit PCM; both branches get the SAME
  // quantized samples, with no fabricated RDS group or test-only decoder.
  std::vector<int16_t> raw;
  int16_t sample;
  while (input.read(reinterpret_cast<char*>(&sample), sizeof(sample))) raw.push_back(sample);
  if (raw.empty()) return 2;
  if (std::string(argv[1]) == "redsea") {
    redsea::Options options;
    options.samplerate = rate;
    options.rbds = rbds;
    redsea::Channel channel(options, 0);
    redsea::SubcarrierSet subcarrier(static_cast<float>(rate));
    redsea::MPXBuffer chunk;
    for (size_t offset = 0; offset < raw.size(); offset += redsea::kInputChunkSize) {
      chunk.used_size = std::min(raw.size() - offset, redsea::kInputChunkSize);
      for (size_t i = 0; i < chunk.used_size; ++i)
        chunk.data[i] = raw[offset + i] / 32768.f;
      channel.processBits(subcarrier.chunkToBits(chunk, 1), std::cout);
      if (channel.getSecondsSinceCarrierLost() > 10.f &&
          subcarrier.getSecondsSinceLastReset() > 5.f) {
        subcarrier.reset();
        channel.resetPI();
      }
    }
    channel.flush(std::cout);
  } else {
    sdrcore::rds::Sink sink;
    sink.configure(rate, rbds);
    std::vector<float> chunk(4096);
    std::string json;
    for (size_t offset = 0; offset < raw.size(); offset += chunk.size()) {
      const size_t count = std::min(raw.size() - offset, chunk.size());
      for (size_t i = 0; i < count; ++i) chunk[i] = raw[offset + i] / 32768.f;
      sink.process(chunk.data(), count);
      while (sink.take_group(json)) std::cout << json << '\n';
    }
  }
}

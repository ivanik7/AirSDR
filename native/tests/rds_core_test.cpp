// SPDX-License-Identifier: GPL-3.0-or-later
#include "../src/rds/rds.h"
#include "src/channel.hh"
#include "src/group.hh"
#include "src/options.hh"

#include <algorithm>
#include <array>
#include <cassert>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {
redsea::Group group(uint16_t pi, uint16_t b, uint16_t c, uint16_t d) {
  redsea::Group result;
  const std::array<uint16_t, 4> data{pi, b, c, d};
  const std::array<redsea::Offset, 4> offsets{redsea::Offset::A,
      redsea::Offset::B, redsea::Offset::C, redsea::Offset::D};
  for (unsigned i = 0; i < 4; ++i) {
    redsea::Block block{};
    block.data = data[i];
    block.is_received = true;
    block.offset = offsets[i];
    result.setBlock(static_cast<redsea::eBlockNumber>(i), block);
  }
  return result;
}
}

int main(int argc, char** argv) {
  redsea::Options opts;
  redsea::Channel channel(opts, 0);
  std::ostringstream decoded;
  // Exercise upstream PI hysteresis, Group 0 PS assembly, and changed PI.
  for (int repeat = 0; repeat < 3; ++repeat)
    for (unsigned segment = 0; segment < 4; ++segment)
      channel.processAndPrintGroup(group(0x1234, static_cast<uint16_t>(0x0400 | segment),
          0xe001, static_cast<uint16_t>("TESTFM  "[2 * segment] << 8 |
                                        "TESTFM  "[2 * segment + 1])), 0, decoded);
  const auto first = decoded.str();
  assert(first.find("0x1234") != std::string::npos);
  assert(first.find("TESTFM") != std::string::npos);
  for (int i = 0; i < 3; ++i)
    channel.processAndPrintGroup(group(0x5678, 0x0400, 0xe001, 0x4e45), 0, decoded);
  assert(decoded.str().find("0x5678") != std::string::npos);

  sdrcore::rds::Sink sink;
  sink.configure(48000, false);
  std::string event;
  assert(!sink.synced() && !sink.take_group(event));
  sink.configure(192000, false);
  std::vector<float> silence(19200, 0);
  sink.process(silence.data(), silence.size());
  assert(!sink.take_group(event));
  sink.reset();
  assert(!sink.synced() && !sink.take_group(event));
  sink.configure(192000, true);
  assert(!sink.synced());
  if (argc == 2) {
    std::ifstream file(argv[1], std::ios::binary);
    uint32_t rate = 0, count = 0;
    file.read(reinterpret_cast<char*>(&rate), sizeof(rate));
    file.read(reinterpret_cast<char*>(&count), sizeof(count));
    assert(file && rate >= 128000 && count > 0);
    std::vector<float> samples(count);
    file.read(reinterpret_cast<char*>(samples.data()), count * sizeof(float));
    assert(file);
    sink.configure(rate, false);
    for (size_t i = 0; i < samples.size(); i += 4096)
      sink.process(samples.data() + i, std::min<size_t>(4096, samples.size() - i));
    unsigned groups = 0;
    while (sink.take_group(event)) {
      std::cout << event << '\n';
      ++groups;
    }
    assert(groups > 0);
    sink.reset();
    assert(!sink.synced() && !sink.take_group(event));
    std::cerr << "RDS decoded groups: " << groups << '\n';
  }
  return 0;
}

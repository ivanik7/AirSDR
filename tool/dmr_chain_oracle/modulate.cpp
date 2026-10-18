// SPDX-License-Identifier: GPL-3.0-or-later
// dmr_modulate RATE OFFSET_HZ CNR_DB SEED < dibits > cf32 IQ
// Test-only 4FSK modulator (native/tests/dmr_fsk_modulator.hpp).
#include "dmr_fsk_modulator.hpp"

#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <iterator>

int main(int argc, char** argv) {
  if (argc != 5) {
    std::fprintf(stderr, "usage: %s RATE OFFSET_HZ CNR_DB SEED < dibits > cf32\n", argv[0]);
    return 2;
  }
  const std::vector<uint8_t> dibits(std::istreambuf_iterator<char>{std::cin}, {});
  dmr_test::FskOptions o;
  o.rate = static_cast<uint32_t>(std::atoi(argv[1]));
  o.offset_hz = std::atof(argv[2]);
  o.cnr_db = std::atof(argv[3]);
  o.seed = static_cast<uint32_t>(std::atoi(argv[4]));
  if (o.rate < 48000) return 2;
  const auto iq = dmr_test::modulate_dmr(dibits, o);
  std::fwrite(iq.data(), sizeof(iq[0]), iq.size(), stdout);
  return 0;
}

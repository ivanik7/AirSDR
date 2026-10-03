// SPDX-License-Identifier: GPL-3.0-or-later
// White-box ring boundary test: upstream USB callbacks can exceed one slot.
// Include the implementation so we can exercise push() without any real USB
// device or a public IQ-copying API. This is not a hardware reception test.
#include "../src/sdrcore.cpp"

#include <cassert>
#include <vector>

int main() {
  SdrHandle h;
  std::vector<uint8_t> transfer(262144);
  for (size_t i = 0; i < transfer.size(); ++i) transfer[i] = i & 0xff;
  h.stats.source = SDR_RTLSDR;
  h.push(transfer.data(), transfer.size());
  assert(h.stats.input_samples == transfer.size() / 2);
  assert(h.queued == kSlots);
  assert(h.stats.dropped_samples == (transfer.size() - kSlots * kBytes) / 2);
  h.producer_done = true;
  h.consume_loop();
  assert(h.stats.processed_samples == kSlots * kBytes / 2);
  uint64_t expected = kFnvOffset;
  for (size_t i = 0; i < kSlots * kBytes; ++i)
    expected = (expected ^ transfer[i]) * kFnvPrime;
  assert(h.stats.checksum == expected);

  SdrHandle hackrf;
  hackrf.stats.source = SDR_HACKRF;
  const uint8_t signed_iq[] = {0x80, 0x7f, 0xff, 0x00};
  hackrf.push(signed_iq, sizeof(signed_iq));
  assert(hackrf.queued == 1);
  assert(hackrf.ring[0][0] == 0 && hackrf.ring[0][1] == 255);
  assert(hackrf.ring[0][2] == 127 && hackrf.ring[0][3] == 128);
  hackrf.producer_done = true;
  hackrf.consume_loop();
  assert(hackrf.stats.processed_samples == 2);
  return 0;
}

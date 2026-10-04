// SPDX-License-Identifier: GPL-3.0-or-later
#include <cassert>
#include <atomic>
#include <thread>

#include "pcm_ring.h"

int main() {
  sdrcore::PcmRing ring(3);
  float input[] = {1, 2, 3, 4, 5, 6, 7, 8};
  float output[8];
  assert(ring.push(input, 4) == 3);
  assert(ring.pop(output, 2) == 2);
  assert(output[0] == 1 && output[3] == 4);
  assert(ring.push(input + 6, 1) == 1);
  assert(ring.pop(output, 4) == 2);
  assert(output[0] == 5 && output[2] == 7);
  assert(output[4] == 0 && output[7] == 0);
  assert(ring.pop(output, 4) == 0);

  sdrcore::PcmRing concurrent(1024);
  std::atomic<bool> done{false};
  std::thread producer([&] {
    for (int i = 1; i <= 100000; ++i) {
      float frame[] = {static_cast<float>(i), -static_cast<float>(i)};
      while (concurrent.push(frame, 1) == 0) std::this_thread::yield();
    }
    done.store(true);
  });
  int last = 0;
  while (last < 100000) {
    float frame[2];
    // An empty buffer is silence, not an old sample. Avoid using that as a
    // sequence value: all produced values are strictly positive.
    concurrent.pop(frame, 1);
    if (frame[0] == 0) continue;
    assert(frame[0] == last + 1 && frame[1] == -frame[0]);
    last++;
  }
  producer.join();
  assert(done.load());
}

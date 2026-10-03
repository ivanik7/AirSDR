// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore.h"

#include <cassert>
#include <chrono>
#include <cstdint>
#include <thread>
#include <unistd.h>

static SdrStats snapshot(SdrHandle* h) {
  SdrStats s{};
  s.size = sizeof(s);
  s.revision = 2;
  assert(sdr_v2_stats(h, &s) == SDR_OK);
  return s;
}

int main() {
  SdrHandle* h = sdr_create();
  assert(h);
  SdrStats bad{};
  assert(sdr_v2_stats(h, &bad) == SDR_INVALID_ARGUMENT);
  assert(sdr_v2_start(h) == SDR_INVALID_STATE);
  assert(sdr_v2_open_usb(h, 0, SDR_RTLSDR) == SDR_UNSUPPORTED);
  assert(snapshot(h).state == SDR_IDLE);
  assert(sdr_v2_open_synthetic(h, 2400000) == SDR_OK);
  assert(sdr_v2_configure(h, 100000000, 2400000, 0) == SDR_OK);
  assert(sdr_v2_start(h) == SDR_OK);
  assert(sdr_v2_start(h) == SDR_INVALID_STATE);
  std::this_thread::sleep_for(std::chrono::milliseconds(55));
  auto running = snapshot(h);
  assert(running.state == SDR_RUNNING && running.source == SDR_SYNTHETIC);
  assert(running.input_samples > 0);
  assert(sdr_v2_stop(h) == SDR_OK);
  auto stopped = snapshot(h);
  assert(stopped.state == SDR_OPEN);
  assert(stopped.input_samples == stopped.processed_samples + stopped.dropped_samples);
  assert(stopped.checksum != 14695981039346656037ULL);
  assert(sdr_v2_start(h) == SDR_OK);
  assert(sdr_v2_stop(h) == SDR_OK);
  assert(sdr_v2_close(h) == SDR_OK);

  int pipefd[2];
  assert(pipe(pipefd) == 0);
  assert(sdr_v2_open_file(h, pipefd[0], 1000) == SDR_OK);
  assert(sdr_v2_start(h) == SDR_OK);
  const uint8_t iq[]{0, 1, 127, 255, 42, 99};
  assert(write(pipefd[1], iq, sizeof(iq)) == sizeof(iq));
  close(pipefd[1]);
  for (int i = 0; i < 50 && snapshot(h).input_samples < 3; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  assert(sdr_v2_stop(h) == SDR_OK);
  auto file = snapshot(h);
  assert(file.source == SDR_FILE && file.input_samples == 3);
  assert(file.processed_samples == 3 && file.dropped_samples == 0);
  assert(sdr_v2_close(h) == SDR_OK);
  // The library closes its duplicate, not the caller's original descriptor.
  int original = dup(pipefd[0]);
  assert(original >= 0);
  close(original);
  close(pipefd[0]);
  sdr_destroy(h);

  // A blocked pipe reader must stop and join without closing the caller's fd.
  assert(pipe(pipefd) == 0);
  h = sdr_create();
  assert(sdr_v2_open_file(h, pipefd[0], 1000) == SDR_OK);
  assert(sdr_v2_start(h) == SDR_OK);
  sdr_destroy(h);
  original = dup(pipefd[0]);
  assert(original >= 0);
  close(original);
  close(pipefd[0]);
  close(pipefd[1]);
  return 0;
}

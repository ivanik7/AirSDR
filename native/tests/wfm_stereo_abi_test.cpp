// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore_v3.h"

#include <cassert>
#include <chrono>
#include <cstdio>
#include <thread>

static SdrV3Snapshot snapshot(SdrHandle* h) {
  SdrV3Snapshot s{};
  s.size = sizeof s;
  s.revision = SDR_V3_REVISION;
  assert(sdr_v3_snapshot(h, &s) == SDR_OK);
  return s;
}

static SdrV3Fft row(SdrHandle* h, uint64_t after = 0) {
  SdrV3Fft row{};
  float bins[512]{};
  for (int i = 0; i < 100; ++i) {
    row.size = sizeof row;
    row.revision = SDR_V3_REVISION;
    if (sdr_v3_read_fft(h, after, &row, bins, 512) == SDR_OK) return row;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  assert(false && "no FFT row");
  return row;
}

int main() {
  assert(sdr_version() == 3);
  assert(sdr_v3_set_wfm_stereo(nullptr, 0) == SDR_INVALID_ARGUMENT);
  SdrHandle* h = sdr_create();
  assert(h);
  assert(sdr_v3_set_wfm_stereo(h, 0) == SDR_INVALID_STATE);
  assert(sdr_v2_open_synthetic(h, 300000) == SDR_OK);
  assert(sdr_v3_set_wfm_stereo(h, 1) == SDR_INVALID_STATE);
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = 100000000;
  c.sample_rate = 300000;
  c.mode = SDR_V3_WFM;
  c.bandwidth_hz = 150000;
  c.squelch = SDR_V3_SQUELCH_OFF;
  c.squelch_level_db = -50;
  c.volume = 1;
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  SdrV3Display d{};
  d.size = sizeof d;
  d.revision = SDR_V3_REVISION;
  d.view_bandwidth_hz = 300000;
  d.width = 512;
  assert(sdr_v3_set_display(h, &d) == SDR_OK);
  auto before = snapshot(h);
  assert(sdr_v3_set_wfm_stereo(h, 2) == SDR_INVALID_ARGUMENT);
  assert(snapshot(h).control_sequence == before.control_sequence);
  assert(sdr_v3_set_wfm_stereo(h, 1) == SDR_OK);
  assert(snapshot(h).control_sequence == before.control_sequence + 1);
  assert(sdr_v3_start(h) == SDR_OK);
  auto old = row(h);
  before = snapshot(h);
  assert(sdr_v3_set_wfm_stereo(h, 0) == SDR_OK);
  auto now = snapshot(h);
  assert(now.control_sequence == before.control_sequence + 1);
  assert(now.stream_generation == before.stream_generation);
  assert(now.state == SDR_RUNNING && now.sample_rate == before.sample_rate &&
         now.center_frequency_hz == before.center_frequency_hz);
  SdrV3Fft pending{};
  pending.size = sizeof pending;
  pending.revision = SDR_V3_REVISION;
  float bins[512]{};
  const auto rc = sdr_v3_read_fft(h, old.sequence, &pending, bins, 512);
  assert(rc == SDR_V3_NO_DATA || (rc == SDR_OK && pending.control_sequence == now.control_sequence));
  auto next = row(h, old.sequence);
  assert(next.stream_generation == now.stream_generation &&
         next.control_sequence == now.control_sequence && next.sequence > old.sequence);
  assert(sdr_v3_set_wfm_stereo(h, 1) == SDR_OK);
  assert(sdr_v3_set_wfm_stereo(h, 1) == SDR_OK);
  assert(snapshot(h).control_sequence == now.control_sequence + 2);
  assert(sdr_v3_set_wfm_stereo(h, 3) == SDR_INVALID_ARGUMENT);
  assert(snapshot(h).control_sequence == now.control_sequence + 2);
  assert(sdr_v3_stop(h) == SDR_OK);
  assert(sdr_v3_set_wfm_stereo(h, 0) == SDR_OK);
  assert(sdr_v2_close(h) == SDR_OK);
  assert(sdr_v3_set_wfm_stereo(h, 1) == SDR_INVALID_STATE);
  assert(sdr_v2_open_synthetic(h, 300000) == SDR_OK);
  // A reopened handle is unconfigured; the new receiver defaults to mono.
  assert(sdr_v3_set_wfm_stereo(h, 1) == SDR_INVALID_STATE);
  assert(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);
  std::puts("WFM stereo ABI state/epoch checks passed");
}

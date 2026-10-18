// SPDX-License-Identifier: GPL-3.0-or-later
// Behavioral ABI/lifecycle test for the additive decoder extension.
#include "sdrcore_decoder_v1.h"

#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <set>
#include <string>
#include <thread>

namespace {

bool contains(const std::string& id) {
  uint32_t count = 0;
  assert(sdr_decoder_count(&count) == SDR_OK);
  for (uint32_t i = 0; i < count; ++i) {
    SdrDecoderDescriptor d{};
    d.size = sizeof d;
    d.revision = SDR_DECODER_REVISION;
    assert(sdr_decoder_descriptor(i, &d) == SDR_OK);
    if (std::string(d.id) == id) return true;
  }
  return false;
}

SdrDecoderDescriptor find(const std::string& id) {
  uint32_t count = 0;
  assert(sdr_decoder_count(&count) == SDR_OK);
  for (uint32_t i = 0; i < count; ++i) {
    SdrDecoderDescriptor d{};
    d.size = sizeof d;
    d.revision = SDR_DECODER_REVISION;
    assert(sdr_decoder_descriptor(i, &d) == SDR_OK);
    if (std::string(d.id) == id) return d;
  }
  assert(false && "decoder id not found in registry");
  return {};
}

}  // namespace

int main() {
  // --- sdr_decoder_version(): additive discovery, independent of any handle.
  assert(sdr_decoder_version() == SDR_DECODER_REVISION);

  // --- sdr_decoder_count(): basic contract, NULL rejected.
  assert(sdr_decoder_count(nullptr) == SDR_INVALID_ARGUMENT);
  uint32_t count = 0xdeadbeef;
  assert(sdr_decoder_count(&count) == SDR_OK);
  assert(count > 0);

  // --- sdr_decoder_descriptor(): index bounds, size/revision checks, and
  // "failure leaves it unchanged" (header contract).
  SdrDecoderDescriptor probe{};
  probe.size = sizeof probe;
  probe.revision = SDR_DECODER_REVISION;
  std::memset(&probe, 0xa5, sizeof probe);
  probe.size = sizeof probe;
  probe.revision = SDR_DECODER_REVISION;
  SdrDecoderDescriptor unchanged = probe;
  assert(sdr_decoder_descriptor(count, &probe) == SDR_INVALID_ARGUMENT);
  assert(std::memcmp(&probe, &unchanged, sizeof probe) == 0);
  assert(sdr_decoder_descriptor(0, nullptr) == SDR_INVALID_ARGUMENT);
  SdrDecoderDescriptor bad_size{};
  bad_size.size = sizeof(bad_size) - 1;
  bad_size.revision = SDR_DECODER_REVISION;
  assert(sdr_decoder_descriptor(0, &bad_size) == SDR_INVALID_ARGUMENT);
  SdrDecoderDescriptor bad_rev{};
  bad_rev.size = sizeof(bad_rev);
  bad_rev.revision = 2;
  assert(sdr_decoder_descriptor(0, &bad_rev) == SDR_INVALID_ARGUMENT);

  // --- Every descriptor is well-formed and self-consistent.
  for (uint32_t i = 0; i < count; ++i) {
    SdrDecoderDescriptor d{};
    d.size = sizeof d;
    d.revision = SDR_DECODER_REVISION;
    assert(sdr_decoder_descriptor(i, &d) == SDR_OK);
    assert(d.size == sizeof d && d.revision == SDR_DECODER_REVISION);
    assert(std::strlen(d.id) > 0 && std::strlen(d.id) < sizeof(d.id));
    assert(d.input == SDR_DECODER_AUDIO || d.input == SDR_DECODER_MPX ||
           d.input == SDR_DECODER_BASEBAND || d.input == SDR_DECODER_RAW_IQ);
    assert(d.exclusive_receiver == 0 || d.exclusive_receiver == 1);
    assert(d.result == SDR_DECODER_MESSAGE || d.result == SDR_DECODER_IMAGE_PROGRESS ||
           d.result == SDR_DECODER_IMAGE_COMPLETE || d.result == SDR_DECODER_AIRCRAFT);
    assert(d.available == 0 || d.available == 1);
  }

  // --- IDs never alias (header contract).
  {
    std::set<std::string> seen;
    for (uint32_t i = 0; i < count; ++i) {
      SdrDecoderDescriptor d{};
      d.size = sizeof d;
      d.revision = SDR_DECODER_REVISION;
      assert(sdr_decoder_descriptor(i, &d) == SDR_OK);
      assert(seen.insert(std::string(d.id)).second && "duplicate decoder id");
    }
  }

  // --- Voice demodulation is explicitly NOT a decoder registry entry:
  // v3 mode/WFM stereo remain the only voice path (AGENTS.md, decoder.hpp).
  assert(!contains("voice"));

  // Registry entries expose real availability, not preview status.
  for (const char* id : {"sstv", "rtl_433", "adsb"}) {
    assert(contains(id));
    SdrDecoderDescriptor d = find(id);
    assert(d.available == 1);
  }
  const auto adsb = find("adsb");
  assert(adsb.input == SDR_DECODER_RAW_IQ);
  assert(adsb.exclusive_receiver == 0);
  assert(adsb.required_rate_hz == 2400000);
  assert(adsb.result == SDR_DECODER_AIRCRAFT);
  const auto mesh = find("meshtastic");
  assert(mesh.input == SDR_DECODER_BASEBAND);
  assert(mesh.required_rate_hz == 1000000);
  assert(mesh.result == SDR_DECODER_MESSAGE);
  assert(mesh.exclusive_receiver == 0);
  assert(mesh.available == 1); // Embedded lorarx PHY + MeshtasticParser.
  // SSTV is an audio-tap decoder valid for USB, LSB or NFM: no single
  // required mode in the descriptor; accepts_mode() gates selection.
  {
    SdrDecoderDescriptor d = find("sstv");
    assert(d.input == SDR_DECODER_AUDIO);
    assert(d.required_mode == UINT32_MAX);
    assert(d.required_rate_hz == 24000);
    assert(d.exclusive_receiver == 0);
  }

  // --- Selection cannot mutate an unopened handle; NULL/empty deselects.
  assert(sdr_decoder_select(nullptr, "sstv", 4, nullptr, 0) == SDR_INVALID_ARGUMENT);
  SdrHandle* h = sdr_create();
  assert(h);
  // Selecting on a handle that was never opened/configured: not yet OPEN/
  // RUNNING with v3 configured, so this is an invalid-state rejection rather
  // than a crash on dereferencing absent DSP state.
  assert(sdr_decoder_select(h, "sstv", 4, nullptr, 0) == SDR_INVALID_STATE);
  assert(sdr_v2_open_synthetic(h, 300000) == SDR_OK);
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
  // Unknown ID is rejected without disturbing v3 state (receiver, audio,
  // tuning). No engine exists to select regardless of ID validity.
  auto snap_before = [&]() {
    SdrV3Snapshot s{};
    s.size = sizeof s;
    s.revision = SDR_V3_REVISION;
    assert(sdr_v3_snapshot(h, &s) == SDR_OK);
    return s;
  };
  auto before = snap_before();
  assert(sdr_decoder_select(h, "meshtastic", 10, nullptr, 0) == SDR_UNSUPPORTED);
  assert(sdr_decoder_select(h, "nope", 4, nullptr, 0) == SDR_UNSUPPORTED);
  auto after = snap_before();
  assert(after.control_sequence == before.control_sequence);
  assert(after.center_frequency_hz == before.center_frequency_hz);
  const char* valid_json = "{\"version\":1,\"settings\":{}}";
  assert(sdr_decoder_select(h, "rtl_433", 7, "{", 1) == SDR_INVALID_ARGUMENT);
  assert(sdr_decoder_select(h, "rtl_433", 7, valid_json,
                            std::strlen(valid_json)) == SDR_OK);
  assert(sdr_decoder_select(h, "rtl_433", 7, "{", 1) == SDR_INVALID_ARGUMENT);
  assert(sdr_decoder_select(h, nullptr, 0, nullptr, 0) == SDR_OK);
  // SSTV cannot attach while the receiver runs WFM (audio tap is USB/LSB/
  // NFM only) and the rejection must not touch v3 state.
  before = snap_before();
  assert(sdr_decoder_select(h, "sstv", 4, valid_json, std::strlen(valid_json)) == SDR_UNSUPPORTED);
  // A missing config is malformed for SSTV (versioned settings required).
  assert(sdr_decoder_select(h, "sstv", 4, nullptr, 0) == SDR_INVALID_ARGUMENT);
  after = snap_before();
  assert(after.control_sequence == before.control_sequence);
  {
    const char* usb = "{\"version\":1,\"settings\":{\"underlying\":\"usb\",\"mode\":\"auto\"}}";
    const char* lsb = "{\"version\":1,\"settings\":{\"underlying\":\"lsb\",\"mode\":\"auto\"}}";
    const char* forced = "{\"version\":1,\"settings\":{\"underlying\":\"usb\",\"mode\":\"martin_m1\"}}";
    SdrV3Controls usb_controls = c;
    usb_controls.mode = SDR_V3_USB;
    usb_controls.bandwidth_hz = 2800;
    assert(sdr_v3_set_controls(h, &usb_controls) == SDR_OK);
    // Unknown/forced picture modes are not implemented: rejected, not ignored.
    assert(sdr_decoder_select(h, "sstv", 4, forced, std::strlen(forced)) == SDR_INVALID_ARGUMENT);
    assert(sdr_decoder_select(h, "sstv", 4, "{", 1) == SDR_INVALID_ARGUMENT);
    // An underlying demod other than the applied mode is "not ready".
    assert(sdr_decoder_select(h, "sstv", 4, lsb, std::strlen(lsb)) == SDR_UNSUPPORTED);
    before = snap_before();
    assert(sdr_decoder_select(h, "sstv", 4, usb, std::strlen(usb)) == SDR_OK);
    after = snap_before();
    // Selecting SSTV never changes tuning or mode.
    assert(after.control_sequence == before.control_sequence);
    assert(after.mode == SDR_V3_USB);
    assert(sdr_decoder_select(h, nullptr, 0, nullptr, 0) == SDR_OK);
    assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  }
  // NULL/empty ID always deselects successfully (no-op when nothing was
  // selected), and never touches v3 state either.
  before = snap_before();
  assert(sdr_decoder_select(h, nullptr, 0, nullptr, 0) == SDR_OK);
  assert(sdr_decoder_select(h, "", 0, nullptr, 0) == SDR_OK);
  after = snap_before();
  assert(after.control_sequence == before.control_sequence);
  assert(sdr_v3_start(h) == SDR_OK);
  assert(sdr_decoder_select(h, "rtl_433", 7, valid_json,
                            std::strlen(valid_json)) == SDR_OK);
  assert(sdr_decoder_select(h, "rtl_433", 7, "{", 1) == SDR_INVALID_ARGUMENT);
  assert(sdr_decoder_select(h, nullptr, 0, nullptr, 0) == SDR_OK);
  assert(sdr_v3_stop(h) == SDR_OK);

  // --- After deselect and stop, the event queue is empty (NO_DATA).
  SdrDecoderEvent event{};
  event.size = sizeof event;
  event.revision = SDR_DECODER_REVISION;
  uint8_t payload[256];
  assert(sdr_decoder_poll(h, 0, &event, payload, sizeof payload) == SDR_DECODER_NO_DATA);
  assert(sdr_decoder_poll(nullptr, 0, &event, payload, sizeof payload) == SDR_INVALID_ARGUMENT);
  assert(sdr_decoder_poll(h, 0, nullptr, payload, sizeof payload) == SDR_INVALID_ARGUMENT);
  SdrDecoderEvent bad_event_size{};
  bad_event_size.size = sizeof(bad_event_size) - 1;
  bad_event_size.revision = SDR_DECODER_REVISION;
  assert(sdr_decoder_poll(h, 0, &bad_event_size, payload, sizeof payload) == SDR_INVALID_ARGUMENT);

  assert(sdr_v3_stop(h) == SDR_INVALID_STATE);
  // ADS-B uses the normal single receiver and sends only zeroed voice frames
  // to the audio sink while selected, even though NFM remains the demod mode.
  c.sample_rate = 2400000;
  c.center_frequency_hz = 1090000000;
  c.bandwidth_hz = 12000;
  c.mode = SDR_V3_NFM;
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  assert(sdr_decoder_select(h, "adsb", 4, valid_json, std::strlen(valid_json)) == SDR_OK);
  const auto audio_before = snap_before();
  assert(sdr_v3_start(h) == SDR_OK);
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  const auto silent = snap_before();
  assert(silent.audio_frames > audio_before.audio_frames);
  assert(silent.audio_nonsilent_frames == audio_before.audio_nonsilent_frames);
  assert(sdr_v3_stop(h) == SDR_OK);
  assert(sdr_decoder_select(h, nullptr, 0, nullptr, 0) == SDR_OK);
  assert(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);

  // --- Each handle has an independent selected backend and queue.
  c.sample_rate = 300000;
  c.center_frequency_hz = 100000000;
  c.bandwidth_hz = 150000;
  c.mode = SDR_V3_WFM;
  SdrHandle* a = sdr_create();
  SdrHandle* b = sdr_create();
  assert(a && b && a != b);
  assert(sdr_v2_open_synthetic(a, 300000) == SDR_OK);
  assert(sdr_v2_open_synthetic(b, 300000) == SDR_OK);
  assert(sdr_v3_set_controls(a, &c) == SDR_OK);
  assert(sdr_v3_set_controls(b, &c) == SDR_OK);
  // Both run WFM: SSTV's audio tap is not ready on either handle.
  assert(sdr_decoder_select(a, "sstv", 4, valid_json, std::strlen(valid_json)) == SDR_UNSUPPORTED);
  assert(sdr_decoder_select(b, "sstv", 4, valid_json, std::strlen(valid_json)) == SDR_UNSUPPORTED);
  assert(sdr_decoder_select(a, "rtl_433", 7, valid_json, std::strlen(valid_json)) == SDR_OK);
  assert(sdr_decoder_select(b, "rtl_433", 7, valid_json, std::strlen(valid_json)) == SDR_OK);
  assert(sdr_v2_close(a) == SDR_OK);
  assert(sdr_v2_close(b) == SDR_OK);
  sdr_destroy(a);
  sdr_destroy(b);

  return 0;
}

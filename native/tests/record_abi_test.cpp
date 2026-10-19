// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore_record_v1.h"
#include <cassert>
#include <chrono>
#include <cstdlib>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>

namespace fs = std::filesystem;
static SdrRecordStatus status(SdrHandle* h) {
  SdrRecordStatus s{};
  s.size = sizeof(s); s.revision = SDR_RECORD_REVISION;
  assert(sdr_record_status(h, &s) == SDR_OK);
  return s;
}
static SdrRecordConfig config(uint32_t streams) {
  SdrRecordConfig c{};
  c.size = sizeof(c); c.revision = SDR_RECORD_REVISION;
  c.streams = streams;
  c.audio_format = streams & (SDR_RECORD_AUDIO | SDR_RECORD_SQUELCH_AUDIO)
      ? SDR_RECORD_WAV : SDR_RECORD_FORMAT_NONE;
  c.start_unix_ms = 1700000000000;
  return c;
}
int main() {
  uint32_t streams = 0, formats = 0;
  assert(sdr_record_version() == SDR_RECORD_REVISION);
  assert(sdr_record_capabilities(&streams, &formats) == SDR_OK);
  assert((streams & 7) == 7 && !(streams & SDR_RECORD_DECODER_LOG));
  assert(formats == (1u << SDR_RECORD_WAV));
  auto dir = fs::temp_directory_path() / "airsdr-record-abi-test";
  fs::remove_all(dir); fs::create_directories(dir);
  auto folder = std::string("file:") + dir.string();
  auto h = sdr_create(); assert(h);
  auto c = config(7);
  assert(sdr_record_start(h, &c, folder.data(), folder.size(), nullptr, 0) == SDR_INVALID_STATE);
  assert(sdr_v2_open_synthetic(h, 300000) == SDR_OK);
  SdrV3Controls controls{};
  controls.size = sizeof(controls); controls.revision = SDR_V3_REVISION;
  controls.center_frequency_hz = 100000000;
  controls.sample_rate = 300000;
  controls.mode = SDR_V3_WFM;
  controls.bandwidth_hz = 150000;
  controls.squelch = SDR_V3_SQUELCH_OFF;
  controls.squelch_level_db = -50;
  controls.volume = 0;
  controls.muted = 1;
  assert(sdr_v3_set_controls(h, &controls) == SDR_OK);
  assert(sdr_v3_set_wfm_stereo(h, 1) == SDR_OK);
  assert(sdr_v3_start(h) == SDR_OK);
  const std::string relative_folder = "file:relative";
  assert(sdr_record_start(h, &c, relative_folder.data(), relative_folder.size(), nullptr, 0) == SDR_INVALID_ARGUMENT);
  c.audio_format = SDR_RECORD_MP3;
  assert(sdr_record_start(h, &c, folder.data(), folder.size(), nullptr, 0) == SDR_UNSUPPORTED);
  c.audio_format = SDR_RECORD_WAV;
  assert(sdr_record_start(h, &c, folder.data(), folder.size(), nullptr, 0) == SDR_OK);
  assert(sdr_record_start(h, &c, folder.data(), folder.size(), nullptr, 0) == SDR_INVALID_STATE);
  std::this_thread::sleep_for(std::chrono::milliseconds(270));
  auto live = status(h);
  assert(live.state == SDR_RECORD_ACTIVE && live.iq_samples_written > 0 &&
         live.audio_frames_written > 0 && live.audio_channels == 2);
  assert(sdr_record_stop(h) == SDR_OK);
  auto done = status(h);
  assert(done.state == SDR_RECORD_IDLE && done.stop_reason == SDR_RECORD_STOP_USER &&
         done.bytes_written > 100 && done.files_created >= 4 &&
         done.segments_completed >= 1 && done.last_error == 0);
  assert(sdr_record_stop(h) == SDR_INVALID_STATE);
  bool data = false, meta = false, continuous = false, segment = false;
  uint64_t lengths = 0;
  for (const auto& entry : fs::directory_iterator(dir)) {
    auto name = entry.path().filename().string();
    lengths += entry.file_size();
    if (name.find(".sigmf-data") != std::string::npos) {
      data = true;
      assert(entry.file_size() == done.iq_samples_written * 2);
    } else if (name.find(".sigmf-meta") != std::string::npos) {
      meta = true;
      std::ifstream input(entry.path());
      std::string text((std::istreambuf_iterator<char>(input)), {});
      assert(text.find("\"core:datatype\":\"cu8\"") != std::string::npos);
      assert(text.find("\"core:sample_rate\":300000") != std::string::npos);
      assert(text.find("\"core:frequency\":100000000") != std::string::npos);
    } else if (entry.path().extension() == ".wav") {
      name.find("_sq") == std::string::npos ? continuous = true : segment = true;
      std::ifstream input(entry.path(), std::ios::binary);
      char header[44]{}; input.read(header, sizeof(header));
      assert(input.gcount() == sizeof(header));
      assert(std::string(header, 4) == "RIFF" && std::string(header + 8, 4) == "WAVE");
      assert(static_cast<unsigned char>(header[22]) == 2);
    }
  }
  assert(data && meta && continuous && segment && lengths == done.bytes_written);
  // New sessions may start while the same receiver runs; an unconfigured
  // optional format never changes the preceding session's status.
  auto previous = done.session_id;
  auto iq = config(SDR_RECORD_IQ);
  assert(sdr_record_start(h, &iq, folder.data(), folder.size(), nullptr, 0) == SDR_OK);
  assert(status(h).session_id == previous + 1);
  std::this_thread::sleep_for(std::chrono::milliseconds(110));
  controls.mode = SDR_V3_NFM;
  controls.bandwidth_hz = 12500;
  controls.sample_rate = 320000;
  controls.center_frequency_hz = 101000000;
  assert(sdr_v3_set_controls(h, &controls) == SDR_OK);
  assert(status(h).state == SDR_RECORD_ACTIVE);
  std::this_thread::sleep_for(std::chrono::milliseconds(130));
  assert(sdr_v3_stop(h) == SDR_OK);
  auto last = status(h);
  assert(last.stop_reason == SDR_RECORD_STOP_RECEIVER && last.last_error == 0 &&
         last.iq_samples_written > 0);
  bool first_rate = false, second_rate = false;
  for (const auto& entry : fs::directory_iterator(dir)) {
    if (entry.path().extension() != ".sigmf-meta") continue;
    std::ifstream input(entry.path());
    std::string text((std::istreambuf_iterator<char>(input)), {});
    if (text.find("\"core:sample_rate\":300000") != std::string::npos)
      first_rate = true;
    if (text.find("\"core:sample_rate\":320000") != std::string::npos &&
        text.find("\"core:frequency\":101000000") != std::string::npos)
      second_rate = true;
  }
  assert(first_rate && second_rate);
  assert(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);
  if (!std::getenv("SDR_RECORD_KEEP_TEST_FILES")) fs::remove_all(dir);
  std::puts("record ABI integration passed");
}

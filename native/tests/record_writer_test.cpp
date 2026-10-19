// SPDX-License-Identifier: GPL-3.0-or-later
#include "record/recorder.h"
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#ifndef _WIN32
#include <fcntl.h>
#include <unistd.h>
#endif

using namespace sdrcore::record;
namespace fs = std::filesystem;
static std::string slurp(const fs::path& p) {
  std::ifstream f(p, std::ios::binary);
  return {std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()};
}
static uint32_t le32(const std::string& s, size_t at) {
  return uint8_t(s.at(at)) | uint32_t(uint8_t(s.at(at + 1))) << 8 |
         uint32_t(uint8_t(s.at(at + 2))) << 16 | uint32_t(uint8_t(s.at(at + 3))) << 24;
}
static fs::path temp_dir() {
  auto p = fs::temp_directory_path() /
           ("record_writer_" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  fs::create_directory(p);
  return p;
}
static SdrRecordConfig config(uint32_t streams) {
  SdrRecordConfig c{};
  c.size = sizeof(c); c.revision = SDR_RECORD_REVISION;
  c.streams = streams; c.audio_format = streams & (SDR_RECORD_AUDIO | SDR_RECORD_SQUELCH_AUDIO) ? SDR_RECORD_WAV : SDR_RECORD_FORMAT_NONE;
  c.start_unix_ms = 1735689600000LL;
  return c;
}
static std::vector<fs::path> files(const fs::path& p, const std::string& ext) {
  std::vector<fs::path> v;
  for (auto& entry : fs::directory_iterator(p)) if (entry.path().extension() == ext) v.push_back(entry.path());
  return v;
}
static void notified(void* ptr, const SdrRecordStatus* s) {
  assert(s->state == SDR_RECORD_IDLE || s->state == SDR_RECORD_FAILED);
  ++*static_cast<int*>(ptr);
}
#ifndef _WIN32
static int32_t pipe_provider(void*, const char*, uint32_t, const char*,
                             uint32_t, const char*, int32_t* fd) {
  int ends[2];
  assert(pipe(ends) == 0);
  close(ends[0]);
  *fd = ends[1];
  return SDR_OK;
}
struct CollisionContext {
  fs::path dir;
  int calls = 0;
  std::string created_name;
};
static int32_t collision_provider(void* ptr, const char*, uint32_t,
                                  const char* name, uint32_t length,
                                  const char*, int32_t* fd) {
  auto& ctx = *static_cast<CollisionContext*>(ptr);
  if (++ctx.calls == 1) return SDR_RECORD_EXISTS;
  ctx.created_name.assign(name, length);
  *fd = open((ctx.dir / ctx.created_name).c_str(), O_CREAT | O_EXCL | O_RDWR, 0644);
  return *fd < 0 ? SDR_IO_ERROR : SDR_OK;
}
static int32_t always_exists(void*, const char*, uint32_t, const char*,
                             uint32_t, const char*, int32_t*) {
  return SDR_RECORD_EXISTS;
}
static int32_t throwing_provider(void*, const char*, uint32_t, const char*,
                                 uint32_t, const char*, int32_t*) {
  throw std::runtime_error("provider failure");
}
#endif
int main() {
  const auto dir = temp_dir();
  {
    Recorder r;
    int notifications = 0;
    r.set_notify(notified, &notifications);
    auto c = config(SDR_RECORD_IQ | SDR_RECORD_AUDIO | SDR_RECORD_SQUELCH_AUDIO);
    assert(r.start(c, "file:" + dir.string()) == SDR_OK);
    const uint8_t iq[] = {0, 255, 10, 20};
    r.offer_iq(iq, sizeof(iq), 1000000, 102300000, "NFM");
    float pcm[] = {-1, 0, 1, .5f, -.5f, .25f};
    r.offer_audio(pcm, 6, 1, {{0, true}, {2, false}, {4, true}}, 102300000, "NFM");
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    auto s = r.status();
    assert(s.state == SDR_RECORD_IDLE && s.stop_reason == SDR_RECORD_STOP_USER);
    assert(notifications == 1);
    assert(s.iq_samples_written == 2 && s.audio_frames_written == 6);
    assert(s.segments_completed == 2 && s.files_created == 5);
    assert(s.bytes_written == fs::file_size(files(dir, ".sigmf-data").at(0)) +
           fs::file_size(files(dir, ".sigmf-meta").at(0)) +
           fs::file_size(files(dir, ".wav").at(0)) + fs::file_size(files(dir, ".wav").at(1)) +
           fs::file_size(files(dir, ".wav").at(2)));
    auto iqdata = slurp(files(dir, ".sigmf-data").at(0));
    assert(iqdata == std::string(reinterpret_cast<const char*>(iq), sizeof(iq)));
    auto meta = slurp(files(dir, ".sigmf-meta").at(0));
    assert(meta.find("\"core:datatype\":\"cu8\"") != std::string::npos);
    assert(meta.find("\"core:frequency\":102300000") != std::string::npos);
    assert(meta.find("\"core:sample_rate\":1000000") != std::string::npos);
    uint64_t data = 0;
    for (auto& p : files(dir, ".wav")) {
      auto wav = slurp(p);
      assert(wav.substr(0, 4) == "RIFF" && wav.substr(8, 4) == "WAVE");
      assert(le32(wav, 24) == 48000 && le32(wav, 40) == wav.size() - 44);
      assert(le32(wav, 4) == wav.size() - 8);
      assert(uint8_t(wav[20]) == 1 && uint8_t(wav[22]) == 1);
      if (p.filename().string().find("_sq1") != std::string::npos) {
        assert(wav.size() == 48);
        assert(uint8_t(wav[44]) == 0 && uint8_t(wav[45]) == 128);
        assert(uint8_t(wav[46]) == 0 && uint8_t(wav[47]) == 0);
      } else if (p.filename().string().find("_sq2") != std::string::npos) {
        assert(wav.size() == 48);
      } else {
        assert(wav.size() == 56);
      }
      data += wav.size() - 44;
    }
    assert(data == 12 + 8);
  }
  {
    Recorder r;
    auto c = config(SDR_RECORD_IQ);
    assert(r.start(c, "file:" + dir.string()) == SDR_OK);
    uint8_t bytes[] = {1, 2};
    r.offer_iq(bytes, 2, 1000, 100000000, "AM");
    r.offer_iq(bytes, 2, 2000, 100000000, "AM");
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    assert(r.status().files_created == 4);
    assert(files(dir, ".sigmf-data").size() == 3);
    assert(files(dir, ".sigmf-meta").size() == 3);
  }
  {
    Recorder r;
    auto c = config(SDR_RECORD_AUDIO);
    assert(r.start(c, "file:" + dir.string()) == SDR_OK);
    std::vector<uint8_t> huge(8 * 1024 * 1024 + 2);
    r.offer_iq(huge.data(), huge.size(), 1000, 10, "AM");
    // IQ is not selected: offering it cannot fail the active audio session.
    assert(r.status().state == SDR_RECORD_ACTIVE);
    std::vector<float> audio(600000);
    r.offer_audio(audio.data(), audio.size(), 1, {}, 10, "AM");
    assert(r.status().audio_dropped_frames == audio.size());
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    assert(r.status().state == SDR_RECORD_IDLE && r.status().last_error != SDR_OK);
    assert(r.status().error_stream == SDR_RECORD_AUDIO);
  }
  {
    Recorder r;
    auto c = config(SDR_RECORD_IQ);
    assert(r.start(c, "file:" + dir.string()) == SDR_OK);
    std::vector<uint8_t> oversized(8 * 1024 * 1024 + 2);
    r.offer_iq(oversized.data(), oversized.size(), 1000, 10, "AM");
    assert(r.status().iq_dropped_samples == oversized.size() / 2);
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    assert(r.status().stop_reason == SDR_RECORD_STOP_ERROR);
    assert(r.status().error_stream == SDR_RECORD_IQ);
    assert(r.status().files_created == 0);
  }
#ifndef _WIN32
  {
    CollisionContext ctx{dir, 0, {}};
    assert(set_provider("collide", 7, collision_provider, &ctx) == SDR_OK);
    Recorder r;
    auto c = config(SDR_RECORD_AUDIO);
    assert(r.start(c, "collide:tree") == SDR_OK);
    const float pcm[] = {0.5f};
    r.offer_audio(pcm, 1, 1, {}, 91000000, "AM");
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    assert(ctx.calls == 2 && ctx.created_name.find("_AM_2.wav") != std::string::npos);
    assert(r.status().files_created == 1 && r.status().last_error == SDR_OK);
    assert(set_provider("collide", 7, nullptr, nullptr) == SDR_OK);
  }
  {
    assert(set_provider("taken", 5, always_exists, nullptr) == SDR_OK);
    Recorder r;
    auto c = config(SDR_RECORD_AUDIO);
    assert(r.start(c, "taken:tree") == SDR_OK);
    const float pcm[] = {0.5f};
    r.offer_audio(pcm, 1, 1, {}, 91000000, "AM");
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    assert(r.status().last_error == SDR_RECORD_NAME_EXHAUSTED);
    assert(r.status().files_created == 0);
    assert(set_provider("taken", 5, nullptr, nullptr) == SDR_OK);
  }
  {
    assert(set_provider("pipe", 4, pipe_provider, nullptr) == SDR_OK);
    Recorder r;
    auto c = config(SDR_RECORD_AUDIO);
    assert(r.start(c, "pipe:tree") == SDR_OK);
    const float pcm[] = {1.0f};
    r.offer_audio(pcm, 1, 1, {}, 123000000, "AM");
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    auto s = r.status();
    assert(s.state == SDR_RECORD_IDLE && s.stop_reason == SDR_RECORD_STOP_ERROR);
    assert(s.last_error == SDR_RECORD_NOT_SEEKABLE && s.error_stream == SDR_RECORD_AUDIO);
    assert(s.files_created == 0 && s.bytes_written == 0);
    assert(set_provider("pipe", 4, nullptr, nullptr) == SDR_OK);
  }
  {
    assert(set_provider("throws", 6, throwing_provider, nullptr) == SDR_OK);
    Recorder r;
    auto c = config(SDR_RECORD_AUDIO);
    assert(r.start(c, "throws:tree") == SDR_OK);
    const float pcm[] = {1.0f};
    r.offer_audio(pcm, 1, 1, {}, 123000000, "AM");
    for (int i = 0; i < 100 && r.status().state == SDR_RECORD_ACTIVE; ++i)
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    assert(r.status().state == SDR_RECORD_FAILED);
    assert(r.status().last_error == SDR_INTERNAL_ERROR);
    assert(r.status().error_stream == SDR_RECORD_AUDIO);
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    assert(set_provider("throws", 6, nullptr, nullptr) == SDR_OK);
  }
#endif
  {
    Recorder r;
    auto c = config(SDR_RECORD_SQUELCH_AUDIO);
    assert(r.start(c, "file:" + dir.string()) == SDR_OK);
    const float pcm[] = {1, 1, 1};
    r.offer_audio(pcm, 3, 1, {{0, true}}, 10, "AM");
    r.offer_audio(pcm, 3, 1, {}, 20, "AM");
    r.offer_audio(pcm, 3, 1, {{2, false}}, 20, "AM");
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    assert(r.status().segments_completed == 2);
    assert(r.status().audio_frames_written == 0);
    assert(r.status().bytes_written == 2 * 44 + 8 * 2);
  }
  {
    Recorder r;
    auto c = config(SDR_RECORD_IQ);
    assert(r.start(c, "file:" + (dir / "missing-folder").string()) == SDR_OK);
    const uint8_t iq[] = {1, 2};
    r.offer_iq(iq, sizeof(iq), 1000, 42, "AM");
    for (int i = 0; i < 100 && r.status().state == SDR_RECORD_ACTIVE; ++i)
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    assert(r.status().state == SDR_RECORD_FAILED);
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    const auto s = r.status();
    assert(s.last_error == SDR_RECORD_FOLDER_UNAVAILABLE);
    assert(s.stop_reason == SDR_RECORD_STOP_ERROR && s.error_stream == SDR_RECORD_IQ);
    assert(s.files_created == 0 && s.bytes_written == 0);
    assert(r.start(c, "file:" + dir.string()) == SDR_OK);
    r.offer_iq(iq, sizeof(iq), 1000, 42, "AM");
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    assert(r.status().state == SDR_RECORD_IDLE && r.status().last_error == 0);
    assert(r.status().session_id == s.session_id + 1);
  }
  {
    Recorder r;
    auto c = config(SDR_RECORD_SQUELCH_AUDIO);
    assert(r.start(c, "file:" + dir.string()) == SDR_OK);
    const float pcm[] = {0.25f, 0.5f, -0.5f};
    // With squelch disabled the DSP emits one open edge, then none. An
    // uninterrupted session must yield exactly one file including all frames.
    r.offer_audio(pcm, 3, 1, {{0, true}}, 97000000, "AM");
    r.offer_audio(pcm, 3, 1, {}, 97000000, "AM");
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    assert(r.status().segments_completed == 1);
    assert(r.status().bytes_written == 44 + 6 * 2);
  }
  {
    Recorder r;
    auto c = config(SDR_RECORD_SQUELCH_AUDIO);
    assert(r.start(c, "file:" + dir.string()) == SDR_OK);
    const float pcm[] = {0.25f, 0.5f, -0.5f};
    // The detector may already be open when recording starts. There is no
    // opening edge in that case, but all three initial frames belong to it.
    r.offer_audio(pcm, 3, 1, {}, 98000000, "AM", true);
    r.offer_audio(pcm, 3, 1, {{2, false}}, 98000000, "AM", false);
    assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
    assert(r.status().segments_completed == 1);
    assert(r.status().bytes_written == 44 + 5 * 2);
  }
  fs::remove_all(dir);
}

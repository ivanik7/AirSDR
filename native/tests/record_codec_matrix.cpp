// SPDX-License-Identifier: GPL-3.0-or-later
#include "record/recorder.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using namespace sdrcore::record;
int main(int argc, char** argv) {
  assert(argc == 2);
  const fs::path root(argv[1]);
  for (uint32_t format = SDR_RECORD_WAV; format <= SDR_RECORD_OPUS; ++format) {
    for (uint32_t channels : {1u, 2u}) {
      for (uint32_t streams : {uint32_t(SDR_RECORD_AUDIO),
                               uint32_t(SDR_RECORD_SQUELCH_AUDIO),
                               uint32_t(SDR_RECORD_AUDIO | SDR_RECORD_SQUELCH_AUDIO)}) {
        auto dir = root / (std::to_string(format) + "-" + std::to_string(channels) +
                           "-" + std::to_string(streams));
        fs::create_directories(dir);
        SdrRecordConfig c{};
        c.size = sizeof(c); c.revision = SDR_RECORD_REVISION;
        c.start_unix_ms = 1735689600000LL; c.streams = streams;
        c.audio_format = format;
        c.audio_bitrate_kbps = format == SDR_RECORD_MP3 ? 128 :
                               format == SDR_RECORD_OPUS ? 96 : 0;
        Recorder r;
        assert(r.start(c, "file:" + dir.string()) == SDR_OK);
        for (size_t block = 0; block < 10; ++block) {
          std::vector<float> pcm(4800 * channels);
          for (size_t frame = 0; frame < 4800; ++frame) {
            const double t = double(block * 4800 + frame) / 48000.0;
            pcm[frame * channels] = 0.55f * std::sin(2 * 3.141592653589793 * 440 * t);
            if (channels == 2)
              pcm[frame * 2 + 1] = 0.35f * std::sin(2 * 3.141592653589793 * 770 * t);
          }
          std::vector<Edge> edges;
          if (block == 0 || block == 5) edges.push_back({0, true});
          if (block == 2 || block == 7) edges.push_back({0, false});
          r.offer_audio(pcm.data(), 4800, channels, edges, 100000000, "WFM");
        }
        assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
        auto status = r.status();
        if (status.last_error || status.state != SDR_RECORD_IDLE) {
          std::fprintf(stderr, "format=%u channels=%u streams=%u error=%d\n",
                       format, channels, streams, status.last_error);
          return 1;
        }
        assert(status.audio_sample_rate == 48000 && status.audio_channels == channels);
        assert(status.audio_dropped_frames == 0);
        assert(status.audio_frames_written == ((streams & SDR_RECORD_AUDIO) ? 48000u : 0u));
        assert(status.segments_completed == ((streams & SDR_RECORD_SQUELCH_AUDIO) ? 2u : 0u));
        assert(status.files_created == ((streams & SDR_RECORD_AUDIO) ? 1u : 0u) +
               ((streams & SDR_RECORD_SQUELCH_AUDIO) ? 2u : 0u));
        uint64_t bytes = 0;
        for (const auto& file : fs::directory_iterator(dir)) bytes += file.file_size();
        assert(bytes == status.bytes_written);
      }
    }
  }
  for (uint32_t format = SDR_RECORD_WAV; format <= SDR_RECORD_OPUS; ++format) {
    for (size_t frames : {123u, 1000u}) {
      auto dir = root / ("short-" + std::to_string(format) + "-" + std::to_string(frames));
      fs::create_directories(dir);
      auto c = SdrRecordConfig{};
      c.size = sizeof(c); c.revision = SDR_RECORD_REVISION;
      c.start_unix_ms = 1735689600000LL; c.streams = SDR_RECORD_AUDIO;
      c.audio_format = format;
      c.audio_bitrate_kbps = format == SDR_RECORD_MP3 ? 128 :
                             format == SDR_RECORD_OPUS ? 96 : 0;
      Recorder r;
      assert(r.start(c, "file:" + dir.string()) == SDR_OK);
      std::vector<float> pcm(frames, .25f);
      r.offer_audio(pcm.data(), frames, 1, {}, 100000000, "NFM");
      assert(r.stop(SDR_RECORD_STOP_USER) == SDR_OK);
      assert(r.status().last_error == 0 && r.status().audio_frames_written == frames);
    }
  }
  return 0;
}

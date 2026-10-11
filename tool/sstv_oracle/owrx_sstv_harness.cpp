// SPDX-License-Identifier: GPL-3.0-or-later
//
// Offline test oracle: the OpenWebRX+ SSTV decoder stage, built against a
// PRISTINE csdr-plus checkout (no sdr_flutter patches), driven the way the
// csdr command-line runner drives a Module.
//
// OpenWebRX+ (csdr/chain/digimodes.py::SstvDemodulator) constructs
// SstvDecoder(24000, 300000) on a fixed 24 kHz audio stream and pipes its
// byte output into owrx/sstv.py::SstvParser. This harness reproduces that
// decoder stage: it reads a 24 kHz mono WAV (s16 or float32), feeds it in
// blocks of at most 1024 samples (csdr's Command::runModule clamps each
// stdin read to 1024 elements and then loops `while canProcess() process()`)
// and writes the raw decoder byte stream (debug text + BMP header + BGR
// rows) to stdout. owrx_parser.py turns that stream into OpenWebRX+ parser
// output.
//
// It is never built into the app and never run as an app subprocess.
//
// With --progress FILE, one "<input samples fed> <total bytes written>" line
// is appended whenever the output grew during a block, so row timing can be
// compared with the native backend's events.
//
// Usage: owrx_sstv_harness [--dbg-time MS] [--block N] [--progress F] input.wav > out.bin
#include "sstv.hpp"
#include "reader.hpp"
#include "writer.hpp"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

class VecReader : public Csdr::Reader<float> {
 public:
  std::vector<float> buf;
  size_t pos = 0;
  size_t available() override { return buf.size() - pos; }
  float* getReadPointer() override { return buf.data() + pos; }
  void advance(size_t n) override {
    pos += std::min(n, buf.size() - pos);
    // Keep memory bounded like a ring buffer would.
    if (pos > (1u << 20)) {
      buf.erase(buf.begin(), buf.begin() + pos);
      pos = 0;
    }
  }
  void wait() override {}
  void unblock() override {}
};

// Same capacity as csdr's StdoutWriter default (10240 bytes); every
// advance() goes straight to stdout.
class StdoutBytes : public Csdr::Writer<unsigned char> {
 public:
  std::vector<unsigned char> scratch = std::vector<unsigned char>(10240);
  uint64_t total = 0;
  size_t writeable() override { return scratch.size(); }
  unsigned char* getWritePointer() override { return scratch.data(); }
  void advance(size_t n) override {
    std::fwrite(scratch.data(), 1, n, stdout);
    total += n;
  }
};

uint32_t le32(const unsigned char* p) {
  return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

bool read_wav(const char* path, std::vector<float>& out, uint32_t& rate) {
  FILE* f = std::fopen(path, "rb");
  if (!f) return false;
  std::vector<unsigned char> all;
  unsigned char tmp[65536];
  size_t n;
  while ((n = std::fread(tmp, 1, sizeof tmp, f)) > 0) all.insert(all.end(), tmp, tmp + n);
  std::fclose(f);
  if (all.size() < 12 || std::memcmp(all.data(), "RIFF", 4) || std::memcmp(all.data() + 8, "WAVE", 4))
    return false;
  uint16_t format = 0, channels = 0, bits = 0;
  size_t off = 12;
  while (off + 8 <= all.size()) {
    const uint32_t size = le32(&all[off + 4]);
    const unsigned char* body = &all[off + 8];
    if (!std::memcmp(&all[off], "fmt ", 4)) {
      format = body[0] | (body[1] << 8);
      channels = body[2] | (body[3] << 8);
      rate = le32(body + 4);
      bits = body[14] | (body[15] << 8);
    } else if (!std::memcmp(&all[off], "data", 4)) {
      if (channels != 1) return false;
      const size_t avail = std::min<size_t>(size, all.size() - off - 8);
      if (format == 1 && bits == 16) {
        for (size_t i = 0; i + 1 < avail; i += 2)
          out.push_back(static_cast<int16_t>(body[i] | (body[i + 1] << 8)) / 32768.0f);
      } else if (format == 3 && bits == 32) {
        out.resize(avail / 4);
        std::memcpy(out.data(), body, out.size() * 4);
      } else {
        return false;
      }
      return true;
    }
    off += 8 + size + (size & 1);
  }
  return false;
}

}  // namespace

int main(int argc, char** argv) {
  unsigned int dbg_time = 300000;  // OpenWebRX+ SstvDemodulator.dbgTime
  size_t block = 1024;             // csdr Command::runModule read clamp
  const char* path = nullptr;
  const char* progress_path = nullptr;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--dbg-time") && i + 1 < argc) dbg_time = std::strtoul(argv[++i], nullptr, 10);
    else if (!std::strcmp(argv[i], "--block") && i + 1 < argc) block = std::strtoul(argv[++i], nullptr, 10);
    else if (!std::strcmp(argv[i], "--progress") && i + 1 < argc) progress_path = argv[++i];
    else path = argv[i];
  }
  if (!path || block == 0) {
    std::fprintf(stderr, "usage: %s [--dbg-time MS] [--block N] input.wav\n", argv[0]);
    return 2;
  }
  std::vector<float> audio;
  uint32_t rate = 0;
  if (!read_wav(path, audio, rate) || rate != 24000) {
    std::fprintf(stderr, "need a mono 24000 Hz s16/float32 WAV: %s\n", path);
    return 2;
  }
  VecReader reader;
  StdoutBytes writer;
  FILE* progress = progress_path ? std::fopen(progress_path, "w") : nullptr;
  Csdr::SstvDecoder<float> decoder(24000, dbg_time);
  decoder.setReader(&reader);
  decoder.setWriter(&writer);
  for (size_t off = 0; off < audio.size(); off += block) {
    const size_t n = std::min(block, audio.size() - off);
    reader.buf.insert(reader.buf.end(), audio.begin() + off, audio.begin() + off + n);
    const uint64_t before = writer.total;
    while (decoder.canProcess()) decoder.process();
    if (progress && writer.total != before)
      std::fprintf(progress, "%zu %llu\n", off + n, static_cast<unsigned long long>(writer.total));
  }
  std::fflush(stdout);
  if (progress) std::fclose(progress);
  return 0;
}

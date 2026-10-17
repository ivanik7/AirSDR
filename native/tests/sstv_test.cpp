// SPDX-License-Identifier: GPL-3.0-or-later
//
// Native tests for the csdr-plus SSTV backend (native/src/decoder/sstv.cpp)
// and its feed from the receiver's 24 kHz audio tap. Signals come from the
// independent test encoder in sstv_test_encoder.hpp; nothing here mocks the
// decoder. Covered:
//   - configure()/accepts_mode() contract (settings v1: auto only),
//   - VIS detection for every encoder mode, parity and unmapped-VIS rejects,
//   - frozen v1 event framing (start, ordered rows, image_complete),
//   - byte parity with the vendored upstream SstvDecoder fed identically,
//   - upstream per-line sync realignment under transmitter clock drift
//     (slant) for Martin and Scottie, Scottie start-sync timeout,
//   - reset on retune/mode change (partial completion, no stale rows),
//   - end-to-end decode through Receiver for USB, LSB and NFM, and
//     receiver-driven retune/mode/bandwidth behaviour.
#include "../src/dsp/receiver.h"
#include "decoder.hpp"
#include "sstv.hpp"
#include "sstv_test_encoder.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace sdrcore::decoder {
std::unique_ptr<Decoder> create_sstv();
}

namespace {

using sdrcore::decoder::Decoder;
using sdrcore::decoder::Event;
using sdrcore::decoder::Result;
using sstv_test::Mode;

constexpr double kPi = 3.14159265358979323846;
int failures = 0;

#define CHECK(cond, ...)                                        \
  do {                                                          \
    if (!(cond)) {                                              \
      std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
      std::fprintf(stderr, __VA_ARGS__);                        \
      std::fprintf(stderr, "\n");                               \
      ++failures;                                               \
    } else {                                                    \
      std::printf("[ok] ");                                     \
      std::printf(__VA_ARGS__);                                 \
      std::printf("\n");                                        \
    }                                                           \
  } while (0)

const char* kUsbAuto = R"({"version":1,"settings":{"underlying":"usb","mode":"auto"}})";

// PSNR floors. Measured on x86-64 (values are printed by each check):
// clean flat areas 27.6-28.8 dB for all five modes, the same through the
// USB/LSB/NFM receiver tap (28.0 dB), and 20.1 dB at 10 dB audio SNR.
// Floors sit ~3 dB below so FFT/libm rounding differences across targets
// cannot flip them, while a channel swap, colour-matrix error, line
// misalignment or level error (all of which cost >10 dB) still fails.
constexpr double kCleanInteriorPsnr = 25.0;
constexpr double kNoisyInteriorPsnr = 17.0;
constexpr double kReceiverInteriorPsnr = 25.0;

// --- Event collection ----------------------------------------------------

std::vector<uint8_t> base64_decode(const std::string& in) {
  auto val = [](char c) -> int {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
  };
  std::vector<uint8_t> out;
  uint32_t acc = 0;
  int bits = 0;
  for (char c : in) {
    const int v = val(c);
    if (v < 0) continue;
    acc = (acc << 6) | static_cast<uint32_t>(v);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<uint8_t>((acc >> bits) & 0xFF));
    }
  }
  return out;
}

struct Frame {
  nlohmann::json start;
  std::vector<nlohmann::json> line_meta;  // line events without pixels
  std::vector<std::vector<uint8_t>> rows;  // BGR, width*3 each
  std::vector<bool> padded;
  nlohmann::json complete;  // null until image_complete
  bool well_formed = true;
};

struct Collector {
  std::vector<Frame> frames;
  int orphan_events = 0;
  size_t max_payload = 0;

  void take_all(Decoder& d) {
    Event e;
    while (d.take_event(e)) {
      max_payload = std::max(max_payload, e.payload.size());
      const auto j = nlohmann::json::parse(e.payload.begin(), e.payload.end(), nullptr, false);
      if (j.is_discarded() || j.value("source", "") != "sstv" || j.value("version", 0) != 1) {
        ++orphan_events;
        continue;
      }
      if (e.kind == Result::image_progress && j.value("phase", "") == "start") {
        Frame f;
        f.start = j;
        f.well_formed = j["line"].is_null() && j["pixels_bgr_base64"].is_null() &&
                        j["padded"].is_null();
        frames.push_back(std::move(f));
        continue;
      }
      if (frames.empty() || frames.back().start["frame_id"] != j["frame_id"] ||
          !frames.back().complete.is_null()) {
        ++orphan_events;
        continue;
      }
      Frame& f = frames.back();
      for (const char* key : {"vis", "sstv_mode", "width", "height", "timestamp_utc",
                              "frequency_hz", "underlying"})
        if (f.start[key] != j[key]) f.well_formed = false;
      if (e.kind == Result::image_progress) {
        const int width = f.start["width"].get<int>();
        if (j["line"] != static_cast<int>(f.rows.size())) f.well_formed = false;
        auto px = base64_decode(j["pixels_bgr_base64"].get<std::string>());
        if (px.size() != static_cast<size_t>(width) * 3) f.well_formed = false;
        f.rows.push_back(std::move(px));
        f.padded.push_back(j["padded"].get<bool>());
        nlohmann::json meta = j;
        meta.erase("pixels_bgr_base64");
        f.line_meta.push_back(std::move(meta));
      } else if (e.kind == Result::image_complete) {
        f.complete = j;
      } else {
        ++orphan_events;
      }
    }
  }
};

void feed_chunks(Decoder& d, const std::vector<float>& audio, Collector& c, size_t chunk = 1000,
                 size_t begin = 0, size_t end = SIZE_MAX) {
  end = std::min(end, audio.size());
  for (size_t off = begin; off < end; off += chunk) {
    const size_t n = std::min(chunk, end - off);
    d.process(audio.data() + off, n, 24000);
    c.take_all(d);
  }
}

std::unique_ptr<Decoder> make_backend(uint64_t freq = 14230000, uint32_t mode = SDR_V3_USB) {
  auto d = sdrcore::decoder::create_sstv();
  if (!d || !d->configure(kUsbAuto)) return nullptr;
  d->set_tuning(freq, mode);
  d->reset();
  return d;
}

std::vector<float> silence(double seconds) {
  return std::vector<float>(static_cast<size_t>(seconds * 24000), 0.0f);
}

std::vector<float> with_trailer(std::vector<float> audio, double seconds = 3.0) {
  const auto tail = silence(seconds);
  audio.insert(audio.end(), tail.begin(), tail.end());
  return audio;
}

// PSNR (dB) of the decoded BGR rows against the RGB source image.
double psnr(const std::vector<uint8_t>& rgb, const Frame& f, int width, int height) {
  double se = 0;
  size_t n = 0;
  for (int y = 0; y < height && y < static_cast<int>(f.rows.size()); ++y) {
    for (int x = 0; x < width; ++x) {
      for (int c = 0; c < 3; ++c) {
        const double src = rgb[(static_cast<size_t>(y) * width + x) * 3 + c];
        const double dec = f.rows[y][static_cast<size_t>(x) * 3 + (2 - c)];
        se += (src - dec) * (src - dec);
        ++n;
      }
    }
  }
  if (n == 0) return 0;
  const double mse = se / n;
  return mse <= 0 ? 99.0 : 10 * std::log10(255.0 * 255.0 / mse);
}

// Upstream estimates every pixel from one FFT window that spans
// WINDOW_FACTOR pixel times (7.7 for Robot 36), so it cannot resolve the
// test pattern's hard bar edges or its 2 px diagonal: whole-image PSNR on
// this saturated pattern is bounded by that smear, not by adapter quality.
// This variant scores only pixels at least `margin` px away from every bar
// boundary, the image border and the diagonal, i.e. the flat areas where
// levels, colour conversion and line alignment are all fully observable.
double interior_psnr(const std::vector<uint8_t>& rgb, const Frame& f, int width, int height,
                     int margin) {
  double se = 0;
  size_t n = 0;
  for (int y = 0; y < height && y < static_cast<int>(f.rows.size()); ++y) {
    const int diag_x = (width - (y * width / height) % width) % width;  // diag == 0 here
    for (int x = margin; x < width - margin; ++x) {
      const int bar_pos = (x * 8) % width;  // distance (in 1/8 px) past the last boundary
      const int to_prev = bar_pos / 8, to_next = (width - bar_pos) / 8;
      if (std::min(to_prev, to_next) < margin) continue;
      int dd = std::abs(x - diag_x);
      dd = std::min(dd, width - dd);
      if (dd < margin + 2) continue;
      for (int c = 0; c < 3; ++c) {
        const double src = rgb[(static_cast<size_t>(y) * width + x) * 3 + c];
        const double dec = f.rows[y][static_cast<size_t>(x) * 3 + (2 - c)];
        se += (src - dec) * (src - dec);
        ++n;
      }
    }
  }
  if (n == 0) return 0;
  const double mse = se / n;
  return mse <= 0 ? 99.0 : 10 * std::log10(255.0 * 255.0 / mse);
}

// Upstream window width, in pixels, of the given mode (read from the
// vendored mode class itself, not restated here).
int window_margin(Mode mode) {
  double wf = 1;
  switch (mode) {
    case Mode::kMartin1: wf = Csdr::Martin1().WINDOW_FACTOR; break;
    case Mode::kScottie1: wf = Csdr::Scottie1().WINDOW_FACTOR; break;
    case Mode::kRobot36: wf = Csdr::Robot36().WINDOW_FACTOR; break;
    case Mode::kPd90: wf = Csdr::PD90().WINDOW_FACTOR; break;
    case Mode::kPd290: wf = Csdr::PD290().WINDOW_FACTOR; break;
  }
  return static_cast<int>(std::ceil(wf)) + 2;
}

// Debug aid: with SSTV_TEST_DUMP_DIR set, decoded frames are written as
// 24-bit top-down BMP files there for visual inspection.
void dump_ppm(const std::string& name, const Frame& f, int width) {
  const char* dir = std::getenv("SSTV_TEST_DUMP_DIR");
  if (!dir || f.rows.empty()) return;
  std::string file = std::string(dir) + "/" + name + ".bmp";
  for (char& ch : file)
    if (ch == ' ') ch = '_';
  FILE* fp = std::fopen(file.c_str(), "wb");
  if (!fp) return;
  const uint32_t stride = (static_cast<uint32_t>(width) * 3 + 3) & ~3u;
  const int32_t height = static_cast<int32_t>(f.rows.size());
  const uint32_t data = stride * static_cast<uint32_t>(height);
  uint8_t h[54] = {'B', 'M'};
  auto put32 = [&](int off, uint32_t v) {
    for (int i = 0; i < 4; ++i) h[off + i] = static_cast<uint8_t>(v >> (8 * i));
  };
  put32(2, 54 + data);
  put32(10, 54);
  put32(14, 40);
  put32(18, static_cast<uint32_t>(width));
  put32(22, static_cast<uint32_t>(-height));
  h[26] = 1;
  h[28] = 24;
  put32(34, data);
  std::fwrite(h, 1, sizeof h, fp);
  const uint8_t pad[4] = {};
  for (const auto& row : f.rows) {
    std::fwrite(row.data(), 1, row.size(), fp);
    std::fwrite(pad, 1, stride - row.size(), fp);
  }
  std::fclose(fp);
}

// Position (sub-pixel) of the first falling edge of the blue channel, i.e.
// the white->yellow bar boundary at x = width/8 of the test pattern.
double blue_edge(const std::vector<uint8_t>& row, int width) {
  const int lo = width / 16, hi = width * 3 / 16;
  for (int x = lo; x < hi; ++x) {
    const int b0 = row[static_cast<size_t>(x) * 3], b1 = row[static_cast<size_t>(x + 1) * 3];
    if (b0 >= 128 && b1 < 128) return x + static_cast<double>(b0 - 128) / std::max(1, b0 - b1);
  }
  return -1;
}

double median_edge(const Frame& f, int width, int from, int to) {
  std::vector<double> e;
  for (int y = from; y < to && y < static_cast<int>(f.rows.size()); ++y) {
    const double v = blue_edge(f.rows[y], width);
    if (v >= 0) e.push_back(v);
  }
  if (e.empty()) return -1;
  std::nth_element(e.begin(), e.begin() + e.size() / 2, e.end());
  return e[e.size() / 2];
}

// --- Upstream harness ------------------------------------------------------
// Drives the vendored Csdr::SstvDecoder<float> directly with plain buffers,
// in exactly the same chunking as the adapter, and returns its raw BMP byte
// stream. The adapter's rows must reproduce this stream byte for byte.
class VecReader : public Csdr::Reader<float> {
 public:
  std::vector<float> buf;
  size_t pos = 0;
  size_t available() override { return buf.size() - pos; }
  float* getReadPointer() override { return buf.data() + pos; }
  void advance(size_t n) override { pos += std::min(n, buf.size() - pos); }
  void wait() override {}
  void unblock() override {}
};
class VecWriter : public Csdr::Writer<unsigned char> {
 public:
  std::vector<uint8_t> bytes;
  std::vector<uint8_t> scratch = std::vector<uint8_t>(256 * 1024);
  size_t writeable() override { return scratch.size(); }
  unsigned char* getWritePointer() override { return scratch.data(); }
  void advance(size_t n) override { bytes.insert(bytes.end(), scratch.begin(), scratch.begin() + n); }
};

std::vector<uint8_t> upstream_bytes(const std::vector<float>& audio, size_t chunk) {
  VecReader reader;
  VecWriter writer;
  Csdr::SstvDecoder<float> engine(24000, 0);
  engine.setReader(&reader);
  engine.setWriter(&writer);
  for (size_t off = 0; off < audio.size(); off += chunk) {
    const size_t n = std::min(chunk, audio.size() - off);
    reader.buf.insert(reader.buf.end(), audio.begin() + off, audio.begin() + off + n);
    while (engine.canProcess()) engine.process();
  }
  return writer.bytes;
}

// --- Tests -----------------------------------------------------------------

void test_configure_contract() {
  auto d = sdrcore::decoder::create_sstv();
  CHECK(d != nullptr, "create_sstv() returns a real backend");
  if (!d) return;
  CHECK(d->configure(kUsbAuto), "v1 usb/auto accepted");
  CHECK(d->configure(R"({"version":1,"settings":{}})"), "v1 with defaults accepted");
  CHECK(d->configure(R"({"version":1,"settings":{"underlying":"nfm"}})"), "v1 nfm accepted");
  CHECK(!d->configure(R"({"version":1,"settings":{"mode":"martin_m1"}})"),
        "forced picture mode rejected (not implemented upstream)");
  CHECK(!d->configure(R"({"version":1,"settings":{"underlying":"wfm"}})"), "underlying wfm rejected");
  CHECK(!d->configure(R"({"version":2,"settings":{}})"), "unknown settings version rejected");
  CHECK(!d->configure(R"({"version":1,"settings":{"extra":1}})"), "unknown key rejected");
  CHECK(!d->configure("{"), "malformed JSON rejected");
  CHECK(!d->configure(""), "empty config rejected");

  auto any = sdrcore::decoder::create_sstv();
  any->configure(R"({"version":1,"settings":{}})");
  CHECK(any->accepts_mode(SDR_V3_USB) && any->accepts_mode(SDR_V3_LSB) &&
            any->accepts_mode(SDR_V3_NFM),
        "no underlying pinned: USB, LSB and NFM accepted");
  CHECK(!any->accepts_mode(SDR_V3_WFM) && !any->accepts_mode(SDR_V3_AM) &&
            !any->accepts_mode(SDR_V3_CW),
        "WFM/AM/CW never accepted");
  auto lsb = sdrcore::decoder::create_sstv();
  lsb->configure(R"({"version":1,"settings":{"underlying":"lsb","mode":"auto"}})");
  CHECK(lsb->accepts_mode(SDR_V3_LSB) && !lsb->accepts_mode(SDR_V3_USB),
        "underlying=lsb pins the accepted mode to LSB");
}

struct ModeCase {
  Mode mode;
  double min_interior_psnr;  // flat-area PSNR, see interior_psnr()
  double min_full_psnr;      // whole-image PSNR, bounded by upstream's window smear
};

// VIS detection, event framing, upstream byte parity and PSNR per mode.
void test_vis_and_framing(const ModeCase& mc) {
  const auto info = sstv_test::mode_info(mc.mode);
  const auto rgb = sstv_test::make_test_pattern(info.width, info.height, 7);
  const auto audio = with_trailer(sstv_test::encode(mc.mode, rgb, info.width, info.height, 24000));
  auto d = make_backend(14230000, SDR_V3_USB);
  Collector c;
  const auto t0 = std::chrono::steady_clock::now();
  feed_chunks(*d, audio, c, 1000);
  const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  CHECK(c.frames.size() == 1, "%s: exactly one frame detected (got %zu)", info.name, c.frames.size());
  if (c.frames.size() != 1) return;
  const Frame& f = c.frames[0];
  CHECK(f.start["vis"] == info.vis && f.start["sstv_mode"] == info.name &&
            f.start["width"] == info.width && f.start["height"] == info.height,
        "%s: VIS %d detected with upstream name and %dx%d", info.name, info.vis, info.width,
        info.height);
  CHECK(f.start["frequency_hz"] == 14230000 && f.start["underlying"] == "usb",
        "%s: start stamped with applied frequency/underlying", info.name);
  CHECK(f.start["frame_id"].is_string() && f.start["frame_id"].get<std::string>() != "0" &&
            f.start["timestamp_utc"].get<std::string>().back() == 'Z',
        "%s: frame_id is a non-zero decimal string and timestamp is UTC", info.name);
  CHECK(f.well_formed && c.orphan_events == 0,
        "%s: ordered rows, exact width*3 BGR, metadata repeated (orphans=%d)", info.name,
        c.orphan_events);
  CHECK(static_cast<int>(f.rows.size()) == info.height, "%s: %d rows emitted (got %zu)", info.name,
        info.height, f.rows.size());
  const int padded = static_cast<int>(std::count(f.padded.begin(), f.padded.end(), true));
  CHECK(!f.complete.is_null() && f.complete["status"] == "complete" && f.complete["reason"] == "end" &&
            f.complete["received_lines"] == info.height && f.complete["padded_lines"] == padded,
        "%s: image_complete complete/end, received=%d padded=%d", info.name, info.height, padded);
  CHECK(c.max_payload <= 65536, "%s: largest payload %zu bytes <= 64 KiB", info.name, c.max_payload);

  // Byte parity with the vendored upstream engine fed identically.
  const auto up = upstream_bytes(audio, 1000);
  std::vector<uint8_t> mine;
  for (const auto& r : f.rows) mine.insert(mine.end(), r.begin(), r.end());
  const bool same = up.size() == 54 + mine.size() &&
                    std::equal(mine.begin(), mine.end(), up.begin() + 54) &&
                    up[0] == 'B' && up[1] == 'M' && up[6] == info.vis && up[7] == 0x73;
  CHECK(same, "%s: rows are byte-identical to upstream SstvDecoder output (%zu vs %zu+54 bytes)",
        info.name, up.size(), mine.size());

  dump_ppm(info.name, f, info.width);
  const double full = psnr(rgb, f, info.width, info.height);
  const double inner = interior_psnr(rgb, f, info.width, info.height, window_margin(mc.mode));
  CHECK(inner >= mc.min_interior_psnr && full >= mc.min_full_psnr,
        "%s: PSNR vs source flat areas %.2f dB >= %.1f, whole image %.2f dB >= %.1f "
        "(decode %.2f s for %.1f s audio)",
        info.name, inner, mc.min_interior_psnr, full, mc.min_full_psnr, secs,
        audio.size() / 24000.0);
}

void test_vis_rejects() {
  const auto info = sstv_test::mode_info(Mode::kRobot36);
  const auto rgb = sstv_test::make_test_pattern(info.width, info.height, 3);
  {
    sstv_test::EncodeOptions o;
    o.corrupt_parity = true;
    auto audio = sstv_test::encode(Mode::kRobot36, rgb, info.width, info.height, 24000, o);
    audio.resize(std::min<size_t>(audio.size(), 24000 * 8));
    audio = with_trailer(audio);
    auto d = make_backend();
    Collector c;
    feed_chunks(*d, audio, c);
    CHECK(c.frames.empty() && c.orphan_events == 0,
          "VIS with odd parity is rejected: no frame announced (frames=%zu)", c.frames.size());
  }
  {
    sstv_test::EncodeOptions o;
    o.vis_override = 68;  // AVT-90: defined upstream but deliberately unmapped.
    auto audio = sstv_test::encode(Mode::kRobot36, rgb, info.width, info.height, 24000, o);
    audio.resize(std::min<size_t>(audio.size(), 24000 * 8));
    audio = with_trailer(audio);
    auto d = make_backend();
    Collector c;
    feed_chunks(*d, audio, c);
    CHECK(c.frames.empty(), "AVT-90 (VIS 68, disabled upstream) is not decoded (frames=%zu)",
          c.frames.size());
  }
  {
    // A Robot 36 transmission with a +40 Hz audio offset still decodes
    // (upstream header tolerance is +/-50 Hz).
    sstv_test::EncodeOptions o;
    o.freq_offset_hz = 40;
    const auto audio = with_trailer(sstv_test::encode(Mode::kRobot36, rgb, info.width, info.height, 24000, o));
    auto d = make_backend();
    Collector c;
    feed_chunks(*d, audio, c);
    CHECK(c.frames.size() == 1 && c.frames[0].start["vis"] == 8 &&
              c.frames[0].rows.size() == static_cast<size_t>(info.height),
          "+40 Hz audio offset: Robot 36 still detected and fully decoded");
  }
  {
    // Noise: 10 dB SNR (in the 12 kHz audio bandwidth) still decodes.
    sstv_test::EncodeOptions o;
    o.add_noise = true;
    o.noise_snr_db = 10;
    const auto audio = with_trailer(sstv_test::encode(Mode::kRobot36, rgb, info.width, info.height, 24000, o));
    auto d = make_backend();
    Collector c;
    feed_chunks(*d, audio, c);
    const bool ok = c.frames.size() == 1 && c.frames[0].rows.size() == static_cast<size_t>(info.height);
    CHECK(ok, "10 dB SNR: Robot 36 detected and fully decoded");
    if (ok) {
      const double inner = interior_psnr(rgb, c.frames[0], info.width, info.height,
                                         window_margin(Mode::kRobot36));
      CHECK(inner >= kNoisyInteriorPsnr, "10 dB SNR: flat-area PSNR %.2f dB >= %.1f (whole %.2f dB)",
            inner, kNoisyInteriorPsnr, psnr(rgb, c.frames[0], info.width, info.height));
    }
  }
}

// Upstream re-finds each line's sync pulse, so transmitter clock error does
// not accumulate into slant: the bar edge stays put from top to bottom.
void test_sync_realignment_under_clock_drift() {
  for (Mode mode : {Mode::kMartin1, Mode::kScottie1}) {
    for (double ratio : {1.0005, 0.9995}) {
      const auto info = sstv_test::mode_info(mode);
      const auto rgb = sstv_test::make_test_pattern(info.width, info.height, 5);
      sstv_test::EncodeOptions o;
      o.clock_ratio = ratio;
      const auto audio = with_trailer(sstv_test::encode(mode, rgb, info.width, info.height, 24000, o));
      auto d = make_backend();
      Collector c;
      feed_chunks(*d, audio, c, 1500);
      const bool one = c.frames.size() == 1 && c.frames[0].rows.size() == static_cast<size_t>(info.height);
      CHECK(one, "%s clock %.4f: one full frame decoded", info.name, ratio);
      if (!one) continue;
      const Frame& f = c.frames[0];
      const double top = median_edge(f, info.width, 2, 2 + info.height / 10);
      const double bottom = median_edge(f, info.width, info.height - info.height / 10, info.height);
      // Without per-line sync the edge would drift by
      // |1-1/ratio| * frame_time / pixel_time (about 120 px for Martin 1).
      CHECK(top > 0 && bottom > 0 && std::fabs(bottom - top) <= 2.0,
            "%s clock %.4f: edge top %.2f px, bottom %.2f px (|slant| <= 2 px)", info.name, ratio,
            top, bottom);
      const auto up = upstream_bytes(audio, 1500);
      std::vector<uint8_t> mine;
      for (const auto& r : f.rows) mine.insert(mine.end(), r.begin(), r.end());
      CHECK(up.size() == mine.size() + 54 && std::equal(mine.begin(), mine.end(), up.begin() + 54),
            "%s clock %.4f: rows byte-identical to upstream", info.name, ratio);
    }
  }
}

// Scottie announces its header at VIS and then waits for a start sync. If
// none arrives, upstream abandons the frame without rows; the adapter must
// close the announced frame as partial/sync_lost.
void test_scottie_start_sync_timeout() {
  const auto info = sstv_test::mode_info(Mode::kScottie1);
  const auto rgb = sstv_test::make_test_pattern(info.width, info.height, 9);
  auto audio = sstv_test::encode(Mode::kScottie1, rgb, info.width, info.height, 24000);
  // Leader 300 + break 10 + leader 300 + 10 VIS bits*30 ms = 910 ms.
  audio.resize(static_cast<size_t>(0.910 * 24000));
  audio = with_trailer(audio, 4.0);
  auto d = make_backend();
  Collector c;
  feed_chunks(*d, audio, c);
  const bool ok = c.frames.size() == 1;
  CHECK(ok, "Scottie VIS without start sync: frame announced (frames=%zu)", c.frames.size());
  if (!ok) return;
  const Frame& f = c.frames[0];
  CHECK(f.rows.empty() && !f.complete.is_null() && f.complete["status"] == "partial" &&
            f.complete["reason"] == "sync_lost" && f.complete["received_lines"] == 0,
        "Scottie start-sync timeout closes the frame: partial/sync_lost, 0 rows");
  // Upstream wrote only the BMP header in this case.
  const auto up = upstream_bytes(audio, 1000);
  CHECK(up.size() == 54, "upstream engine also wrote only the 54-byte header (%zu bytes)", up.size());
}

// A transmission cut off mid-frame: upstream keeps decoding scanlines from
// whatever audio follows (here silence; findSync() fails and it falls back
// to the nominal line timing) until LINE_COUNT, then ends the frame
// naturally. The adapter must reproduce that byte for byte, not invent its
// own early termination.
void test_truncated_transmission() {
  const auto info = sstv_test::mode_info(Mode::kRobot36);
  const auto rgb = sstv_test::make_test_pattern(info.width, info.height, 19);
  auto audio = sstv_test::encode(Mode::kRobot36, rgb, info.width, info.height, 24000);
  audio.resize(audio.size() / 2);
  audio = with_trailer(audio, 25.0);
  auto d = make_backend();
  Collector c;
  feed_chunks(*d, audio, c, 777);
  const bool one = c.frames.size() == 1 && !c.frames[0].complete.is_null();
  CHECK(one, "truncated Robot 36: one frame, closed (frames=%zu)", c.frames.size());
  if (!one) return;
  const Frame& f = c.frames[0];
  std::vector<uint8_t> mine;
  for (const auto& r : f.rows) mine.insert(mine.end(), r.begin(), r.end());
  const auto up = upstream_bytes(audio, 777);
  CHECK(up.size() == mine.size() + 54 && std::equal(mine.begin(), mine.end(), up.begin() + 54) &&
            f.rows.size() == static_cast<size_t>(info.height) && f.complete["reason"] == "end",
        "truncated Robot 36: %zu rows byte-identical to upstream, reason=%s", f.rows.size(),
        f.complete["reason"].get<std::string>().c_str());
}

// Retune/mode-change reset at the backend boundary: the open frame closes
// as partial with the right reason, its unread input is discarded, and the
// next frame gets a new id and the new tuning.
void test_backend_reset_on_retune_and_mode() {
  const auto info = sstv_test::mode_info(Mode::kRobot36);
  const auto rgb = sstv_test::make_test_pattern(info.width, info.height, 11);
  const auto audio = with_trailer(sstv_test::encode(Mode::kRobot36, rgb, info.width, info.height, 24000));
  const size_t half = audio.size() / 2;
  struct Step { uint64_t freq; uint32_t mode; const char* reason; };
  for (const Step& s : {Step{14233000, SDR_V3_USB, "retune"}, Step{14230000, SDR_V3_LSB, "mode"},
                        Step{14230000, SDR_V3_USB, "stop"}}) {
    auto d = sdrcore::decoder::create_sstv();
    d->configure(R"({"version":1,"settings":{}})");
    d->set_tuning(14230000, SDR_V3_USB);
    d->reset();
    Collector c;
    feed_chunks(*d, audio, c, 1000, 0, half);
    const size_t rows_before = c.frames.empty() ? 0 : c.frames[0].rows.size();
    d->set_tuning(s.freq, s.mode);
    d->reset();
    c.take_all(*d);
    const bool closed = c.frames.size() == 1 && !c.frames[0].complete.is_null();
    CHECK(closed, "%s: reset closes the open frame", s.reason);
    if (!closed) continue;
    const Frame& f = c.frames[0];
    CHECK(f.complete["status"] == "partial" && f.complete["reason"] == s.reason &&
              f.complete["received_lines"] == rows_before && rows_before > 0 &&
              rows_before < static_cast<size_t>(info.height) &&
              f.complete["frequency_hz"] == 14230000 && f.complete["underlying"] == "usb",
          "%s: partial with reason=%s, received_lines=%zu, old frequency/underlying kept",
          s.reason, s.reason, rows_before);
    // The remainder of the old transmission has no header: nothing more.
    feed_chunks(*d, audio, c, 1000, half);
    CHECK(c.frames.size() == 1 && c.frames[0].rows.size() == rows_before,
          "%s: no stale rows after reset (rows %zu)", s.reason, c.frames[0].rows.size());
    // A new transmission decodes as a new frame under the new tuning.
    feed_chunks(*d, audio, c, 1000);
    const bool second = c.frames.size() == 2;
    CHECK(second, "%s: next transmission decodes as a new frame", s.reason);
    if (!second) continue;
    const auto id0 = std::stoull(c.frames[0].start["frame_id"].get<std::string>());
    const auto id1 = std::stoull(c.frames[1].start["frame_id"].get<std::string>());
    const char* underlying = s.mode == SDR_V3_LSB ? "lsb" : "usb";
    CHECK(id1 > id0 && c.frames[1].start["frequency_hz"] == s.freq &&
              c.frames[1].start["underlying"] == underlying &&
              c.frames[1].complete["status"] == "complete",
          "%s: new frame_id %llu > %llu, frequency %llu, underlying %s, complete", s.reason,
          static_cast<unsigned long long>(id1), static_cast<unsigned long long>(id0),
          static_cast<unsigned long long>(s.freq), underlying);
  }
  // reset() with no open frame emits nothing.
  auto d = make_backend();
  d->set_tuning(7171000, SDR_V3_LSB);
  d->reset();
  Event e;
  CHECK(!d->take_event(e), "reset without an open frame emits no event");
}

// --- Through the receiver ---------------------------------------------------

SdrV3Controls make_controls(uint32_t mode, uint32_t bandwidth, uint32_t rate, uint64_t center,
                             int64_t vfo) {
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = center;
  c.vfo_offset_hz = vfo;
  c.sample_rate = rate;
  c.mode = mode;
  c.bandwidth_hz = bandwidth;
  c.gain_tenths_db = 200;
  c.squelch = SDR_V3_SQUELCH_OFF;
  c.squelch_level_db = -50;
  c.volume = 1.0f;
  return c;
}

SdrV3Display make_display(uint32_t rate) {
  SdrV3Display d{};
  d.size = sizeof d;
  d.revision = SDR_V3_REVISION;
  d.view_bandwidth_hz = rate;
  d.width = 0;
  return d;
}

uint8_t quant(double v) {
  return static_cast<uint8_t>(std::clamp(std::lround(127.5 + 127.5 * v), 0L, 255L));
}

// CU8 IQ of an SSTV transmission received at `rate`, `vfo_hz` from the LO.
// USB: exp(+j*audio_phase), LSB: exp(-j*audio_phase), NFM: FM carrier at
// the VFO deviated by `deviation_hz` per unit of SSTV audio.
std::vector<uint8_t> sstv_iq(Mode mode, const std::vector<uint8_t>& rgb, uint32_t rate,
                             uint32_t demod, int64_t vfo_hz, double seconds_trailer = 3.0) {
  const auto info = sstv_test::mode_info(mode);
  sstv_test::EncodeOptions o;
  o.output_phase = demod != SDR_V3_NFM;
  auto sig = sstv_test::encode(mode, rgb, info.width, info.height, rate, o);
  sig.resize(sig.size() + static_cast<size_t>(seconds_trailer * rate), 0.0f);
  std::vector<uint8_t> iq(sig.size() * 2);
  const double amp = 0.3, step = 2 * kPi * static_cast<double>(vfo_hz) / rate;
  const double deviation_hz = 2500;
  double carrier = 0, fm = 0;
  const size_t signal_end = sig.size() - static_cast<size_t>(seconds_trailer * rate);
  for (size_t n = 0; n < sig.size(); ++n) {
    double ph = carrier;
    if (n < signal_end) {
      if (demod == SDR_V3_USB) ph += sig[n];
      else if (demod == SDR_V3_LSB) ph -= sig[n];
      else {
        fm += 2 * kPi * deviation_hz * sig[n] / rate;
        if (fm > kPi) fm -= 2 * kPi;
        if (fm < -kPi) fm += 2 * kPi;
        ph += fm;
      }
    }
    const double a = (demod == SDR_V3_NFM || n < signal_end) ? amp : 0.0;
    iq[2 * n] = quant(a * std::cos(ph));
    iq[2 * n + 1] = quant(a * std::sin(ph));
    carrier += step;
    if (carrier > kPi) carrier -= 2 * kPi;
  }
  return iq;
}

void feed_rx(sdrcore::dsp::Receiver& rx, Decoder& d, const std::vector<uint8_t>& iq, Collector& c,
             size_t begin_pairs = 0, size_t end_pairs = SIZE_MAX, size_t block_pairs = 16384) {
  end_pairs = std::min(end_pairs, iq.size() / 2);
  sdrcore::dsp::ProcessResult r;
  for (size_t p = begin_pairs; p < end_pairs; p += block_pairs) {
    const size_t n = std::min(block_pairs, end_pairs - p);
    rx.process(iq.data() + 2 * p, 2 * n, r);
    c.take_all(d);
  }
}

void test_receiver_end_to_end() {
  constexpr uint32_t kRate = 250000;
  constexpr int64_t kVfo = 30000;
  constexpr uint64_t kCenter = 14200000;
  const auto info = sstv_test::mode_info(Mode::kRobot36);
  const auto rgb = sstv_test::make_test_pattern(info.width, info.height, 13);
  struct Case { uint32_t mode; uint32_t bw; const char* name; };
  for (const Case& k : {Case{SDR_V3_USB, 2800, "usb"}, Case{SDR_V3_LSB, 2800, "lsb"},
                        Case{SDR_V3_NFM, 12500, "nfm"}}) {
    const auto iq = sstv_iq(Mode::kRobot36, rgb, kRate, k.mode, kVfo);
    auto rx = sdrcore::dsp::make_receiver();
    rx->configure(make_controls(k.mode, k.bw, kRate, kCenter, kVfo), make_display(kRate));
    auto d = sdrcore::decoder::create_sstv();
    const std::string cfg = std::string(R"({"version":1,"settings":{"underlying":")") + k.name +
                            R"(","mode":"auto"}})";
    d->configure(cfg);
    rx->set_decoder(d.get(), sdrcore::decoder::Input::audio);
    Collector c;
    const auto t0 = std::chrono::steady_clock::now();
    feed_rx(*rx, *d, iq, c);
    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    const bool ok = c.frames.size() == 1 && c.frames[0].rows.size() == static_cast<size_t>(info.height);
    CHECK(ok, "receiver %s: Robot 36 decoded through the 24 kHz tap (frames=%zu)", k.name,
          c.frames.size());
    if (!ok) continue;
    const Frame& f = c.frames[0];
    CHECK(f.start["frequency_hz"] == kCenter + kVfo && f.start["underlying"] == k.name &&
              f.complete["status"] == "complete",
          "receiver %s: tuned frequency %llu and underlying stamped, complete", k.name,
          static_cast<unsigned long long>(kCenter + kVfo));
    const double audio_s = static_cast<double>(iq.size() / 2) / kRate;
    const double inner = interior_psnr(rgb, f, info.width, info.height, window_margin(Mode::kRobot36));
    CHECK(inner >= kReceiverInteriorPsnr,
          "receiver %s: flat-area PSNR %.2f dB >= %.1f, whole %.2f dB (%.2f s CPU for %.1f s of IQ, "
          "%.1f%% of real time)",
          k.name, inner, kReceiverInteriorPsnr, psnr(rgb, f, info.width, info.height), secs, audio_s,
          100 * secs / audio_s);
  }
}

// Regression for t_b137e226: the csdr NFM deemphasis FIR on the audio tap
// tilts the SSTV tone range (+1.0 dB at 1200 Hz, -3.2 dB at 2300 Hz vs
// 1500 Hz). Without a matching transmitter pre-emphasis that tilt turned
// every tone step into an amplitude step, upstream's FFT-peak sync search
// found line starts late, and fast-pixel modes slipped ~2 px (PD-90 over
// NFM: 23.5 dB vs source, 25.0 dB vs the oracle; USB 29.5 dB). The tap now
// normalises the tone envelope, so NFM must decode like the direct
// adapter: same bar edge position and near-identical flat areas.
// The assertion checks both the flat-area similarity and edge alignment;
// scores vary slightly with the generated pattern and receiver build.
void test_receiver_nfm_matches_adapter() {
  constexpr uint32_t kRate = 240000;
  constexpr int64_t kVfo = 20000;
  constexpr uint64_t kCenter = 145500000;
  for (const Mode mode : {Mode::kPd90, Mode::kScottie1}) {
    const auto info = sstv_test::mode_info(mode);
    const auto rgb = sstv_test::make_test_pattern(info.width, info.height, 21);
    // Direct adapter on the clean 24 kHz audio: the reference image.
    const auto audio = with_trailer(sstv_test::encode(mode, rgb, info.width, info.height, 24000));
    auto ref_dec = make_backend(14230000, SDR_V3_USB);
    Collector ref;
    feed_chunks(*ref_dec, audio, ref, 1000);
    // The same transmission over FM (2.5 kHz deviation, no pre-emphasis).
    const auto iq = sstv_iq(mode, rgb, kRate, SDR_V3_NFM, kVfo);
    auto rx = sdrcore::dsp::make_receiver();
    rx->configure(make_controls(SDR_V3_NFM, 12500, kRate, kCenter, kVfo), make_display(kRate));
    auto d = sdrcore::decoder::create_sstv();
    d->configure(R"({"version":1,"settings":{"underlying":"nfm","mode":"auto"}})");
    rx->set_decoder(d.get(), sdrcore::decoder::Input::audio);
    Collector c;
    feed_rx(*rx, *d, iq, c);
    const bool ok = ref.frames.size() == 1 && c.frames.size() == 1 &&
                    c.frames[0].rows.size() == static_cast<size_t>(info.height) &&
                    ref.frames[0].rows.size() == static_cast<size_t>(info.height);
    CHECK(ok, "receiver nfm %s: one complete frame (adapter %zu, receiver %zu frames)", info.name,
          ref.frames.size(), c.frames.size());
    if (!ok) continue;
    const Frame& a = ref.frames[0];
    const Frame& f = c.frames[0];
    dump_ppm(std::string("nfm_") + info.name, f, info.width);
    // The adapter's decoded image as an RGB "source" for interior_psnr().
    std::vector<uint8_t> a_rgb(static_cast<size_t>(info.width) * info.height * 3);
    for (int y = 0; y < info.height; ++y)
      for (int x = 0; x < info.width; ++x)
        for (int ch = 0; ch < 3; ++ch)
          a_rgb[(static_cast<size_t>(y) * info.width + x) * 3 + ch] =
              a.rows[y][static_cast<size_t>(x) * 3 + (2 - ch)];
    const int margin = window_margin(mode);
    const double vs_adapter = interior_psnr(a_rgb, f, info.width, info.height, margin);
    const double vs_source = interior_psnr(rgb, f, info.width, info.height, margin);
    const double adapter_vs_source = interior_psnr(rgb, a, info.width, info.height, margin);
    const double shift = median_edge(f, info.width, 8, info.height - 8) -
                         median_edge(a, info.width, 8, info.height - 8);
    CHECK(vs_adapter >= 35.0 && std::fabs(shift) <= 0.5 && vs_source >= adapter_vs_source - 1.0,
          "receiver nfm %s: flat areas %.2f dB vs the direct adapter (>= 35), bar edge shift "
          "%.2f px (|.| <= 0.5), %.2f dB vs source (adapter %.2f, loss <= 1 dB)",
          info.name, vs_adapter, shift, vs_source, adapter_vs_source);
  }
}

void test_receiver_retune_mode_bandwidth() {
  constexpr uint32_t kRate = 250000;
  constexpr int64_t kVfo = 30000;
  constexpr uint64_t kCenter = 14200000;
  const auto info = sstv_test::mode_info(Mode::kRobot36);
  const auto rgb = sstv_test::make_test_pattern(info.width, info.height, 17);
  const auto iq = sstv_iq(Mode::kRobot36, rgb, kRate, SDR_V3_USB, kVfo);
  const size_t pairs = iq.size() / 2, mid = pairs / 2;
  struct Step { const char* name; int64_t vfo; uint32_t mode; uint32_t bw; const char* reason; };
  for (const Step& s : {Step{"VFO retune", kVfo + 5000, SDR_V3_USB, 2800, "retune"},
                        Step{"mode USB->LSB", kVfo, SDR_V3_LSB, 2800, "mode"},
                        Step{"bandwidth only", kVfo, SDR_V3_USB, 3000, nullptr}}) {
    auto rx = sdrcore::dsp::make_receiver();
    SdrV3Controls ctl = make_controls(SDR_V3_USB, 2800, kRate, kCenter, kVfo);
    rx->configure(ctl, make_display(kRate));
    auto d = sdrcore::decoder::create_sstv();
    d->configure(R"({"version":1,"settings":{}})");
    rx->set_decoder(d.get(), sdrcore::decoder::Input::audio);
    Collector c;
    feed_rx(*rx, *d, iq, c, 0, mid);
    const size_t rows_mid = c.frames.empty() ? 0 : c.frames[0].rows.size();
    ctl.vfo_offset_hz = s.vfo;
    ctl.mode = s.mode;
    ctl.bandwidth_hz = s.bw;
    rx->configure(ctl, make_display(kRate));
    c.take_all(*d);
    feed_rx(*rx, *d, iq, c, mid);
    if (s.reason) {
      const bool ok = c.frames.size() == 1 && !c.frames[0].complete.is_null();
      CHECK(ok, "receiver %s: open frame closed (frames=%zu)", s.name, c.frames.size());
      if (!ok) continue;
      CHECK(c.frames[0].complete["status"] == "partial" && c.frames[0].complete["reason"] == s.reason &&
                c.frames[0].rows.size() == rows_mid && rows_mid > 0,
            "receiver %s: partial/%s after %zu rows, no rows of the old signal after the reset",
            s.name, s.reason, rows_mid);
    } else {
      const bool ok = c.frames.size() == 1 && c.frames[0].rows.size() == static_cast<size_t>(info.height) &&
                      c.frames[0].complete["status"] == "complete";
      CHECK(ok, "receiver %s: no reset, frame completes (rows %zu)", s.name,
            c.frames.empty() ? size_t{0} : c.frames[0].rows.size());
    }
  }
  // LO recenter keeping the same tuned frequency: no reset, frame completes.
  {
    auto rx = sdrcore::dsp::make_receiver();
    SdrV3Controls ctl = make_controls(SDR_V3_USB, 2800, kRate, kCenter, kVfo);
    rx->configure(ctl, make_display(kRate));
    auto d = sdrcore::decoder::create_sstv();
    d->configure(kUsbAuto);
    rx->set_decoder(d.get(), sdrcore::decoder::Input::audio);
    Collector c;
    feed_rx(*rx, *d, iq, c, 0, mid);
    // Same tuned frequency (center + offset) under a moved LO; the IQ is
    // regenerated for the new offset by shifting the remaining samples.
    ctl.center_frequency_hz += 10000;
    ctl.vfo_offset_hz -= 10000;
    rx->configure(ctl, make_display(kRate));
    std::vector<uint8_t> shifted(iq.begin() + 2 * mid, iq.end());
    const double step = 2 * kPi * 10000.0 / kRate;
    for (size_t n = 0; n < shifted.size() / 2; ++n) {
      const std::complex<double> v((shifted[2 * n] - 127.5) / 127.5, (shifted[2 * n + 1] - 127.5) / 127.5);
      const auto w = v * std::polar(1.0, -step * static_cast<double>(n + mid));
      shifted[2 * n] = quant(w.real());
      shifted[2 * n + 1] = quant(w.imag());
    }
    feed_rx(*rx, *d, shifted, c);
    const bool ok = c.frames.size() == 1 && c.frames[0].rows.size() == static_cast<size_t>(info.height) &&
                    c.frames[0].complete["status"] == "complete";
    CHECK(ok, "receiver LO recenter at same tuned frequency: no reset, frame completes");
  }
}

}  // namespace

int main(int argc, char** argv) {
  const bool quick = argc > 1 && std::strcmp(argv[1], "--quick") == 0;
  if (argc > 1 && std::strcmp(argv[1], "--nfm-tap") == 0) {
    // Only the NFM tap regression (fast RED/GREEN loop).
    test_receiver_nfm_matches_adapter();
    std::printf(failures ? "%d check(s) failed.\n" : "All SSTV checks passed.\n", failures);
    return failures ? 1 : 0;
  }
  test_configure_contract();
  test_vis_rejects();
  test_scottie_start_sync_timeout();
  test_truncated_transmission();
  test_backend_reset_on_retune_and_mode();
  // Whole-image floors: measured 15.4 (Robot 36), 22.6 (Martin 1), 16.0
  // (Scottie 1), 17.0 (PD-90) and 17.7 dB (PD-290); bounded by upstream's
  // multi-pixel FFT window at the pattern's hard bar edges (see
  // interior_psnr()), so they only guard against gross regressions.
  for (const ModeCase& mc : {ModeCase{Mode::kRobot36, kCleanInteriorPsnr, 13.5},
                             ModeCase{Mode::kMartin1, kCleanInteriorPsnr, 20.0},
                             ModeCase{Mode::kScottie1, kCleanInteriorPsnr, 14.0},
                             ModeCase{Mode::kPd90, kCleanInteriorPsnr, 15.0}}) {
    test_vis_and_framing(mc);
  }
  if (!quick) {
    test_vis_and_framing(ModeCase{Mode::kPd290, kCleanInteriorPsnr, 15.5});
    test_sync_realignment_under_clock_drift();
    test_receiver_end_to_end();
    test_receiver_nfm_matches_adapter();
    test_receiver_retune_mode_bandwidth();
  }
  if (failures) {
    std::fprintf(stderr, "%d check(s) failed.\n", failures);
    return 1;
  }
  std::printf("All SSTV checks passed.\n");
  return 0;
}

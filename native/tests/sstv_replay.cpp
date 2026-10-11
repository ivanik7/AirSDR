// SPDX-License-Identifier: GPL-3.0-or-later
//
// Host-only replay tool for the SSTV oracle comparison
// (tool/sstv_oracle/compare.py). It feeds one 24 kHz demodulated-audio WAV
// through the production native SSTV path and records every v1 event:
//
//   adapter  <in.wav> <outdir> [--chunk N]
//       WAV -> sdrcore::decoder::create_sstv() directly, N samples per
//       process() call (default 1024, the csdr Command::runModule clamp).
//   receiver <in.wav> <outdir> --mode usb|lsb|nfm [--rate HZ] [--vfo HZ]
//            [--block PAIRS] [--iq-out file.cu8]
//       WAV -> CU8 IQ (USB/LSB: analytic signal; NFM: FM, 2.5 kHz
//       deviation per unit audio) -> sdrcore::dsp::Receiver with the SSTV
//       backend on its 24 kHz audio tap, exactly as the app's DSP worker
//       drives it. --iq-out also stores the IQ so the Dart end-to-end test
//       can replay it as a file source.
//   make-iq  <in.wav> <out.cu8> --mode usb|lsb|nfm [--rate HZ] [--vfo HZ]
//       only writes the IQ.
//
// Output: <outdir>/events.jsonl (one line per event, pixels removed, with
// "input_samples" = 24 kHz audio samples consumed when the event was
// taken) and <outdir>/frame_<frame_id>.bgr (the rows, concatenated).
#include "../src/dsp/receiver.h"
#include "decoder.hpp"
#include "sdrcore_v3.h"

#include <nlohmann/json.hpp>

#include <algorithm>
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
constexpr double kPi = 3.14159265358979323846;

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
  for (size_t off = 12; off + 8 <= all.size();) {
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

class Recorder {
 public:
  explicit Recorder(std::string dir) : dir_(std::move(dir)) {
    events_ = std::fopen((dir_ + "/events.jsonl").c_str(), "w");
  }
  ~Recorder() {
    for (auto& [id, fp] : frames_) std::fclose(fp);
    if (events_) std::fclose(events_);
  }
  bool ok() const { return events_ != nullptr; }

  void take_all(Decoder& d, uint64_t input_samples) {
    Event e;
    while (d.take_event(e)) {
      auto j = nlohmann::json::parse(e.payload.begin(), e.payload.end(), nullptr, false);
      if (j.is_discarded()) {
        std::fprintf(events_, "{\"kind\":\"invalid\"}\n");
        continue;
      }
      if (e.kind == Result::image_progress && j.value("phase", "") == "line") {
        const std::string id = j["frame_id"].get<std::string>();
        auto px = base64_decode(j["pixels_bgr_base64"].get<std::string>());
        j["pixels_bytes"] = px.size();
        j.erase("pixels_bgr_base64");
        FILE*& fp = frames_[id];
        if (!fp) fp = std::fopen((dir_ + "/frame_" + id + ".bgr").c_str(), "wb");
        if (fp) std::fwrite(px.data(), 1, px.size(), fp);
      }
      j["kind"] = e.kind == Result::image_complete ? "image_complete" : "image_progress";
      j["input_samples"] = input_samples;
      std::fprintf(events_, "%s\n", j.dump().c_str());
    }
    dropped_ += d.take_dropped_count();
  }
  uint64_t dropped() const { return dropped_; }

 private:
  std::string dir_;
  FILE* events_ = nullptr;
  std::map<std::string, FILE*> frames_;
  uint64_t dropped_ = 0;
};

// Analytic signal of the audio at 24 kHz (I = audio delayed by the Hilbert
// group delay, Q = 255-tap Blackman-windowed Hilbert FIR), then integer
// interpolation by L = rate/24000 with a 6 kHz windowed-sinc low-pass (the
// SSTV band is 1.1-2.3 kHz), mixed to vfo_hz and quantized to CU8 at 0.3
// of full scale. NFM: phase accumulation with 2.5 kHz deviation per unit
// of audio (normalized so the audio's peak maps to 1).
std::vector<uint8_t> make_iq(const std::vector<float>& audio, const std::string& mode,
                             uint32_t rate, int64_t vfo_hz) {
  const uint32_t L = rate / 24000;
  std::vector<std::complex<double>> z(audio.size());
  float peak = 1e-9f;
  for (float v : audio) peak = std::max(peak, std::fabs(v));
  if (mode == "nfm") {
    for (size_t n = 0; n < audio.size(); ++n) z[n] = {audio[n] / peak, 0.0};
  } else {
    constexpr int kTaps = 255, kMid = kTaps / 2;
    std::vector<double> h(kTaps, 0.0);
    for (int k = 0; k < kTaps; ++k) {
      const int m = k - kMid;
      if (m % 2 == 0) continue;
      const double w = 0.42 - 0.5 * std::cos(2 * kPi * k / (kTaps - 1)) +
                       0.08 * std::cos(4 * kPi * k / (kTaps - 1));
      h[k] = 2.0 / (kPi * m) * w;
    }
    const double sign = mode == "lsb" ? -1.0 : 1.0;
    for (size_t n = 0; n < audio.size(); ++n) {
      double q = 0;
      for (int k = 0; k < kTaps; ++k) {
        const long idx = static_cast<long>(n) + kMid - k;
        if (idx >= 0 && idx < static_cast<long>(audio.size())) q += h[k] * audio[idx];
      }
      const double i = audio[n];
      z[n] = {i, sign * q};
    }
  }
  // Interpolation filter (zero-stuffed input, gain L).
  const int taps = 16 * static_cast<int>(L) + 1, mid = taps / 2;
  std::vector<double> lp(taps);
  const double fc = 6000.0 / rate;
  for (int k = 0; k < taps; ++k) {
    const int m = k - mid;
    const double s = m == 0 ? 2 * fc : std::sin(2 * kPi * fc * m) / (kPi * m);
    const double w = 0.42 - 0.5 * std::cos(2 * kPi * k / (taps - 1)) +
                     0.08 * std::cos(4 * kPi * k / (taps - 1));
    lp[k] = s * w * L;
  }
  std::vector<uint8_t> iq(audio.size() * L * 2);
  const double amp = 0.3;
  double fm_phase = 0;
  const double vfo_step = 2 * kPi * static_cast<double>(vfo_hz) / rate;
  auto quant = [](double v) {
    return static_cast<uint8_t>(std::clamp(std::lround(127.5 + 127.5 * v), 0L, 255L));
  };
  // Scale so the analytic signal's peak magnitude is 1 (USB/LSB).
  double zpeak = 1e-9;
  if (mode != "nfm")
    for (const auto& v : z) zpeak = std::max(zpeak, std::abs(v));
  for (size_t out = 0; out < audio.size() * L; ++out) {
    std::complex<double> acc = 0;
    // Only every L-th input of the zero-stuffed stream is non-zero.
    const long first = static_cast<long>(out) - mid;
    long k0 = first % static_cast<long>(L);
    if (k0 < 0) k0 += L;
    k0 = (L - k0) % L;
    for (long k = k0; k < taps; k += L) {
      const long src = first + k;
      if (src < 0) continue;
      const size_t n = static_cast<size_t>(src) / L;
      if (n >= z.size()) break;
      acc += lp[taps - 1 - k] * z[n];
    }
    std::complex<double> s;
    if (mode == "nfm") {
      fm_phase += 2 * kPi * 2500.0 * acc.real() / rate;
      if (fm_phase > kPi) fm_phase -= 2 * kPi;
      if (fm_phase < -kPi) fm_phase += 2 * kPi;
      s = std::polar(amp, fm_phase);
    } else {
      s = amp * acc / zpeak;
    }
    s *= std::polar(1.0, vfo_step * static_cast<double>(out));
    iq[2 * out] = quant(s.real());
    iq[2 * out + 1] = quant(s.imag());
  }
  return iq;
}

// Returns false for an unsupported name (SDR_V3_NFM is 0, so the mode value
// itself cannot double as the error sentinel).
bool parse_mode(const std::string& m, uint32_t& out) {
  if (m == "usb") out = SDR_V3_USB;
  else if (m == "lsb") out = SDR_V3_LSB;
  else if (m == "nfm") out = SDR_V3_NFM;
  else return false;
  return true;
}

int usage(const char* argv0) {
  std::fprintf(stderr,
               "usage: %s adapter <in.wav> <outdir> [--chunk N]\n"
               "       %s receiver <in.wav> <outdir> --mode usb|lsb|nfm [--rate HZ] [--vfo HZ]"
               " [--block PAIRS] [--iq-out F]\n"
               "       %s make-iq <in.wav> <out.cu8> --mode usb|lsb|nfm [--rate HZ] [--vfo HZ]\n",
               argv0, argv0, argv0);
  return 2;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) return usage(argv[0]);
  const std::string cmd = argv[1], wav = argv[2], out = argv[3];
  size_t chunk = 1024, block = 16384;
  uint32_t rate = 240000;
  int64_t vfo = 0;
  std::string mode = "usb", iq_out;
  for (int i = 4; i + 1 < argc; i += 2) {
    const std::string k = argv[i], v = argv[i + 1];
    if (k == "--chunk") chunk = std::strtoul(v.c_str(), nullptr, 10);
    else if (k == "--block") block = std::strtoul(v.c_str(), nullptr, 10);
    else if (k == "--rate") rate = std::strtoul(v.c_str(), nullptr, 10);
    else if (k == "--vfo") vfo = std::strtoll(v.c_str(), nullptr, 10);
    else if (k == "--mode") mode = v;
    else if (k == "--iq-out") iq_out = v;
    else return usage(argv[0]);
  }
  std::vector<float> audio;
  uint32_t wav_rate = 0;
  if (!read_wav(wav.c_str(), audio, wav_rate) || wav_rate != 24000) {
    std::fprintf(stderr, "need a mono 24000 Hz s16/float32 WAV: %s\n", wav.c_str());
    return 2;
  }
  uint32_t v3_mode = 0;
  if (chunk == 0 || block == 0 || rate % 24000 != 0 || !parse_mode(mode, v3_mode))
    return usage(argv[0]);

  if (cmd == "make-iq" || cmd == "receiver") {
    const auto iq = make_iq(audio, mode, rate, vfo);
    const std::string path = cmd == "make-iq" ? out : iq_out;
    if (!path.empty()) {
      FILE* fp = std::fopen(path.c_str(), "wb");
      if (!fp || std::fwrite(iq.data(), 1, iq.size(), fp) != iq.size()) {
        std::fprintf(stderr, "cannot write %s\n", path.c_str());
        return 1;
      }
      std::fclose(fp);
    }
    if (cmd == "make-iq") return 0;

    Recorder rec(out);
    if (!rec.ok()) return 1;
    SdrV3Controls c{};
    c.size = sizeof c;
    c.revision = SDR_V3_REVISION;
    c.center_frequency_hz = 14230000 - vfo;
    c.vfo_offset_hz = vfo;
    c.sample_rate = rate;
    c.mode = v3_mode;
    c.bandwidth_hz = mode == "nfm" ? 12500 : 2800;
    c.gain_tenths_db = 200;
    c.squelch = SDR_V3_SQUELCH_OFF;
    c.squelch_level_db = -50;
    c.volume = 1.0f;
    SdrV3Display disp{};
    disp.size = sizeof disp;
    disp.revision = SDR_V3_REVISION;
    disp.view_bandwidth_hz = rate;
    auto rx = sdrcore::dsp::make_receiver();
    rx->configure(c, disp);
    auto d = sdrcore::decoder::create_sstv();
    const std::string cfg = R"({"version":1,"settings":{"mode":"auto","underlying":")" + mode + "\"}}";
    if (!d->configure(cfg)) return 1;
    rx->set_decoder(d.get(), sdrcore::decoder::Input::audio);
    sdrcore::dsp::ProcessResult r;
    const size_t pairs = iq.size() / 2;
    for (size_t p = 0; p < pairs; p += block) {
      const size_t n = std::min(block, pairs - p);
      rx->process(iq.data() + 2 * p, 2 * n, r);
      rec.take_all(*d, (p + n) * 24000ULL / rate);
    }
    std::printf("{\"dropped\":%llu}\n", static_cast<unsigned long long>(rec.dropped()));
    return 0;
  }
  if (cmd == "adapter") {
    Recorder rec(out);
    if (!rec.ok()) return 1;
    auto d = sdrcore::decoder::create_sstv();
    if (!d->configure(R"({"version":1,"settings":{"mode":"auto","underlying":"usb"}})")) return 1;
    d->set_tuning(14230000, SDR_V3_USB);
    d->reset();
    for (size_t off = 0; off < audio.size(); off += chunk) {
      const size_t n = std::min(chunk, audio.size() - off);
      d->process(audio.data() + off, n, 24000);
      rec.take_all(*d, off + n);
    }
    std::printf("{\"dropped\":%llu}\n", static_cast<unsigned long long>(rec.dropped()));
    return 0;
  }
  return usage(argv[0]);
}

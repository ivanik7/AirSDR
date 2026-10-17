// SPDX-License-Identifier: GPL-3.0-or-later
// Host tests for the DMR AMBE+2 voice output stage (native/src/dmr/vocoder.*).
// Synthetic channel frames come from dmr_ambe_test_encoder.hpp (inverse of
// mbelib's channel decoding); they are vocoder parameter vectors, not speech.
#include "dmr/vocoder.hpp"
#include "dmr_ambe_test_encoder.hpp"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#if SDRCORE_ENABLE_MBELIB
extern "C" {
#include <mbelib.h>
}
#endif

namespace {

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

using sdrcore::dmr::AmbeFrame;
using sdrcore::dmr::AmbeSynthesizer;
using sdrcore::dmr::FrameStats;
using sdrcore::dmr::VoiceOutput;

AmbeFrame frame_of(const dmr_test::Frame9& bits) {
  AmbeFrame f;
  std::memcpy(f.bits, bits.data(), 9);
  return f;
}

double rms(const int16_t* x, size_t n) {
  double s = 0;
  for (size_t i = 0; i < n; ++i) s += double(x[i]) * x[i];
  return n ? std::sqrt(s / n) : 0;
}
double rms(const std::vector<float>& x, size_t from = 0) {
  double s = 0;
  for (size_t i = from; i < x.size(); ++i) s += double(x[i]) * x[i];
  return x.size() > from ? std::sqrt(s / (x.size() - from)) : 0;
}

// Fraction of power above `cut_hz` (single-sided DFT over the whole vector).
double power_above(const std::vector<float>& x, double rate, double cut_hz) {
  size_t n = 1;
  while (n * 2 <= x.size()) n *= 2;
  std::vector<std::complex<double>> d(n);
  for (size_t i = 0; i < n; ++i) {
    const double w = 0.5 - 0.5 * std::cos(2 * M_PI * i / (n - 1));
    d[i] = x[i] * w;
  }
  for (size_t i = 1, j = 0; i < n; ++i) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(d[i], d[j]);
  }
  for (size_t len = 2; len <= n; len <<= 1) {
    const auto step = std::polar(1.0, -2 * M_PI / double(len));
    for (size_t b = 0; b < n; b += len) {
      std::complex<double> w{1, 0};
      for (size_t j = 0; j < len / 2; ++j) {
        const auto a = d[b + j], c = d[b + j + len / 2] * w;
        d[b + j] = a + c;
        d[b + j + len / 2] = a - c;
        w *= step;
      }
    }
  }
  double total = 0, high = 0;
  for (size_t k = 1; k < n / 2; ++k) {
    const double p = std::norm(d[k]);
    total += p;
    if (k * rate / n > cut_hz) high += p;
  }
  return total > 0 ? high / total : 0;
}

void test_availability() {
  CHECK(sdrcore::dmr::vocoder_available() == bool(SDRCORE_ENABLE_MBELIB),
        "vocoder_available() matches SDRCORE_ENABLE_MBELIB=%d", int(SDRCORE_ENABLE_MBELIB));
}

#if SDRCORE_ENABLE_MBELIB
// The test encoder is the exact inverse of mbelib's channel decoding: a clean
// frame decodes with zero corrections and returns the same 49 parameter bits.
void test_encoder_roundtrip_with_mbelib() {
  int mismatches = 0, corrected = 0;
  for (int n = 0; n < 200; ++n) {
    const auto p = dmr_test::track(n);
    const auto want = dmr_test::params_to_ambe_d(p);
    const auto f = dmr_test::encode(p);
    // softmbe unpack + deinterleave, then mbelib's own ECC/demodulation.
    char inter[72], deint[72], fr[4][24] = {{0}}, d[49] = {0};
    for (int i = 0; i < 72; i++) inter[i] = (f[i / 8] >> (7 - i % 8)) & 1;
    for (int i = 0; i < 72; i++) deint[i] = inter[dmr_interleave_permutation[i]];
    for (int i = 0; i < 24; i++) fr[0][i] = deint[i];
    for (int i = 0; i < 23; i++) fr[1][i] = deint[24 + i];
    for (int i = 0; i < 11; i++) fr[2][i] = deint[47 + i];
    for (int i = 0; i < 14; i++) fr[3][i] = deint[58 + i];
    corrected += mbe_eccAmbe3600x2450C0(fr);
    mbe_demodulateAmbe3600x2450Data(fr);
    corrected += mbe_eccAmbe3600x2450Data(fr, d);
    for (int i = 0; i < 49; ++i) mismatches += d[i] != want[i];
  }
  CHECK(mismatches == 0 && corrected == 0,
        "test encoder round-trips 200 frames through mbelib ECC (bit mismatches %d, corrections %d)",
        mismatches, corrected);
}

void test_synthesizer_frames_and_errors() {
  AmbeSynthesizer synth;
  int16_t pcm[160];
  FrameStats st;
  double voiced_rms = 0;
  bool clean = true;
  for (int n = 0; n < 50; ++n) {
    const bool ok = synth.decode(dmr_test::encode(dmr_test::track(n)).data(), pcm, &st);
    clean = clean && ok && st.errs == 0 && st.errs2 == 0;
    if (n >= 10) voiced_rms += rms(pcm, 160) / 40;
  }
  CHECK(clean, "50 clean frames decode with errs = errs2 = 0");
  CHECK(voiced_rms > 50, "clean parameter frames synthesize audible PCM (mean RMS %.1f)", voiced_rms);

  // 1..3 C0 data-bit errors are corrected by Golay(23,12) and reported in
  // errs. mbelib counts corrected DATA bits only: C0 data = fr[0][12..23]
  // (deinterleaved index 12..23), C1 data = fr[1][11..22] (index 35..46).
  for (int nerr = 1; nerr <= 3; ++nerr) {
    auto f = dmr_test::encode(dmr_test::track(7));
    for (int e = 0; e < nerr; ++e) dmr_test::flip(f, dmr_test::interleaved_position(12 + 4 * e));
    synth.decode(f.data(), pcm, &st);
    CHECK(st.errs == nerr && st.errs2 == nerr, "%d C0 channel bit error(s) corrected (errs=%d errs2=%d)",
          nerr, st.errs, st.errs2);
  }
  // C1 errors count only in errs2.
  {
    auto f = dmr_test::encode(dmr_test::track(8));
    dmr_test::flip(f, dmr_test::interleaved_position(35 + 2));
    dmr_test::flip(f, dmr_test::interleaved_position(35 + 9));
    synth.decode(f.data(), pcm, &st);
    CHECK(st.errs == 0 && st.errs2 == 2, "C1 errors counted in errs2 only (errs=%d errs2=%d)", st.errs,
          st.errs2);
  }
  // Silence frame (b0 = 124) and erasure (b0 = 120) synthesize zeros.
  {
    dmr_test::Params p;
    p.b0 = 120;
    synth.decode(dmr_test::encode(p).data(), pcm, &st);
    CHECK(rms(pcm, 160) == 0, "erasure frame (b0=120) yields silence, err_str '%s'", st.err_str);
    synth.reset();
    p.b0 = 124;
    p.b2 = 0;
    synth.decode(dmr_test::encode(p).data(), pcm, &st);
    CHECK(rms(pcm, 160) < 30, "silence frame (b0=124) after reset is near-silent (RMS %.2f)", rms(pcm, 160));
  }
  // errs2 > 3 (here 2 C0 + 2 C1 corrected data bits): mbelib repeats the
  // previous parameters ('R') and, after three repeats, mutes ('M') and
  // re-initialises -- upstream behaviour, unmodified.
  {
    synth.reset();
    for (int n = 0; n < 5; ++n) synth.decode(dmr_test::encode(dmr_test::track(n)).data(), pcm, &st);
    std::string marks;
    std::vector<double> levels;
    for (int r = 0; r < 5; ++r) {
      auto f = dmr_test::encode(dmr_test::track(5 + r));
      for (int e : {13, 20, 37, 44}) dmr_test::flip(f, dmr_test::interleaved_position(e));
      synth.decode(f.data(), pcm, &st);
      // err_str is "==..R" for a repeat and "==..RM" for repeat+mute.
      marks += std::strchr(st.err_str, 'M') ? 'M' : std::strchr(st.err_str, 'R') ? 'R' : '-';
      levels.push_back(rms(pcm, 160));
    }
    CHECK(marks.substr(0, 4) == "RRRM" && levels[0] > 0 && levels[3] == 0,
          "errs2 > 3: repeat x3 then mute ('%s', RMS %.0f .. %.0f)", marks.c_str(), levels[0], levels[3]);
  }
}

void test_voice_output_chain() {
  VoiceOutput out;
  std::vector<int16_t> cap;
  out.set_capture_8k(&cap);
  // First frame: AGC keeps its 100-sample look-ahead -> 60 samples out.
  out.on_ambe(frame_of(dmr_test::encode(dmr_test::track(0))));
  CHECK(cap.size() == 60 && out.buffered_frames() == 60 * 6,
        "first frame: 60 post-AGC 8 kHz samples, %zu at 48 kHz", out.buffered_frames());
  float buf[48000];
  CHECK(out.read_audio(buf, 4800) == 0, "pre-buffer withholds output below 100 ms");
  for (int n = 1; n < 40; ++n) out.on_ambe(frame_of(dmr_test::encode(dmr_test::track(n))));
  CHECK(cap.size() == 60 + 39 * 160, "steady state: 160 samples per frame (%zu total)", cap.size());
  CHECK(out.frames_decoded() == 40 && out.frames_dropped() == 0, "40 frames decoded");
  const size_t queued = out.buffered_frames();
  CHECK(queued == cap.size() * 6, "x6 interpolation: %zu 48 kHz samples for %zu 8 kHz", queued, cap.size());
  std::vector<float> pcm48;
  size_t got;
  while ((got = out.read_audio(buf, 1024)) > 0) pcm48.insert(pcm48.end(), buf, buf + got);
  CHECK(pcm48.size() == queued && out.buffered_frames() == 0, "read_audio drains the queue");
  CHECK(out.read_audio(buf, 1024) == 0, "underrun returns 0 (receiver plays silence)");
  // Level: AGC (max gain 30, reference 0.8) lifts the vocoder output; the
  // 48 kHz signal keeps the 8 kHz RMS (unity-gain interpolator).
  std::vector<float> cap_f(cap.begin(), cap.end());
  for (auto& v : cap_f) v /= 32768.0f;
  const double r8 = rms(cap_f, 1600), r48 = rms(pcm48, 9600);
  CHECK(r8 > 0.02 && std::abs(r48 / r8 - 1) < 0.1, "48 kHz RMS %.4f tracks 8 kHz RMS %.4f", r48, r8);
  float peak = 0;
  for (float v : pcm48) peak = std::max(peak, std::abs(v));
  CHECK(peak <= 1.0f, "output within [-1, 1] (peak %.3f)", peak);
  const double hi = power_above(pcm48, 48000, 4500);
  CHECK(hi < 1e-4, "interpolation images above 4.5 kHz: %.2e of power", hi);
  const double band = power_above(cap_f, 8000, 3600);
  CHECK(band < 0.02, "DigitalVoiceFilter: %.2e of 8 kHz power above 3.6 kHz", band);

  // Reset drops queue and state; disabled voice drops frames.
  out.on_ambe(frame_of(dmr_test::encode(dmr_test::track(1))));
  out.reset();
  CHECK(out.buffered_frames() == 0, "reset() clears queued PCM");
  out.set_enabled(false);
  out.on_ambe(frame_of(dmr_test::encode(dmr_test::track(2))));
  CHECK(out.frames_dropped() == 1 && out.buffered_frames() == 0, "disabled voice drops frames");
  out.set_enabled(true);

  // Capacity bound: one second, oldest dropped.
  out.set_capture_8k(nullptr);
  for (int n = 0; n < 60; ++n) out.on_ambe(frame_of(dmr_test::encode(dmr_test::track(n))));
  CHECK(out.buffered_frames() == VoiceOutput::kCapacityFrames && out.samples_overflowed() > 0,
        "queue bounded at %zu frames (%llu overflowed)", out.buffered_frames(),
        static_cast<unsigned long long>(out.samples_overflowed()));
}

// Determinism: same frames -> bit-identical PCM after reset (mbelib's
// unvoiced phase uses rand(); a fresh srand(1) makes runs comparable).
void test_determinism() {
  std::vector<int16_t> a, b;
  for (auto* cap : {&a, &b}) {
    std::srand(1);
    VoiceOutput out;
    out.set_capture_8k(cap);
    for (int n = 0; n < 30; ++n) out.on_ambe(frame_of(dmr_test::encode(dmr_test::track(n))));
  }
  CHECK(a == b && !a.empty(), "identical input + rand seed -> identical PCM (%zu samples)", a.size());
}
#else
void test_disabled_build() {
  VoiceOutput out;
  for (int n = 0; n < 20; ++n) out.on_ambe(frame_of(dmr_test::encode(dmr_test::track(n))));
  float buf[4800];
  CHECK(out.frames_decoded() == 0 && out.frames_dropped() == 20 && out.buffered_frames() == 0 &&
            out.read_audio(buf, 4800) == 0,
        "SDRCORE_ENABLE_MBELIB=OFF: frames counted and dropped, no PCM");
  AmbeSynthesizer s;
  int16_t pcm[160] = {};
  CHECK(!s.decode(dmr_test::encode(dmr_test::track(0)).data(), pcm), "AmbeSynthesizer::decode returns false");
}
#endif

}  // namespace

int main() {
  test_availability();
#if SDRCORE_ENABLE_MBELIB
  test_encoder_roundtrip_with_mbelib();
  test_synthesizer_frames_and_errors();
  test_voice_output_chain();
  test_determinism();
#else
  test_disabled_build();
#endif
  if (failures) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::puts("DMR vocoder tests passed");
  return 0;
}

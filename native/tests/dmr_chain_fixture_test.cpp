// SPDX-License-Identifier: GPL-3.0-or-later
// DMR receive chain against stored pristine OpenWebRX+ outputs.
//
// native/tests/data/dmr_chain/ is written by
//   tool/dmr_chain_oracle/compare.py ... --golden native/tests/data/dmr_chain
// from the unmodified OpenWebRX+ chain (csdr-plus f26b520 + digiham-plus
// beec7822, mbelib 9a04ed5 + codecserver-softmbe 66397fcf). See
// tool/dmr_chain_oracle/README.md and docs/status/dmr-chain-oracle.md.
//   tx.dibits        synthetic BS-sourced DMR, MMDVMHost a819ae64 encoders
//   truth.txt        metadata the transmitter sent
//   <case>.ambe      oracle AMBE frames, <case>.meta oracle per-slot
//                    metadata transitions (slot 0 first, then slot 1)
//   dibits.pcm8k     oracle 8 kHz s16 voice for dibits.ambe (rand() seed 1)
//
// Cases: dibits (sync + framing + FEC on clean symbols), dibits_err (same with
// deterministic symbol errors: Golay/Hamming/BPTC/QR correction paths),
// iq240_cn15 / iq250_cn15 (4FSK through Channel at C/N 15 dB, test modulator).
// The IQ is regenerated here with the same modulator and seed; its noise
// comes from libstdc++'s normal_distribution, so the IQ cases are only valid
// with the toolchain the fixture was generated with (Linux host, libstdc++).
#include "dmr/channel.hpp"
#include "dmr/framing.hpp"
#include "dmr/vocoder.hpp"
#include "dmr_fsk_modulator.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <vector>

#ifndef DMR_CHAIN_FIXTURE_DIR
#error "DMR_CHAIN_FIXTURE_DIR must point at native/tests/data/dmr_chain"
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

using Frame = std::string;  // 9 bytes

std::string read_file(const std::string& name) {
  std::ifstream in(std::string(DMR_CHAIN_FIXTURE_DIR) + "/" + name, std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "missing fixture %s\n", name.c_str());
    std::exit(1);
  }
  return std::string(std::istreambuf_iterator<char>{in}, {});
}

std::vector<Frame> split_frames(const std::string& data) {
  std::vector<Frame> out;
  for (size_t i = 0; i + 9 <= data.size(); i += 9) out.push_back(data.substr(i, 9));
  return out;
}

std::vector<std::string> split_lines(const std::string& data) {
  std::vector<std::string> out;
  size_t at = 0;
  while (at < data.size()) {
    const size_t end = data.find('\n', at);
    const std::string line = data.substr(at, end == std::string::npos ? std::string::npos : end - at);
    if (!line.empty()) out.push_back(line);
    if (end == std::string::npos) break;
    at = end + 1;
  }
  return out;
}

// Same text as tool/dmr_chain_oracle/chain.cpp (native build).
std::string meta_line(const sdrcore::dmr::SlotMeta& m) {
  auto id = [](uint32_t v) { return v ? std::to_string(v) : std::string("-"); };
  std::string s = "M " + std::to_string(unsigned(m.slot)) + ' ' +
                  (m.sync == 2 ? "voice" : m.sync == 1 ? "data" : "-") + ' ' +
                  (m.type == 2 ? "group" : m.type == 1 ? "direct" : "-") + ' ' + id(m.source) +
                  ' ' + id(m.target) + ' ' + (m.alias.empty() ? "-" : m.alias) + ' ';
  if (m.latlon) {
    s += std::to_string(static_cast<float>(m.latlon->first)) + ' ' +
         std::to_string(static_cast<float>(m.latlon->second));
  } else {
    s += "- -";
  }
  return s;
}

struct Result {
  std::vector<Frame> frames;
  std::map<unsigned, std::vector<std::string>> transitions;  // per slot
  std::vector<std::string> flat() const {
    std::vector<std::string> out;
    for (const auto& [slot, lines] : transitions) out.insert(out.end(), lines.begin(), lines.end());
    return out;
  }
};

struct Run {
  Result result;
  sdrcore::dmr::Framing framing{
      [this](const sdrcore::dmr::AmbeFrame& f) {
        result.frames.emplace_back(reinterpret_cast<const char*>(f.bits), sizeof(f.bits));
      },
      [this](const sdrcore::dmr::SlotMeta& m) {
        auto& seq = result.transitions[m.slot];
        std::string line = meta_line(m);
        if (seq.empty() || seq.back() != line) seq.push_back(std::move(line));
      }};
};

// Mirrors compare.py inject_errors().
std::vector<uint8_t> inject_errors(std::vector<uint8_t> d) {
  for (size_t i = 0; i < d.size(); ++i) {
    if (i % 61 == 17) d[i] ^= 1;
    if (i % 211 == 5) d[i] ^= 2;
  }
  return d;
}

Result run_dibits(const std::vector<uint8_t>& dibits) {
  Run run;
  // Odd chunking: frame/sync boundaries must not depend on caller blocks.
  for (size_t at = 0; at < dibits.size(); at += 997)
    run.framing.on_symbols(dibits.data() + at, std::min<size_t>(997, dibits.size() - at));
  return run.result;
}

Result run_iq(const std::vector<uint8_t>& dibits, uint32_t rate, double cnr, uint32_t seed) {
  dmr_test::FskOptions o;
  o.rate = rate;
  o.cnr_db = cnr;
  o.seed = seed;
  const auto iq = dmr_test::modulate_dmr(dibits, o);
  Run run;
  struct Sink final : sdrcore::dmr::SymbolSink {
    sdrcore::dmr::Framing* framing;
    void on_symbols(const uint8_t* d, size_t n) override { framing->on_symbols(d, n); }
  } sink;
  sink.framing = &run.framing;
  sdrcore::dmr::Channel channel;
  if (!channel.configure(rate)) {
    std::fprintf(stderr, "Channel rejected %u S/s\n", rate);
    std::exit(1);
  }
  for (size_t at = 0; at < iq.size(); at += 8192)
    channel.process(iq.data() + at, std::min<size_t>(8192, iq.size() - at), sink);
  return run.result;
}

size_t identical(const std::vector<Frame>& a, const std::vector<Frame>& b) {
  size_t n = 0;
  for (size_t i = 0; i < a.size() && i < b.size(); ++i) n += a[i] == b[i];
  return n;
}

bool contains_all(const std::vector<std::string>& have, const std::vector<std::string>& want) {
  for (const auto& w : want) {
    bool found = false;
    for (const auto& h : have) found |= h == w;
    if (!found) return false;
  }
  return true;
}

// min_identical: minimum count of index-aligned frames equal to the oracle.
void check_case(const char* name, const Result& r, size_t min_identical, bool check_truth,
                const std::vector<std::string>& truth) {
  const auto oracle = split_frames(read_file(std::string(name) + ".ambe"));
  const auto oracle_meta = split_lines(read_file(std::string(name) + ".meta"));
  const size_t same = identical(r.frames, oracle);
  CHECK(!oracle.empty() && r.frames.size() == oracle.size(), "%s: AMBE frame count %zu == oracle %zu",
        name, r.frames.size(), oracle.size());
  CHECK(same >= min_identical, "%s: %zu/%zu AMBE frames identical to oracle (min %zu)", name, same,
        oracle.size(), min_identical);
  CHECK(r.flat() == oracle_meta, "%s: per-slot metadata transitions equal to oracle (%zu)", name,
        oracle_meta.size());
  if (check_truth)
    CHECK(contains_all(r.flat(), truth), "%s: all transmitted metadata decoded (IDs, alias, GPS)", name);
}

}  // namespace

int main() {
  const std::string tx_raw = read_file("tx.dibits");
  const std::vector<uint8_t> tx(tx_raw.begin(), tx_raw.end());
  const auto truth = split_lines(read_file("truth.txt"));

  const Result clean = run_dibits(tx);
  check_case("dibits", clean, 102, true, truth);
  check_case("dibits_err", run_dibits(inject_errors(tx)), 102, false, truth);

  // Voice: Framing frames -> VoiceOutput (softmbe/mbelib, DigitalVoiceFilter,
  // AGC) must reproduce the oracle 8 kHz PCM bit-exactly.
  {
    const std::string pcm_raw = read_file("dibits.pcm8k");
    std::vector<int16_t> oracle(pcm_raw.size() / 2);
    std::memcpy(oracle.data(), pcm_raw.data(), oracle.size() * 2);
    std::srand(1);
    sdrcore::dmr::VoiceOutput out;
    std::vector<int16_t> pcm;
    out.set_capture_8k(&pcm);
    for (const auto& f : clean.frames) {
      sdrcore::dmr::AmbeFrame frame;
      std::memcpy(frame.bits, f.data(), 9);
      out.on_ambe(frame);
    }
    CHECK(pcm == oracle, "voice: %zu PCM samples bit-exact to OpenWebRX+ (%zu)", pcm.size(),
          oracle.size());
  }

  // IQ: measured 102/102 at 240 kS/s and 94/102 at 250 kS/s (the native
  // fractional selector differs from csdr's; see docs/status). Limits leave
  // one frame of slack at 240k for FFTW plan selection and catch regressions.
  check_case("iq240_cn15", run_iq(tx, 240000, 15, 1), 101, true, truth);
  check_case("iq250_cn15", run_iq(tx, 250000, 15, 1), 92, true, truth);

  if (failures) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::printf("all DMR chain fixture checks passed\n");
  return 0;
}

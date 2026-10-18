// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the registered DMR decoder on the same recordings as the pristine
// OpenWebRX+ chain oracle (tests/data/dmr_chain), without tuner control or a
// subprocess. The JSON events of the registry backend must reproduce the
// oracle per-slot metadata transitions for each IQ recording.
#include "decoder.hpp"
#include "dmr/backend.hpp"
#include "dmr/vocoder.hpp"
#include "dmr_fsk_modulator.hpp"
#include <nlohmann/json.hpp>

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <utility>
#include <vector>

#ifndef DMR_CHAIN_FIXTURE_DIR
#error "Missing DMR_CHAIN_FIXTURE_DIR"
#endif

using nlohmann::json;
namespace {
int failures = 0;
#define CHECK(cond, ...)                \
  do {                                  \
    if (cond) {                         \
      std::printf("ok   " __VA_ARGS__); \
    } else {                            \
      std::printf("FAIL " __VA_ARGS__); \
      ++failures;                       \
    }                                   \
    std::printf("\n");                  \
  } while (0)

std::string fixture(const std::string& name) {
  std::ifstream file(std::string(DMR_CHAIN_FIXTURE_DIR) + "/" + name, std::ios::binary);
  assert(file);
  return {std::istreambuf_iterator<char>(file), {}};
}

std::vector<std::string> lines(const std::string& text) {
  std::vector<std::string> out;
  size_t at = 0;
  while (at < text.size()) {
    const auto end = text.find('\n', at);
    auto line = text.substr(at, end == std::string::npos ? std::string::npos : end - at);
    if (!line.empty()) out.push_back(line);
    if (end == std::string::npos) break;
    at = end + 1;
  }
  return out;
}

std::vector<json> drain(sdrcore::decoder::Decoder& backend) {
  sdrcore::decoder::Event event;
  std::vector<json> result;
  while (backend.take_event(event)) {
    assert(event.kind == sdrcore::decoder::Result::message);
    result.push_back(json::parse(event.payload.begin(), event.payload.end()));
  }
  return result;
}

// Same text as tool/dmr_chain_oracle/chain.cpp, rebuilt from the backend's
// JSON so the comparison covers the event encoding, not just Framing.
std::string meta_line(const json& e) {
  auto id = [&](const char* key) {
    const auto v = e.value(key, 0u);
    return v ? std::to_string(v) : std::string("-");
  };
  std::string s = "M " + std::to_string(e.at("slot").get<unsigned>()) + ' ' +
                  e.value("sync", std::string("-")) + ' ' + e.value("type", std::string("-")) +
                  ' ' + id("source") + ' ' + id("target") + ' ' +
                  e.value("talkeralias", std::string("-")) + ' ';
  if (e.contains("lat") && e.contains("lon")) {
    s += std::to_string(static_cast<float>(e["lat"].get<double>())) + ' ' +
         std::to_string(static_cast<float>(e["lon"].get<double>()));
  } else {
    s += "- -";
  }
  return s;
}

struct Run {
  std::vector<std::string> meta;  // per-slot transitions, slot 0 first
  size_t audio_frames = 0;
  double seconds = 0;
  double signal_seconds = 0;
};

Run run_iq(sdrcore::decoder::Decoder& backend, const std::vector<uint8_t>& dibits, uint32_t rate) {
  assert(backend.configure(R"({"schema":"dmr/1","slot_filter":3,"color_code":-1,"voice":true})"));
  drain(backend);  // Reset announces "no sync" for both slots; not part of the recording.
  dmr_test::FskOptions options;
  options.rate = rate;
  options.cnr_db = 15;
  options.seed = 1;
  const auto iq = dmr_test::modulate_dmr(dibits, options);
  Run run;
  run.signal_seconds = double(iq.size()) / rate;
  std::vector<json> events;
  std::vector<float> interleaved;
  float audio[4096];
  for (size_t at = 0; at < iq.size(); at += 8192) {
    const size_t count = std::min<size_t>(8192, iq.size() - at);
    interleaved.resize(count * 2);
    for (size_t i = 0; i < count; ++i) {
      interleaved[i * 2] = iq[at + i].real();
      interleaved[i * 2 + 1] = iq[at + i].imag();
    }
    const auto start = std::chrono::steady_clock::now();
    backend.process(interleaved.data(), count, rate);
    run.seconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    auto next = drain(backend);
    events.insert(events.end(), next.begin(), next.end());
    while (const size_t n = backend.read_audio(audio, std::size(audio))) run.audio_frames += n;
  }
  std::map<unsigned, std::vector<std::string>> per_slot;
  for (const auto& event : events) {
    assert(event.at("schema") == "dmr/1" && event.at("protocol") == "DMR");
    auto& seq = per_slot[event.at("slot").get<unsigned>()];
    auto line = meta_line(event);
    if (seq.empty() || seq.back() != line) seq.push_back(std::move(line));
  }
  for (const auto& [slot, seq] : per_slot) run.meta.insert(run.meta.end(), seq.begin(), seq.end());
  return run;
}

bool contains_all(const std::vector<std::string>& have, const std::vector<std::string>& want) {
  for (const auto& w : want)
    if (std::find(have.begin(), have.end(), w) == have.end()) return false;
  return true;
}
}  // namespace

int main() {
  auto backend = sdrcore::decoder::create_dmr();
  assert(backend);
  assert(!backend->configure(R"({"schema":"dmr/2","slot_filter":3,"color_code":-1,"voice":true})"));
  assert(!backend->configure(R"({"schema":"dmr/1","slot_filter":0,"color_code":-1,"voice":true})"));
  assert(!backend->configure(R"({"schema":"dmr/1","slot_filter":3,"color_code":16,"voice":true})"));
  assert(backend->configure(R"({"schema":"dmr/1","slot_filter":3,"color_code":-1,"voice":true})"));
  assert(backend->provides_audio() == sdrcore::dmr::vocoder_available());

  const auto bytes = fixture("tx.dibits");
  const std::vector<uint8_t> dibits(bytes.begin(), bytes.end());
  const auto truth = lines(fixture("truth.txt"));

  // Same recordings as dmr_chain_fixture_test's iq240_cn15 / iq250_cn15 cases,
  // whose .meta files were produced by the unmodified OpenWebRX+ chain.
  const std::pair<const char*, uint32_t> cases[] = {{"iq240_cn15", 240000}, {"iq250_cn15", 250000}};
  for (const auto& [name, rate] : cases) {
    const auto oracle = lines(fixture(std::string(name) + ".meta"));
    const auto run = run_iq(*backend, dibits, rate);
    CHECK(run.meta == oracle, "%s: backend JSON metadata transitions == OpenWebRX+ oracle (%zu/%zu)",
          name, run.meta.size(), oracle.size());
    if (run.meta != oracle)
      for (const auto& line : run.meta) std::printf("     got %s\n", line.c_str());
    CHECK(contains_all(run.meta, truth), "%s: all transmitted IDs, alias and GPS decoded", name);
    if (sdrcore::dmr::vocoder_available()) {
      CHECK(run.audio_frames > 0, "%s: %zu frames of 48 kHz voice PCM (%.2f s)", name,
            run.audio_frames, run.audio_frames / 48000.0);
    } else {
      CHECK(run.audio_frames == 0, "%s: no PCM without mbelib", name);
    }
    std::printf("info %s: %.3f s CPU for %.3f s of IQ, real-time factor %.1fx\n", name,
                run.seconds, run.signal_seconds, run.signal_seconds / run.seconds);
    CHECK(run.seconds < run.signal_seconds, "%s: faster than real time", name);
  }

  backend->reset();
  auto events = drain(*backend);
  assert(events.size() == 2);
  for (const auto& event : events) {
    assert(!event.contains("sync"));
    assert(!event.contains("source"));
  }
  float audio[4096];
  assert(backend->read_audio(audio, std::size(audio)) == 0);
  assert(backend->configure(R"({"schema":"dmr/1","slot_filter":1,"color_code":2,"voice":false})"));
  assert(!backend->provides_audio());
  assert(backend->configure(R"({"schema":"dmr/1","slot_filter":3,"color_code":-1,"voice":true})"));
  assert(drain(*backend).size() == 2);

  if (failures) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::printf("all DMR backend checks passed\n");
  return 0;
}

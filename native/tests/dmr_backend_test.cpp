// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the registered DMR decoder on the same dibits/voice corpus as the
// pristine OpenWebRX+ chain oracle, without tuner control or a subprocess.
#include "decoder.hpp"
#include "dmr/backend.hpp"
#include "dmr/vocoder.hpp"
#include "dmr_fsk_modulator.hpp"
#include <nlohmann/json.hpp>

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#ifndef DMR_CHAIN_FIXTURE_DIR
#error "Missing DMR_CHAIN_FIXTURE_DIR"
#endif

using nlohmann::json;
namespace {
std::string fixture(const char* name) {
  std::ifstream file(std::string(DMR_CHAIN_FIXTURE_DIR) + "/" + name, std::ios::binary);
  assert(file);
  return {std::istreambuf_iterator<char>(file), {}};
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
  dmr_test::FskOptions options;
  options.rate = 240000;
  options.cnr_db = 15;
  options.seed = 1;
  const auto iq = dmr_test::modulate_dmr(dibits, options);
  std::vector<json> events;
  std::vector<float> interleaved;
  for (size_t at = 0; at < iq.size(); at += 8192) {
    const size_t count = std::min<size_t>(8192, iq.size() - at);
    interleaved.resize(count * 2);
    for (size_t i = 0; i < count; ++i) {
      interleaved[i * 2] = iq[at + i].real();
      interleaved[i * 2 + 1] = iq[at + i].imag();
    }
    backend->process(interleaved.data(), count, options.rate);
    auto next = drain(*backend);
    events.insert(events.end(), next.begin(), next.end());
    float audio[4096]{};
    backend->read_audio(audio, std::size(audio));
  }
  bool decoded = false;
  for (const auto& event : events) {
    assert(event.at("schema") == "dmr/1" && event.at("protocol") == "DMR");
    assert(event.at("slot") == 0 || event.at("slot") == 1);
    if (event.value("source", 0) != 0 && event.value("target", 0) != 0)
      decoded = true;
  }
  assert(decoded && "the upstream corpus must yield source and destination IDs");
  backend->reset();
  events = drain(*backend);
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
}

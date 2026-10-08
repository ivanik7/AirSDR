// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone white-box ABI test: compile with sdrcore.cpp, receiver.cpp, USB
// adapters and audio sink, but not the production registry/decoder backend.
#include "../src/sdrcore.cpp"
#include <cassert>
#include <string_view>

namespace sdrcore::decoder {
class ProbeDecoder final : public Decoder {
 public:
  bool configure(std::string_view json) override { return json == "{\"version\":1}"; }
  void reset() override { pending.clear(); }
  void process(const float*, size_t, uint32_t) override {}
  bool take_event(Event& event) override {
    if (pending.empty()) return false;
    event = std::move(pending.front()); pending.pop_front(); return true;
  }
  std::deque<Event> pending;
};
std::unique_ptr<Decoder> make_probe() { return std::make_unique<ProbeDecoder>(); }
const std::vector<Registration>& registry() {
  static const std::vector<Registration> entries = {{
      {"probe", Input::baseband, false, UINT32_MAX, 0, Result::message}, &make_probe}};
  return entries;
}
} // namespace sdrcore::decoder

int main() {
  SdrHandle* h = sdr_create();
  assert(sdr_v2_open_synthetic(h, 192000) == SDR_OK);
  SdrV3Controls c{};
  c.size = sizeof c; c.revision = SDR_V3_REVISION;
  c.sample_rate = 192000; c.center_frequency_hz = 433920000;
  c.mode = SDR_V3_NFM; c.bandwidth_hz = 12000;
  c.volume = 1; c.squelch = SDR_V3_SQUELCH_OFF;
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  const char* config = "{\"version\":1}";
  assert(sdr_decoder_select(h, "probe", 5, config, std::strlen(config)) == SDR_UNSUPPORTED);
  c.sample_rate = 240000; assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  assert(sdr_decoder_select(h, "probe", 5, "{}", 2) == SDR_INVALID_ARGUMENT);
  assert(sdr_decoder_select(h, "probe", 5, config, std::strlen(config)) == SDR_OK);
  auto* probe = static_cast<sdrcore::decoder::ProbeDecoder*>(h->decoder.get());
  c.sample_rate = 192000;
  assert(sdr_v3_set_controls(h, &c) == SDR_UNSUPPORTED);
  c.sample_rate = 240000;
  assert(h->decoder.get() == probe);
  assert(sdr_decoder_select(h, "probe", 5, "{}", 2) == SDR_INVALID_ARGUMENT);
  assert(h->decoder.get() == probe);
  assert(sdr_v3_start(h) == SDR_OK);
  // Publish more than FIFO capacity without relying on RF protocol timing.
  {
    std::lock_guard<std::mutex> dsp(h->dsp_mutex);
    std::lock_guard<std::mutex> state(h->mutex);
    for (uint32_t i = 0; i < 300; ++i) {
      sdrcore::decoder::Event e{sdrcore::decoder::Result::message, {static_cast<uint8_t>(i)}};
      probe->pending.push_back(std::move(e));
      h->drain_decoder_events();
    }
  }
  assert(h->decoder_events.size() == 256 && h->decoder_dropped == 44);
  SdrDecoderEvent out{}; out.size = sizeof out; out.revision = SDR_DECODER_REVISION;
  uint8_t byte = 0;
  assert(sdr_decoder_poll(h, 0, &out, nullptr, 0) == SDR_DECODER_BUFFER_SMALL);
  assert(out.payload_bytes == 1 && out.sequence == 0);
  assert(sdr_decoder_poll(h, 0, &out, &byte, 1) == SDR_OK);
  assert(out.sequence == 45 && out.dropped_events == 44 && byte == 44);
  assert(sdr_decoder_poll(h, 45, &out, &byte, 1) == SDR_OK);
  assert(out.sequence == 46 && byte == 45);
  {
    std::lock_guard<std::mutex> dsp(h->dsp_mutex);
    std::lock_guard<std::mutex> state(h->mutex);
    probe->pending.push_back({sdrcore::decoder::Result::message,
                              std::vector<uint8_t>(SDR_DECODER_MAX_PAYLOAD + 1, 1)});
    h->drain_decoder_events();
  }
  assert(h->decoder_dropped == 45 && h->decoder_events.size() == 256);
  c.vfo_offset_hz = 10000;
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  assert(sdr_decoder_poll(h, 0, &out, &byte, 1) == SDR_DECODER_NO_DATA);
  assert(out.sequence == 46); // NO_DATA leaves outputs intact.
  assert(sdr_v3_stop(h) == SDR_OK);
  assert(sdr_decoder_poll(h, 0, &out, &byte, 1) == SDR_DECODER_NO_DATA);
  assert(sdr_v3_start(h) == SDR_OK);
  assert(sdr_decoder_poll(h, 0, &out, &byte, 1) == SDR_DECODER_NO_DATA);
  assert(sdr_v3_stop(h) == SDR_OK);
  assert(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);
}

// Symbol-level DMR framing adapter around digiham (GPL-3.0), not a DSP demodulator.
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace sdrcore::dmr {
struct AmbeFrame {
    uint8_t slot;
    uint8_t bits[9]; // Interleaved 72 bits, MSB first; 3 frames per voice burst.
};
struct SlotMeta {
    uint8_t slot = 0; // 0=TS1, 1=TS2, as in digiham.
    int sync = -1; // -1=no sync, 1=data, 2=voice.
    int type = -1; // -1=unknown, 1=direct, 2=group.
    uint32_t source = 0;
    uint32_t target = 0;
    uint8_t color_code = 0xff; // Unknown until a valid EMB or SlotType.
    std::optional<bool> privacy; // Indication only. No decryption.
    uint32_t duration_ms = 0; // Observed voice-slot frames, not wall-clock time.
    std::string alias;
    std::optional<std::pair<double, double>> latlon;
};
class Framing {
public:
    using VoiceSink = std::function<void(const AmbeFrame&)>;
    using MetaSink = std::function<void(const SlotMeta&)>;
    Framing(VoiceSink voice, MetaSink metadata);
    ~Framing();
    Framing(const Framing&) = delete;
    Framing& operator=(const Framing&) = delete;
    void on_symbols(const uint8_t* dibits, size_t n); // digiham symbols 0..3, at 4800/s.
    void set_slot_filter(uint8_t mask); // 1=TS1, 2=TS2, 3=both.
    void set_color_filter(int color); // -1=off, 0..15=allowed CC.
    void reset(); // retune/generation boundary; emits no-sync for both slots.
private:
    struct State;
    std::unique_ptr<State> state_;
    VoiceSink voice_;
    MetaSink metadata_;
    uint8_t slot_filter_ = 3;
    int color_filter_ = -1;
    std::vector<uint8_t> pending_;
    std::array<SlotMeta, 2> last_{};
    void on_metadata(const std::map<std::string, std::string>& fields);
};
}

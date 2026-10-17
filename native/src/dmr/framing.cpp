#include "framing.hpp"
#include "dmr_phase.hpp"
#include "dmr_meta.hpp"

#include <algorithm>
#include <cstring>
#include <utility>

namespace sdrcore::dmr {
namespace {
class CallbackWriter final : public Digiham::MetaWriter {
public:
    explicit CallbackWriter(std::function<void(const std::map<std::string, std::string>&)> cb)
        : callback_(std::move(cb)) {}
    void sendMetaData(std::map<std::string, std::string> fields) override { callback_(fields); }
private:
    std::function<void(const std::map<std::string, std::string>&)> callback_;
};
uint32_t number(const std::map<std::string, std::string>& fields, const char* key) {
    auto it = fields.find(key);
    return it == fields.end() ? 0 : static_cast<uint32_t>(std::stoul(it->second));
}
}
struct Framing::State {
    explicit State(Framing* owner) : writer([owner](const auto& m) { owner->on_metadata(m); }) {
        meta.setWriter(&writer);
        phase = std::make_unique<Digiham::Dmr::SyncPhase>();
        phase->setMetaCollector(&meta);
    }
    Digiham::Dmr::MetaCollector meta;
    CallbackWriter writer;
    std::unique_ptr<Digiham::Phase> phase;
};
Framing::Framing(VoiceSink voice, MetaSink metadata)
    : state_(std::make_unique<State>(this)), voice_(std::move(voice)), metadata_(std::move(metadata)) {
    last_[0].slot = 0;
    last_[1].slot = 1;
}
Framing::~Framing() = default;

void Framing::on_metadata(const std::map<std::string, std::string>& fields) {
    const auto index = number(fields, "slot");
    if (index > 1) return;
    SlotMeta next;
    next.slot = static_cast<uint8_t>(index);
    if (auto it = fields.find("sync"); it != fields.end())
        next.sync = it->second == "voice" ? 2 : it->second == "data" ? 1 : -1;
    if (auto it = fields.find("type"); it != fields.end())
        next.type = it->second == "group" ? 2 : it->second == "direct" ? 1 : -1;
    next.source = number(fields, "source");
    next.target = number(fields, "target");
    if (auto it = fields.find("color_code"); it != fields.end())
        next.color_code = static_cast<uint8_t>(std::stoul(it->second));
    if (auto it = fields.find("privacy"); it != fields.end()) next.privacy = it->second == "true";
    next.duration_ms = number(fields, "duration_ms");
    if (auto it = fields.find("talkeralias"); it != fields.end()) next.alias = it->second;
    if (fields.count("lat") && fields.count("lon"))
        next.latlon = std::make_pair(std::stod(fields.at("lat")), std::stod(fields.at("lon")));
    if (color_filter_ >= 0 && next.color_code != color_filter_) {
        if (last_[index].sync >= 0) {
            last_[index] = SlotMeta{};
            last_[index].slot = static_cast<uint8_t>(index);
            if (metadata_) metadata_(last_[index]);
        }
        return;
    }
    last_[index] = next;
    if (metadata_) metadata_(next);
}

void Framing::on_symbols(const uint8_t* dibits, size_t n) {
    if (n == 0 || !dibits) return;
    // No fake correction of out-of-alphabet symbols: reject the whole bad batch.
    if (std::any_of(dibits, dibits + n, [](uint8_t v) { return v > 3; })) return;
    pending_.insert(pending_.end(), dibits, dibits + n);
    size_t consumed = 0;
    while (pending_.size() - consumed >= static_cast<size_t>(state_->phase->getRequiredData())) {
        Csdr::Reader<unsigned char> reader(pending_.data() + consumed);
        uint8_t payload[27] = {};
        Csdr::Writer<unsigned char> writer(payload);
        auto* previous = state_->phase.get();
        auto* next = previous->process(&reader, &writer);
        if (next != previous) {
            state_->phase.reset(next);
            state_->phase->setMetaCollector(&state_->meta);
            if (auto* frame = dynamic_cast<Digiham::Dmr::FramePhase*>(next)) {
                frame->setSlotFilter(slot_filter_);
                frame->setColorFilter(color_filter_);
            }
        }
        if (writer.offset() == 27 && voice_) {
            const auto* frame = dynamic_cast<Digiham::Dmr::FramePhase*>(state_->phase.get());
            if (frame && frame->getActiveSlot() >= 0) {
                for (unsigned i = 0; i < 3; ++i) {
                    AmbeFrame output{};
                    output.slot = static_cast<uint8_t>(frame->getActiveSlot());
                    std::memcpy(output.bits, payload + i * 9, 9);
                    voice_(output);
                }
            }
        }
        // SyncPhase switches phase without consuming; FramePhase may switch back
        // after losing sync. Reprocess the same window in the new phase.
        if (reader.offset() == 0 && next == previous) break;
        consumed += reader.offset();
    }
    if (consumed) pending_.erase(pending_.begin(), pending_.begin() + consumed);
}
void Framing::set_slot_filter(uint8_t mask) {
    if (mask < 1 || mask > 3) return;
    slot_filter_ = mask;
    if (auto* frame = dynamic_cast<Digiham::Dmr::FramePhase*>(state_->phase.get()))
        frame->setSlotFilter(mask);
}
void Framing::set_color_filter(int color) {
    if (color < -1 || color > 15) return;
    color_filter_ = color;
    if (auto* frame = dynamic_cast<Digiham::Dmr::FramePhase*>(state_->phase.get()))
        frame->setColorFilter(color);
    for (size_t slot = 0; slot < 2; ++slot) {
        if (last_[slot].sync >= 0 && color >= 0 && last_[slot].color_code != color) {
            last_[slot] = SlotMeta{};
            last_[slot].slot = static_cast<uint8_t>(slot);
            if (metadata_) metadata_(last_[slot]);
        }
    }
}
void Framing::reset() {
    pending_.clear();
    state_ = std::make_unique<State>(this);
    for (size_t slot = 0; slot < 2; ++slot) {
        last_[slot] = SlotMeta{};
        last_[slot].slot = static_cast<uint8_t>(slot);
        if (metadata_) metadata_(last_[slot]);
    }
}
}

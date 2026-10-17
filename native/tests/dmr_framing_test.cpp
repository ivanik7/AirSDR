#include "dmr/framing.hpp"
#include "dmr_meta.hpp"
#include "lc.hpp"
#include "gps.hpp"
#include "talkeralias.hpp"
#include "embedded.hpp"
extern "C" {
#include "hamming_7_4.h"
#include "quadratic_residue.h"
#include "bptc_196_96.h"
#include "golay_20_8.h"
}
#include <array>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <memory>
#include <vector>

using sdrcore::dmr::AmbeFrame;
using sdrcore::dmr::Framing;
using sdrcore::dmr::SlotMeta;
namespace {
constexpr std::array<uint8_t, 24> bs_voice = {1,3,1,1,1,1,3,3,3,1,1,3,3,1,3,3,1,3,1,1,3,3,1,3};
constexpr std::array<uint8_t, 24> ms_voice = {1,3,3,3,1,3,3,1,1,1,3,1,3,1,1,1,1,3,3,1,3,3,3,1};
constexpr std::array<uint8_t, 24> bs_data = {3,1,3,3,3,3,1,1,1,3,3,1,1,3,1,1,3,1,3,3,1,1,3,1};
constexpr std::array<uint8_t, 24> ms_data = {3,1,1,1,3,1,1,3,3,3,1,3,1,3,3,3,3,1,1,3,1,1,1,3};

std::vector<uint8_t> burst(unsigned slot, const std::array<uint8_t, 24>& sync) {
    std::vector<uint8_t> out(144, 0);
    // CACH TACT: systematic [busy,slot,LCSS(2),parity(3)] Hamming(7,4).
    const int pos[] = {0, 4, 8, 12, 14, 18, 22};
    uint8_t tact = 0;
    for (unsigned i = 0; i < 128; ++i) {
        auto candidate = static_cast<uint8_t>(i);
        if (hamming_7_4_parity(&candidate) == 0 && ((i >> 5) & 1) == slot) {
            tact = static_cast<uint8_t>(i);
            break;
        }
    }
    for (int i = 0; i < 7; ++i) {
        int bit = (tact >> (6 - i)) & 1;
        out[pos[i] / 2] |= bit << (1 - pos[i] % 2);
    }
    for (int i = 0; i < 54; ++i) {
        out[12+i] = static_cast<uint8_t>(i % 4);
        out[90+i] = static_cast<uint8_t>((i+1) % 4);
    }
    for (size_t i = 0; i < sync.size(); ++i) out[66+i] = sync[i];
    return out;
}
uint16_t emb(unsigned cc) {
    for (unsigned i = 0; i < 512; ++i) {
        uint16_t word = static_cast<uint16_t>((cc << 12) | i);
        if (quadratic_residue_parity(&word) == 0) return word;
    }
    assert(false);
    return 0;
}
void inject_emb(std::vector<uint8_t>& b, unsigned cc) {
    uint16_t word = emb(cc);
    for (int i = 0; i < 4; ++i) {
        b[66+i] = static_cast<uint8_t>((word >> (14-i*2)) & 3);
        b[86+i] = static_cast<uint8_t>((word >> (6-i*2)) & 3);
    }
}
void feed(Framing& f, const std::vector<uint8_t>& b) {
    // Deliberately split across sync and burst boundaries.
    for (size_t i = 0; i < b.size(); i += 17) f.on_symbols(b.data()+i, std::min<size_t>(17, b.size()-i));
}
}
int main() {
    // Upstream LC mapping plus the opt-in privacy indicator (never decrypt).
    unsigned char group_lc[9] = {0, 0, 0x40, 0, 0, 91, 0x27, 0xfb, 0x11};
    Digiham::Dmr::Lc group(group_lc);
    Digiham::Dmr::Slot slot;
    slot.setFromLc(&group);
    slot.setColorCode(7);
    auto fields = slot.collect();
    assert(fields.at("type") == "group" && fields.at("target") == "91");
    assert(fields.at("source") == "2620177" && fields.at("privacy") == "true");
    assert(fields.at("color_code") == "7");
    group_lc[0] = 3;
    group_lc[2] = 0;
    Digiham::Dmr::Lc direct(group_lc);
    slot.setFromLc(&direct);
    assert(slot.collect().at("type") == "direct" && slot.collect().at("privacy") == "false");
    unsigned char gps_data[7] = {0, 0, 0, 0, 0, 0, 0};
    slot.setCoordinate(Digiham::Dmr::Gps::parse(gps_data));
    assert(slot.collect().at("lat") == "0.000000");
    unsigned char alias_hdr[7] = {static_cast<unsigned char>((1 << 6) | (2 << 1)), 'A', 'B'};
    Digiham::Dmr::TalkerAliasCollector alias;
    alias.setBlock(0, alias_hdr);
    assert(alias.isComplete() && alias.getContents() == "AB");
    Digiham::Dmr::EmbeddedCollector embedded;
    unsigned char fragment[4] = {};
    for (int i = 0; i < 3; ++i) embedded.collect(fragment);
    assert(embedded.getLc() == nullptr); // No fourth fragment: must not read garbage.
    embedded.collect(fragment);
    std::unique_ptr<Digiham::Dmr::Lc> embedded_lc(embedded.getLc());
    assert(embedded_lc && embedded_lc->getOpCode() == 0);

    uint8_t zeros[25] = {};
    uint8_t decoded[12] = {};
    assert(bptc_196_96(zeros, decoded));
    zeros[9] ^= 0x20;
    assert(bptc_196_96(zeros, decoded)); // Column/row single-bit correction.
    uint16_t codeword = emb(7);
    uint16_t corrupt = codeword ^ 0x10;
    assert(quadratic_residue(&corrupt) && corrupt == codeword);
    uint32_t golay = 0x15;
    assert(golay_20_8(&golay) && golay == 0); // Upstream three-bit correction.
    uint8_t tact = 0x40;
    // The upstream Hamming decoder returns corrected, systematic payload.
    assert(hamming_7_4(&tact));
    std::vector<AmbeFrame> voice;
    std::vector<SlotMeta> metadata;
    Framing f([&](const AmbeFrame& frame) { voice.push_back(frame); },
              [&](const SlotMeta& slot) { metadata.push_back(slot); });
    auto one = burst(0, bs_voice);
    auto two = burst(1, bs_voice);
    feed(f, one);
    feed(f, two);
    assert(voice.size() == 3); // Only the first voice slot wins upstream.
    assert(voice[0].slot == 0);
    assert(voice[0].bits[0] == 0x1b); // dibits 0,1,2,3 in MSB order.
    assert(!metadata.empty() && metadata.front().slot == 0 && metadata.front().sync == 2);
    f.set_slot_filter(2);
    feed(f, one);
    feed(f, two);
    assert(voice.size() == 6 && voice.back().slot == 1);
    f.reset();
    assert(metadata[metadata.size()-1].sync == -1);
    assert(metadata[metadata.size()-2].sync == -1);
    f.set_slot_filter(3);
    f.set_color_filter(7);
    feed(f, one);
    feed(f, two);
    assert(voice.size() == 6); // CC unknown on voice-sync burst.
    one = burst(0, bs_voice);
    inject_emb(one, 7);
    two = burst(1, bs_voice);
    inject_emb(two, 8);
    feed(f, one);
    feed(f, two);
    assert(voice.size() == 9 && voice.back().slot == 0);
    assert(metadata.back().slot == 0);
    bool saw_cc = false;
    for (const auto& m : metadata) if (m.slot == 0 && m.color_code == 7) saw_cc = true;
    assert(saw_cc);
    f.reset();
    f.set_slot_filter(3);
    f.set_color_filter(-1);
    feed(f, burst(0, ms_voice));
    feed(f, burst(1, ms_data));
    assert(metadata.back().sync == 1);
    const auto before_bad_sync = voice.size();
    f.reset();
    auto bad = burst(0, bs_voice);
    for (int i = 0; i < 4; ++i) bad[66+i] ^= 1;
    feed(f, bad);
    assert(voice.size() == before_bad_sync); // Invalid sync cannot lock a fresh stream.
    for (const auto& [pattern, expected_sync] :
         {std::pair{bs_voice, 2}, std::pair{ms_voice, 2},
          std::pair{bs_data, 1}, std::pair{ms_data, 1}}) {
        f.reset();
        auto noisy = burst(0, pattern);
        for (int i = 0; i < 3; ++i) noisy[66+i] ^= 1;
        auto previous_events = metadata.size();
        feed(f, noisy);

        assert(metadata.size() > previous_events);
        assert(metadata.back().sync == expected_sync);
    }
    std::cout << "DMR framing/slot/FEC tests passed\n";
}

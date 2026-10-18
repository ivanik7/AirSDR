// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic DMR Tier II repeater (BS-sourced) transmission, encoded with the
// unmodified MMDVMHost DMR classes (g4klx/MMDVMHost a819ae64, GPL-2.0-or-later:
// BPTC(196,96), RS(12,9), Golay(20,8), QR(16,7), Hamming(16,11), CRC-5,
// syncs) plus an ETSI Hamming(7,4) TACT encoder. No on-air recording and no
// speech: the AMBE+2 payloads come from the project's parameter-vector test
// encoder (native/tests/dmr_ambe_test_encoder.hpp).
//
//   dmr_tx_encode OUT_DIR
// writes OUT_DIR/tx.dibits   (digiham symbols 0..3, one byte each, CACH first)
//        OUT_DIR/tx_ts1.ambe, tx_ts2.ambe (9-byte frames transmitted per slot)
//        OUT_DIR/truth.txt   (per-slot metadata that a decoder must report)
#include "BPTC19696.h"
#include "DMRDefines.h"
#include "DMREMB.h"
#include "DMREmbeddedData.h"
#include "DMRFullLC.h"
#include "DMRLC.h"
#include "DMRSlotType.h"
#include "Sync.h"

#include "dmr_ambe_test_encoder.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace {

constexpr unsigned char kColorCode = 1;
using Burst = std::array<unsigned char, 33>;

struct Call {
  int slot;            // 0 = TS1, 1 = TS2
  int start_pair;      // first burst pair carrying the voice LC header
  FLCO flco;           // GROUP or USER_USER
  unsigned src, dst;
  bool alias_and_gps;  // superframes 2..4 carry TA header/block1 and GPS
};

// Talker alias "SDR-ORACLE", 8-bit format: header byte = format<<6 | len<<1.
const char kAlias[] = "SDR-ORACLE";
// GPS embedded LC in digiham's sign-magnitude reading (see STATUS):
// lat 51.5 -> 4800451, lon -0.125 -> 11651 with the sign bit.
constexpr unsigned kLatBits = 4800451, kLonBits = 11651;

CDMRLC lc_bytes(unsigned char flco, const unsigned char data[7]) {
  unsigned char bytes[9] = {flco, 0};
  std::memcpy(bytes + 2, data, 7);
  return CDMRLC(bytes);
}

CDMRLC embedded_lc(const Call& call, int superframe) {
  if (call.alias_and_gps && superframe == 1) {
    unsigned char d[7] = {static_cast<unsigned char>((1 << 6) | ((sizeof(kAlias) - 1) << 1))};
    std::memcpy(d + 1, kAlias, 6);
    return lc_bytes(4, d);
  }
  if (call.alias_and_gps && superframe == 2) {
    unsigned char d[7] = {};
    std::memcpy(d, kAlias + 6, sizeof(kAlias) - 1 - 6);
    return lc_bytes(5, d);
  }
  if (call.alias_and_gps && superframe == 3) {
    const unsigned char d[7] = {0x01, (kLonBits >> 16) & 0xff, (kLonBits >> 8) & 0xff,
                                kLonBits & 0xff, (kLatBits >> 16) & 0x7f,
                                (kLatBits >> 8) & 0xff, kLatBits & 0xff};
    return lc_bytes(8, d);
  }
  return CDMRLC(call.flco, call.src, call.dst);
}

Burst data_burst(unsigned char type, const CDMRLC* lc) {
  Burst b{};
  if (lc != nullptr) {
    CDMRFullLC full;
    full.encode(*lc, b.data(), type);
  } else {
    unsigned char zero[12] = {};
    CBPTC19696 bptc;
    bptc.encode(zero, b.data());
  }
  CDMRSlotType slot_type;
  slot_type.setColorCode(kColorCode);
  slot_type.setDataType(type);
  slot_type.getData(b.data());
  CSync::addDMRDataSync(b.data(), true);
  return b;
}

void put_bits(Burst& b, size_t at, const dmr_test::Frame9& frame, size_t from, size_t n) {
  for (size_t i = 0; i < n; ++i) {
    const size_t src = from + i, dst = at + i;
    const int bit = (frame[src / 8] >> (7 - src % 8)) & 1;
    b[dst / 8] = static_cast<unsigned char>((b[dst / 8] & ~(0x80 >> (dst % 8))) | (bit << (7 - dst % 8)));
  }
}

// 216 AMBE bits: 108 before the sync/EMB field, 108 after it.
Burst voice_burst(const std::array<dmr_test::Frame9, 3>& frames, int position,
                  CDMREmbeddedData& embedded) {
  Burst b{};
  for (size_t k = 0; k < 3; ++k) {
    for (size_t i = 0; i < 72; ++i) {
      const size_t bit = k * 72 + i;
      put_bits(b, bit < 108 ? bit : bit + 48, frames[k], i, 1);
    }
  }
  if (position == 0) {
    CSync::addDMRAudioSync(b.data(), true);
  } else {
    // Bursts B..E: LC fragments 1..4; F: no embedded LC (LCSS single).
    const unsigned char lcss = embedded.getData(b.data(), position <= 4 ? position : 0);
    CDMREMB emb;
    emb.setColorCode(kColorCode);
    emb.setPI(false);
    emb.setLCSS(lcss);
    emb.getData(b.data());
  }
  return b;
}

// ETSI TS 102 361-1 B.3.5 Hamming(7,4) generator rows for AT, TC, LCSS1, LCSS0.
unsigned char tact(int slot) {
  static constexpr unsigned char rows[4] = {0b1000101, 0b0100111, 0b0010110, 0b0001011};
  const unsigned char data = static_cast<unsigned char>(0b1000 | (slot << 2));  // AT busy, LCSS 0
  unsigned char word = 0;
  for (int i = 0; i < 4; ++i)
    if (data & (8 >> i)) word ^= rows[i];
  return word;
}

void append(std::vector<uint8_t>& out, int slot, const Burst& b) {
  static constexpr int kTactPositions[7] = {0, 4, 8, 12, 14, 18, 22};
  uint8_t cach[12] = {};
  const unsigned char t = tact(slot);
  for (int i = 0; i < 7; ++i) {
    const int pos = kTactPositions[i];
    cach[pos / 2] |= static_cast<uint8_t>(((t >> (6 - i)) & 1) << (1 - pos % 2));
  }
  out.insert(out.end(), cach, cach + 12);
  for (int i = 0; i < 132; ++i)
    out.push_back(static_cast<uint8_t>((b[i / 4] >> (6 - 2 * (i % 4))) & 3));
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s OUT_DIR\n", argv[0]);
    return 2;
  }
  const std::string dir = argv[1];
  const Call calls[2] = {
      {0, 30, FLCO::GROUP, 2345678, 91, true},
      {1, 40, FLCO::USER_USER, 1234567, 7654321, false},
  };
  constexpr int kSuperframes = 4, kPairs = 80;
  std::vector<uint8_t> dibits;
  std::vector<dmr_test::Frame9> sent[2];
  CDMREmbeddedData embedded[2];
  int voice_index = 0;
  for (int pair = 0; pair < kPairs; ++pair) {
    for (const Call& call : calls) {
      const int rel = pair - call.start_pair;
      const int voice_bursts = 6 * kSuperframes;
      Burst b;
      if (rel == 0 || rel == 1) {
        const CDMRLC lc(call.flco, call.src, call.dst);
        b = data_burst(DT_VOICE_LC_HEADER, &lc);
      } else if (rel >= 2 && rel < 2 + voice_bursts) {
        const int n = rel - 2, superframe = n / 6, position = n % 6;
        if (position == 0) embedded[call.slot].setLC(embedded_lc(call, superframe));
        std::array<dmr_test::Frame9, 3> frames;
        for (auto& f : frames) {
          f = dmr_test::encode(dmr_test::track(voice_index++));
          sent[call.slot].push_back(f);
        }
        b = voice_burst(frames, position, embedded[call.slot]);
      } else if (rel == 2 + voice_bursts || rel == 3 + voice_bursts) {
        const CDMRLC lc(call.flco, call.src, call.dst);
        b = data_burst(DT_TERMINATOR_WITH_LC, &lc);
      } else {
        b = data_burst(DT_IDLE, nullptr);
      }
      append(dibits, call.slot, b);
    }
  }
  std::ofstream(dir + "/tx.dibits", std::ios::binary)
      .write(reinterpret_cast<const char*>(dibits.data()), static_cast<std::streamsize>(dibits.size()));
  for (int s = 0; s < 2; ++s) {
    std::ofstream out(dir + "/tx_ts" + std::to_string(s + 1) + ".ambe", std::ios::binary);
    for (const auto& f : sent[s]) out.write(reinterpret_cast<const char*>(f.data()), 9);
  }
  // Values exactly as digiham formats them (to_string of the float result).
  const float lat = 180.0f / static_cast<float>(1 << 24) * static_cast<float>(kLatBits);
  const float lon = -(360.0f / static_cast<float>(1 << 25) * static_cast<float>(kLonBits));
  std::ofstream truth(dir + "/truth.txt");
  truth << "M 0 voice group 2345678 91 - - -\n"
        << "M 0 voice group 2345678 91 " << kAlias << " - -\n"
        << "M 0 voice group 2345678 91 " << kAlias << ' ' << std::to_string(lat) << ' '
        << std::to_string(lon) << "\n"
        << "M 1 voice direct 1234567 7654321 - - -\n";
  std::printf("tx: %zu dibits (%.2f s), %zu+%zu AMBE frames\n", dibits.size(),
              dibits.size() / 4800.0, sent[0].size(), sent[1].size());
  return 0;
}

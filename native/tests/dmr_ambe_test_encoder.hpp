// SPDX-License-Identifier: GPL-3.0-or-later
// Test-only AMBE+2 (3600x2450) CHANNEL encoder for synthetic DMR voice frames.
//
// There is no open AMBE+2 speech encoder. This builds valid channel frames
// from chosen 49-bit parameter vectors (pitch b0, V/UV b1, gain b2, PRBA
// b3/b4, HOC b5..b8) by inverting exactly what mbelib 1.3.0 decodes:
//   ambe_d -> C0 Golay(23,12)+parity, C1 Golay(23,12) XOR the C0-seeded PRNG,
//   C2/C3 uncoded -> ambe_fr[4][24] -> 72-bit deinterleaved packet
//   -> inverse of codecserver-softmbe dmr_interleave_permutation
//   -> 9 bytes MSB-first (digiham DmrDecoder's emitted layout).
// Sources: mbelib ambe3600x2450.c mbe_eccAmbe3600x2450C0/Data and
// mbe_demodulateAmbe3600x2450Data, ecc.c mbe_golay2312, ecc_const.h
// golayGenerator; softmbesession.cpp decode_ambe_3600x2450.
// The audio from such frames is vocoder buzz/noise, not speech.
#pragma once

#include <array>
#include <cstdint>

#include <softmbe/interleaver_permutations_const.hpp>

namespace dmr_test {

using AmbeD = std::array<uint8_t, 49>;
using Frame9 = std::array<uint8_t, 9>;

// mbelib ecc_const.h golayGenerator[12] (Golay 23,12 check bits per data bit,
// data bit i = block bit 22-i).
constexpr int kGolayGenerator[12] = {0x63a, 0x31d, 0x7b4, 0x3da, 0x1ed, 0x6cc,
                                     0x366, 0x1b3, 0x6e3, 0x54b, 0x49f, 0x475};

// 12 data bits (data[0] = MSB, block bit 22) -> 23-bit codeword as in[0..22]
// with in[k] = block bit k (the order mbe_golay2312 reads).
inline void golay2312_encode(const uint8_t data[12], uint8_t in[23]) {
  int ecc = 0;
  long block = 0;
  for (int i = 0; i < 12; ++i) {
    block = (block << 1) | data[i];
    if (data[i]) ecc ^= kGolayGenerator[i];
  }
  block = (block << 11) | ecc;
  for (int k = 0; k < 23; ++k) in[k] = static_cast<uint8_t>((block >> k) & 1);
}

// Build b0..b8 into ambe_d per mbe_decodeAmbe2450Parms' bit map.
struct Params {
  int b0 = 40, b1 = 0, b2 = 16, b3 = 0, b4 = 0, b5 = 0, b6 = 0, b7 = 0, b8 = 0;
};
inline AmbeD params_to_ambe_d(const Params& p) {
  AmbeD d{};
  auto put = [&d](int value, std::initializer_list<int> positions) {
    int shift = static_cast<int>(positions.size()) - 1;
    for (int pos : positions) d[pos] = static_cast<uint8_t>((value >> shift--) & 1);
  };
  put(p.b0, {0, 1, 2, 3, 37, 38, 39});
  put(p.b1, {4, 5, 6, 7, 35});
  put(p.b2, {8, 9, 10, 11, 36});
  put(p.b3, {12, 13, 14, 15, 16, 17, 18, 19, 40});
  put(p.b4, {20, 21, 22, 23, 41, 42, 43});
  put(p.b5, {24, 25, 26, 27, 44});
  put(p.b6, {28, 29, 30, 31, 45});
  put(p.b7, {32, 33, 34, 46});
  put(p.b8, {47, 48});
  return d;
}

// Inverse of mbe_eccAmbe3600x2450Data/C0 + mbe_demodulateAmbe3600x2450Data.
inline void ambe_d_to_fr(const AmbeD& d, uint8_t fr[4][24]) {
  for (int c = 0; c < 4; ++c)
    for (int j = 0; j < 24; ++j) fr[c][j] = 0;
  uint8_t data[12], in[23];
  for (int i = 0; i < 12; ++i) data[i] = d[i];
  golay2312_encode(data, in);
  int parity = 0;
  for (int j = 0; j < 23; ++j) {
    fr[0][j + 1] = in[j];
    parity ^= in[j];
  }
  fr[0][0] = static_cast<uint8_t>(parity);  // C0 Golay24 parity (mbelib ignores it)
  for (int i = 0; i < 12; ++i) data[i] = d[12 + i];
  golay2312_encode(data, in);
  // PRNG seeded from C0 data bits fr[0][23..12] (= d[0..11]).
  unsigned short pr[24];
  unsigned short foo = 0;
  for (int i = 23; i >= 12; --i) foo = static_cast<unsigned short>((foo << 1) | fr[0][i]);
  pr[0] = static_cast<unsigned short>(16 * foo);
  for (int i = 1; i < 24; ++i)
    pr[i] = static_cast<unsigned short>((173 * pr[i - 1]) + 13849 -
                                        (65536 * (((173 * pr[i - 1]) + 13849) / 65536)));
  for (int i = 1; i < 24; ++i) pr[i] = static_cast<unsigned short>(pr[i] / 32768);
  int k = 1;
  for (int j = 22; j >= 0; --j) fr[1][j] = static_cast<uint8_t>(in[j] ^ pr[k++]);
  for (int i = 0; i < 11; ++i) fr[2][10 - i] = d[24 + i];
  for (int i = 0; i < 14; ++i) fr[3][13 - i] = d[35 + i];
}

inline Frame9 fr_to_frame(const uint8_t fr[4][24]) {
  uint8_t deint[72];
  for (int i = 0; i < 24; ++i) deint[i] = fr[0][i];
  for (int i = 0; i < 23; ++i) deint[24 + i] = fr[1][i];
  for (int i = 0; i < 11; ++i) deint[47 + i] = fr[2][i];
  for (int i = 0; i < 14; ++i) deint[58 + i] = fr[3][i];
  uint8_t inter[72] = {};
  for (int i = 0; i < 72; ++i) inter[dmr_interleave_permutation[i]] = deint[i];
  Frame9 out{};
  for (int i = 0; i < 72; ++i) out[i / 8] |= static_cast<uint8_t>(inter[i] << (7 - i % 8));
  return out;
}

inline Frame9 encode(const Params& p) {
  uint8_t fr[4][24];
  ambe_d_to_fr(params_to_ambe_d(p), fr);
  return fr_to_frame(fr);
}

// Interleaved bit position (0..71) of deinterleaved packet bit `deint_index`
// (0..23 = C0, 24..46 = C1, 47..57 = C2, 58..71 = C3), for error injection.
inline int interleaved_position(int deint_index) { return dmr_interleave_permutation[deint_index]; }
inline void flip(Frame9& f, int interleaved_bit) {
  f[interleaved_bit / 8] ^= static_cast<uint8_t>(1u << (7 - interleaved_bit % 8));
}

// Deterministic, speech-like varying parameter track (not speech).
inline Params track(int n) {
  Params p;
  p.b0 = 20 + (n * 7) % 80;          // pitch index inside the valid 0..119
  p.b1 = (n / 3) % 32;               // V/UV pattern
  p.b2 = 10 + (n * 5) % 20;          // gain delta
  p.b3 = (n * 37) % 512;
  p.b4 = (n * 11) % 128;
  p.b5 = (n * 3) % 32;
  p.b6 = (n * 13) % 32;
  p.b7 = (n * 5) % 16;
  p.b8 = n % 4;
  return p;
}

}  // namespace dmr_test

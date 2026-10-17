// SPDX-License-Identifier: GPL-3.0-or-later
//
// NFM de-emphasis FIR coefficients for a 24,000 S/s audio tap, copied
// verbatim from csdr-plus (https://github.com/csdobre/csdr-plus) commit
// f26b52071c4a127fc8193d058c249cac57585de4, src/lib/predefined.h,
// array `deemphasis_nfm_predefined_fir_24000` (comment there:
// "mkdeemph(24000,199,500)" -- designed with Octave's `firls`, 199 taps,
// normalized to 0 dB at 500 Hz; see that file's generator script).
// csdr-plus describes this filter as having 199 taps in its own comment
// and switch-case (deemphasis.cpp), but the literal initializer in
// predefined.h actually holds 201 floats; both counts are reported below
// for anyone diffing against upstream. This header reproduces the array
// exactly as written upstream, including its actual element count.
//
// Upstream copyright/license notice, preserved verbatim (BSD-3-Clause-style,
// from predefined.h lines 1-31):
//
// This software is part of libcsdr, a set of simple DSP routines for
// Software Defined Radio.
//
// Copyright (c) 2014, Andras Retzler <randras@sdr.hu>
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the copyright holder nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL ANDRAS RETZLER BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#ifndef SDRCORE_DSP_CSDR_NFM_DEEMPHASIS_24000_H
#define SDRCORE_DSP_CSDR_NFM_DEEMPHASIS_24000_H

namespace sdrcore {
namespace dsp {

// Element count of deemphasis_nfm_predefined_fir_24000 as literally written
// in csdr-plus's predefined.h (201), not the 199 named in that project's own
// comment/switch-case (deemphasis.cpp's NfmDeephasis::getFilter() passes a
// literal 199 to FirFilter, one short of the array's true size -- an
// upstream off-by-two that we do not reproduce: we use the full table).
inline constexpr int kCsdrNfmDeemphasis24000Taps = 201;

inline constexpr float kCsdrNfmDeemphasis24000Fir[kCsdrNfmDeemphasis24000Taps] = {
    -0.000889951f, -0.000698861f, -0.00107321f, -0.00176281f, -0.00222791f, -0.00210541f, -0.00153f, -0.0010253f,
    -0.00105133f, -0.0015979f, -0.0021819f, -0.00225993f, -0.00170334f, -0.00091998f, -0.000507512f, -0.000731928f,
    -0.00128529f, -0.00154232f, -0.00110241f, -0.00014769f, 0.000702325f, 0.000924361f, 0.000553814f, 0.000167338f,
    0.000388289f, 0.00133759f, 0.00251198f, 0.00320854f, 0.00313678f, 0.00268434f, 0.00259233f, 0.0033093f,
    0.00458394f, 0.00566291f, 0.00593754f, 0.00548284f, 0.00500954f, 0.0052529f, 0.00631985f, 0.00756987f,
    0.00815281f, 0.00775064f, 0.00687412f, 0.00643636f, 0.00695449f, 0.00807289f, 0.00884221f, 0.00853598f,
    0.00730153f, 0.0060614f, 0.00572225f, 0.00636501f, 0.00713516f, 0.00696093f, 0.00549744f, 0.00346664f,
    0.00206222f, 0.00190518f, 0.00245981f, 0.00245429f, 0.000982237f, -0.0016636f, -0.00418614f, -0.00539053f,
    -0.00526323f, -0.00505351f, -0.00622261f, -0.00913351f, -0.0126443f, -0.0150336f, -0.0155167f, -0.0150251f,
    -0.0154871f, -0.0181413f, -0.022337f, -0.025954f, -0.0272085f, -0.0263264f, -0.0255364f, -0.027212f,
    -0.0316631f, -0.0365759f, -0.0388275f, -0.0373129f, -0.0342968f, -0.033795f, -0.0380034f, -0.044771f,
    -0.0487059f, -0.0456547f, -0.037125f, -0.0304537f, -0.0332925f, -0.045605f, -0.0553367f, -0.0424946f,
    0.00909836f, 0.0990565f, 0.205387f, 0.291918f, 0.325263f, 0.291918f, 0.205387f, 0.0990565f,
    0.00909836f, -0.0424946f, -0.0553367f, -0.045605f, -0.0332925f, -0.0304537f, -0.037125f, -0.0456547f,
    -0.0487059f, -0.044771f, -0.0380034f, -0.033795f, -0.0342968f, -0.0373129f, -0.0388275f, -0.0365759f,
    -0.0316631f, -0.027212f, -0.0255364f, -0.0263264f, -0.0272085f, -0.025954f, -0.022337f, -0.0181413f,
    -0.0154871f, -0.0150251f, -0.0155167f, -0.0150336f, -0.0126443f, -0.00913351f, -0.00622261f, -0.00505351f,
    -0.00526323f, -0.00539053f, -0.00418614f, -0.0016636f, 0.000982237f, 0.00245429f, 0.00245981f, 0.00190518f,
    0.00206222f, 0.00346664f, 0.00549744f, 0.00696093f, 0.00713516f, 0.00636501f, 0.00572225f, 0.0060614f,
    0.00730153f, 0.00853598f, 0.00884221f, 0.00807289f, 0.00695449f, 0.00643636f, 0.00687412f, 0.00775064f,
    0.00815281f, 0.00756987f, 0.00631985f, 0.0052529f, 0.00500954f, 0.00548284f, 0.00593754f, 0.00566291f,
    0.00458394f, 0.0033093f, 0.00259233f, 0.00268434f, 0.00313678f, 0.00320854f, 0.00251198f, 0.00133759f,
    0.000388289f, 0.000167338f, 0.000553814f, 0.000924361f, 0.000702325f, -0.00014769f, -0.00110241f, -0.00154232f,
    -0.00128529f, -0.000731928f, -0.000507512f, -0.00091998f, -0.00170334f, -0.00225993f, -0.0021819f, -0.0015979f,
    -0.00105133f, -0.0010253f, -0.00153f, -0.00210541f, -0.00222791f, -0.00176281f, -0.00107321f, -0.000698861f,
    -0.000889951f};

}  // namespace dsp
}  // namespace sdrcore
#endif  // SDRCORE_DSP_CSDR_NFM_DEEMPHASIS_24000_H

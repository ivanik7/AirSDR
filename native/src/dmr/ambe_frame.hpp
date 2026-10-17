// SPDX-License-Identifier: GPL-3.0-or-later
// Shared DMR voice frame type: produced by the digiham framing adapter
// (framing.hpp, t_0c6cc09e) and consumed by the AMBE+2 voice output
// (vocoder.hpp, t_5b101746). docs/status/dmr.md §7.3.
#pragma once

#include <cstdint>

namespace sdrcore::dmr {

// One 72-bit AMBE+2 (3600x2450) channel frame, still DMR-interleaved,
// MSB-first, exactly as digiham's DmrDecoder emits it (its 27-byte voice
// burst split into three consecutive 9-byte frames).
struct AmbeFrame {
  uint8_t slot = 0;  // 0 = TS1, 1 = TS2 (informational; upstream ignores it)
  uint8_t bits[9] = {};
};

}  // namespace sdrcore::dmr

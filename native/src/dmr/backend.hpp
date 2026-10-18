// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "decoder.hpp"
#include <memory>

namespace sdrcore::decoder {
// The sole receiver's tuned baseband tap feeds the OpenWebRX+ DMR chain.
std::unique_ptr<Decoder> create_dmr();
}

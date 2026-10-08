// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone white-box ABI-2 tests include sdrcore.cpp without the production
// decoder registry. They never select a data decoder; keep linkage isolated.
#include "decoder.hpp"

namespace sdrcore::decoder {
const std::vector<Registration>& registry() {
  static const std::vector<Registration> empty;
  return empty;
}
} // namespace sdrcore::decoder

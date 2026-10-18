// SPDX-License-Identifier: GPL-3.0-or-later
#include "lorarx_session.hpp"
#include "lorarx_embed.h"

namespace sdrcore::decoder::lorarx_session {
std::mutex mutex;
void* owner = nullptr;
Sink sink = nullptr;
}

extern "C" void lorarx_embed_emit(const char* json, size_t length) {
  // Invoked synchronously inside block() while the owner holds mutex.
  if (sdrcore::decoder::lorarx_session::owner &&
      sdrcore::decoder::lorarx_session::sink)
    sdrcore::decoder::lorarx_session::sink(
        sdrcore::decoder::lorarx_session::owner, json, length);
}

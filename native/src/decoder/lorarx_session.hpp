// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstddef>
#include <mutex>

namespace sdrcore::decoder::lorarx_session {
// The upstream lorarx demodulator has process-global state. Both data modes
// share one owner and callback, guarded around all start/block/clear calls.
using Sink = void (*)(void*, const char*, size_t);
extern std::mutex mutex;
extern void* owner;
extern Sink sink;
}  // namespace sdrcore::decoder::lorarx_session

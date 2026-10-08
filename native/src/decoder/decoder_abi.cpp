// SPDX-License-Identifier: GPL-3.0-or-later
// Public registry metadata; per-handle selection and polling live beside
// SdrHandle in sdrcore.cpp so DSP, event FIFO and lifecycle share its locks.
#include "sdrcore_decoder_v1.h"
#include "decoder.hpp"
#include <cstring>

extern "C" uint32_t sdr_decoder_version(void) { return SDR_DECODER_REVISION; }

extern "C" int32_t sdr_decoder_count(uint32_t* count) {
  if (!count) return SDR_INVALID_ARGUMENT;
  *count = static_cast<uint32_t>(sdrcore::decoder::registry().size());
  return SDR_OK;
}

extern "C" int32_t sdr_decoder_descriptor(uint32_t index,
                                           SdrDecoderDescriptor* descriptor) {
  if (!descriptor || descriptor->size != sizeof(SdrDecoderDescriptor) ||
      descriptor->revision != SDR_DECODER_REVISION)
    return SDR_INVALID_ARGUMENT;
  const auto& entries = sdrcore::decoder::registry();
  if (index >= entries.size()) return SDR_INVALID_ARGUMENT;
  const auto& reg = entries[index];
  SdrDecoderDescriptor out{};
  out.size = sizeof(out);
  out.revision = SDR_DECODER_REVISION;
  std::strncpy(out.id, reg.descriptor.id, sizeof(out.id) - 1);
  out.id[sizeof(out.id) - 1] = '\0';
  out.input = static_cast<uint32_t>(reg.descriptor.input);
  out.exclusive_receiver = reg.descriptor.exclusive_receiver ? 1u : 0u;
  out.required_mode = reg.descriptor.required_mode;
  out.required_rate_hz = reg.descriptor.required_rate_hz;
  out.result = static_cast<uint32_t>(reg.descriptor.result);
  out.available = reg.create ? 1u : 0u;
  *descriptor = out;
  return SDR_OK;
}

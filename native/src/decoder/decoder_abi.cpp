// SPDX-License-Identifier: GPL-3.0-or-later
// Additive decoder extension ABI (native/include/sdrcore_decoder_v1.h).
//
// This file implements NO decoding engine. Every registry entry
// (native/src/decoder/registry.cpp) carries a null factory, so
// sdr_decoder_select() can never attach a real backend today; every
// selection of a cataloged-but-unavailable id (sstv/rtl_433/adsb) or an
// unknown id fails with SDR_UNSUPPORTED and leaves the v3 receiver, audio
// and tuning untouched. sdr_decoder_poll() can therefore never observe a
// real event and always reports SDR_DECODER_NO_DATA.
//
// Deliberately stateless: this translation unit holds no per-handle decoder
// state and never reaches into SdrHandle's internals (defined privately in
// sdrcore.cpp), so it cannot race or corrupt the v3 receiver it shares a
// handle with. State is only queried through the existing public
// sdr_v3_snapshot() call, serialized by the caller like every other v3
// command on the handle.
//
// Forward design note for when a real backend lands (still not implemented
// here): decoder.hpp documents "at most one decoder instance is attached to
// the sole v3 handle" and "the owner bounds payload to 64 KiB, keeps only
// its newest event". That means the eventual attachment point is a single
// optional `std::unique_ptr<sdrcore::decoder::Decoder>` slot plus one
// pending `Event` living inside SdrHandle itself (guarded by its existing
// `mutex`/`dsp_mutex`, the same lock order already used by
// sdr_v3_set_controls/set_display/set_wfm_stereo), not a side table keyed by
// pointer identity in this file: a pointer-identity side table would risk
// aliasing a destroyed handle's leftover state onto a reused SdrHandle*
// address once decoders stop being universally unavailable. Exclusive
// backends must additionally check the v3 snapshot's state before
// attaching: selecting an exclusive id while SDR_RUNNING must fail (the
// caller has to stop ordinary listening first), never silently stop it.
#include "sdrcore_decoder_v1.h"

#include "decoder.hpp"

#include <cstring>
#include <string>

namespace {

bool snapshot_listenable(SdrHandle* handle, bool* ok) {
  SdrV3Snapshot snap{};
  snap.size = sizeof snap;
  snap.revision = SDR_V3_REVISION;
  if (sdr_v3_snapshot(handle, &snap) != SDR_OK) {
    *ok = false;
    return false;
  }
  *ok = true;
  return snap.state == SDR_OPEN || snap.state == SDR_RUNNING;
}

}  // namespace

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
  out.available = reg.create ? 1u : 0u;  // Null factory => unavailable today.
  *descriptor = out;
  return SDR_OK;
}

extern "C" int32_t sdr_decoder_select(SdrHandle* handle, const char* id,
                                       uint32_t id_bytes, const char* config,
                                       uint32_t config_bytes) {
  if (!handle) return SDR_INVALID_ARGUMENT;
  if ((id_bytes && !id) || (config_bytes && !config))
    return SDR_INVALID_ARGUMENT;
  bool snapshot_ok = false;
  const bool listenable = snapshot_listenable(handle, &snapshot_ok);
  if (!snapshot_ok) return SDR_INTERNAL_ERROR;
  // Commands are serialized by the caller with v3 start/stop/controls on
  // this handle, like every other v3 command; selection only makes sense
  // once the handle has a configured session to attach to or detach from.
  if (!listenable) return SDR_INVALID_STATE;
  // NULL/empty ID deselects. With no decoder ever attached (stateless; see
  // file header), this is always a safe no-op.
  if (!id || id_bytes == 0) return SDR_OK;
  const std::string requested(id, id_bytes);
  for (const auto& reg : sdrcore::decoder::registry()) {
    if (requested != reg.descriptor.id) continue;
    // A real factory would attach here (see the design note above). Every
    // shipped entry today has create == nullptr, so a cataloged id is
    // rejected exactly like an unknown one: SDR_UNSUPPORTED either way.
    if (!reg.create) return SDR_UNSUPPORTED;
    break;  // Unreachable until a real factory ships.
  }
  return SDR_UNSUPPORTED;  // Unknown id, or cataloged-but-unavailable above.
}

extern "C" int32_t sdr_decoder_poll(SdrHandle* handle, uint64_t after_sequence,
                                     SdrDecoderEvent* event, uint8_t* payload,
                                     uint32_t capacity) {
  (void)after_sequence;
  if (!handle || !event || event->size != sizeof(SdrDecoderEvent) ||
      event->revision != SDR_DECODER_REVISION)
    return SDR_INVALID_ARGUMENT;
  if (capacity && !payload) return SDR_INVALID_ARGUMENT;
  // No decoder instance can ever be attached today (every registry entry's
  // factory is null), so no event can ever exist; outputs are left
  // completely unchanged, matching the header's NO_DATA contract.
  return SDR_DECODER_NO_DATA;
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Static decoder registry (native/include/decoder.hpp). This file declares
// WHAT decoder backends exist and their contract metadata; it implements NO
// decoding. Every entry below has a null `create` factory, matching
// decoder.hpp's "a null factory denotes an inspectable but unavailable
// registry entry" rule: no SSTV, rtl_433 or ADS-B engine ships yet. Voice
// demodulation (v3 mode/WFM stereo) is intentionally absent from this list;
// it is not a data decoder instance (see decoder.hpp's header comment and
// lib/ui/decoders/decoder_contract.dart's `voice` catalog entry, which is
// marked `voice: true` and has no native registry counterpart).
#include "decoder.hpp"

namespace sdrcore::decoder {

const std::vector<Registration>& registry() {
  // Metadata mirrors the Dart preview catalog
  // (lib/ui/decoders/decoder_contract.dart `decoderCatalog`) so the two
  // layers describe the same conceptual decoders, even though neither this
  // native registry nor the Dart catalog claims a working backend today.
  static const std::vector<Registration> kRegistry = {
      Registration{
          Descriptor{
              /*id=*/"sstv",
              /*input=*/Input::audio,
              /*exclusive_receiver=*/false,
              /*required_mode=*/4,  // SDR_V3_USB, matches the Dart catalog.
              /*required_rate_hz=*/24000,
              /*result=*/Result::image_complete,
          },
          /*create=*/nullptr,
      },
      Registration{
          Descriptor{
              /*id=*/"rtl_433",
              /*input=*/Input::baseband,
              /*exclusive_receiver=*/false,  // Shares the tuned VFO.
              /*required_mode=*/0xFFFFFFFFu,  // Independent of demod mode.
              /*required_rate_hz=*/0,  // Negotiated integer decimation.
              /*result=*/Result::message,
          },
          /*create=*/nullptr,
      },
      Registration{
          Descriptor{
              /*id=*/"adsb",
              /*input=*/Input::raw_iq,
              /*exclusive_receiver=*/true,  // Wideband capture displaces listening.
              /*required_mode=*/0xFFFFFFFFu,  // Independent of demod mode.
              /*required_rate_hz=*/2400000,
              /*result=*/Result::aircraft,
          },
          /*create=*/nullptr,
      },
  };
  return kRegistry;
}

}  // namespace sdrcore::decoder

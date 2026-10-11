// SPDX-License-Identifier: GPL-3.0-or-later
// Static data-decoder registry. rtl_433 is embedded in-process; SSTV and
// ADS-B remain unavailable. Voice demodulators belong to v3, not this list.
#include "decoder.hpp"

namespace sdrcore::decoder {
std::unique_ptr<Decoder> create_rtl433();

const std::vector<Registration>& registry() {
  // Metadata mirrors the Dart decoder catalog.
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
          /*create=*/create_rtl433,
      },
      Registration{
          Descriptor{
              /*id=*/"adsb",
              /*input=*/Input::raw_iq,
              /*exclusive_receiver=*/false,  // Tuned IQ tap; no tuner handoff.
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

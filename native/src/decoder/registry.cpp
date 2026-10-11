// SPDX-License-Identifier: GPL-3.0-or-later
// Static data-decoder registry. rtl_433 and SSTV (csdr-plus SstvDecoder) are
// embedded in-process, alongside dump1090 ADS-B. Voice demodulators belong
// to v3, not this list.
#include "decoder.hpp"

namespace sdrcore::decoder {
std::unique_ptr<Decoder> create_rtl433();
std::unique_ptr<Decoder> create_sstv();
std::unique_ptr<Decoder> create_adsb();

const std::vector<Registration>& registry() {
  // Metadata mirrors the Dart decoder catalog.
  static const std::vector<Registration> kRegistry = {
      Registration{
          Descriptor{
              /*id=*/"sstv",
              /*input=*/Input::audio,
              /*exclusive_receiver=*/false,
              // USB, LSB or NFM: enforced by Decoder::accepts_mode() at
              // selection and by the receiver tap, not by one fixed mode.
              /*required_mode=*/0xFFFFFFFFu,
              /*required_rate_hz=*/24000,
              /*result=*/Result::image_complete,
          },
          /*create=*/create_sstv,
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
          /*create=*/create_adsb,
      },
  };
  return kRegistry;
}

}  // namespace sdrcore::decoder

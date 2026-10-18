// SPDX-License-Identifier: GPL-3.0-or-later
// Static decoder registry. DMR voice uses the tuned baseband tap;
// analog voice demodulators remain in v3.
#include "decoder.hpp"

namespace sdrcore::decoder {
std::unique_ptr<Decoder> create_rtl433();
std::unique_ptr<Decoder> create_sstv();
std::unique_ptr<Decoder> create_adsb();
std::unique_ptr<Decoder> create_meshtastic();
std::unique_ptr<Decoder> create_dmr();

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
      Registration{
          Descriptor{
              /*id=*/"meshtastic",
              /*input=*/Input::baseband,
              /*exclusive_receiver=*/false,
              /*required_mode=*/0xFFFFFFFFu,
              /*required_rate_hz=*/1000000,
              /*result=*/Result::message,
          },
          /*create=*/create_meshtastic,
      },
      Registration{
          Descriptor{"dmr", Input::baseband, false, 0xFFFFFFFFu, 0,
                     Result::message},
          create_dmr,
      },
  };
  return kRegistry;
}

}  // namespace sdrcore::decoder

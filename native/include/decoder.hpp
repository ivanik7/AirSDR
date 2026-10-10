// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace sdrcore::decoder {

// Registry metadata mirrors the versioned C extension. Voice demodulators
// are NOT data decoder instances: v3 mode/WFM stereo continue unchanged.
enum class Input : uint32_t { audio = 1, mpx = 2, baseband = 3, raw_iq = 4 };
enum class Result : uint32_t {
  message = 1, image_progress = 2, image_complete = 3, aircraft = 4
};
struct Descriptor {
  const char* id;  // stable ASCII; max 31 bytes
  Input input;
  bool exclusive_receiver;
  uint32_t required_mode;  // UINT32_MAX = independent of demod mode
  uint32_t required_rate_hz; // 0 = backend-dependent
  Result result;
};
struct Event {
  Result kind;
  std::vector<uint8_t> payload; // UTF-8 JSON or bounded image segment
};

// Called solely by the native DSP worker, never the Dart/UI thread. All sample
// spans are borrowed and valid only for process(); float audio/MPX is mono,
// complex baseband/raw IQ is interleaved float I,Q. Rates are samples/sec
// (complex pairs/sec for IQ). process() must not retain a sample pointer,
// block on UI delivery or emit more than the bounded queue can hold.
class Decoder {
 public:
  virtual ~Decoder() = default;
  virtual bool configure(std::string_view versioned_json) = 0;
  virtual void reset() = 0; // stream start/retune/stop discontinuity
  virtual void process(const float* samples, size_t frames,
                       uint32_t sample_rate_hz) = 0;
  // A backend may yield a low-rate result. The owner bounds payload to 64 KiB,
  // queues up to 256 events FIFO, and stamps sequence/stream generation under
  // the handle lock before the C poll copies it. No direct Dart callbacks.
  virtual bool take_event(Event& out) = 0;
  // Backends with an internal bounded staging queue report drops so they are
  // included in the same per-handle counter as the public FIFO's drops.
  virtual uint64_t take_dropped_count() { return 0; }
  // Input::audio backends only. The receiver feeds the audio tap only while
  // accepts_mode(current SdrV3Mode) is true; sdr_decoder_select rejects a
  // backend that does not accept the currently applied mode (SDR_UNSUPPORTED)
  // and leaves the previous decoder untouched. Default: any mode.
  virtual bool accepts_mode(uint32_t /*sdr_v3_mode*/) const { return true; }
  // Input::audio backends only. Applied tuned frequency (center_frequency_hz
  // + vfo_offset_hz) and SdrV3Mode. The receiver calls this immediately
  // before EVERY reset() it issues (attach, tuned-frequency/LO change, mode
  // change, sample-rate change, stream reset/retune), so the backend can
  // stamp frame metadata and name the reset: tuned frequency changed ->
  // "retune", mode changed -> "mode", otherwise "stop".
  virtual void set_tuning(uint64_t /*tuned_frequency_hz*/,
                          uint32_t /*sdr_v3_mode*/) {}
};

using Factory = std::unique_ptr<Decoder> (*)();
struct Registration { Descriptor descriptor; Factory create; };
// A null factory denotes an inspectable but unavailable registry entry.
// IDs never alias, and at most one decoder instance is attached to the sole
// v3 handle. Exclusive entries must stop ordinary listening before selection;
// no backend may claim a second tuner. Registry/factory implementation lives
// in native/src/decoder/ and must enforce these constraints.
const std::vector<Registration>& registry();

} // namespace sdrcore::decoder

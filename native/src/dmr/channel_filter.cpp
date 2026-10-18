// SPDX-License-Identifier: GPL-3.0-or-later
#include "channel_filter.hpp"
#include "dsp/fftw_planner.hpp"

#include <csdr/fftfilter.hpp>
#include <csdr/filter.hpp>
#include <csdr/firdecimate.hpp>
#include <csdr/fractionaldecimator.hpp>
#include <csdr/window.hpp>
#include <digiham/rrc_filter.hpp>

#include <algorithm>
#include <mutex>

namespace sdrcore::dmr {
namespace {
using Sample = Csdr::complex<float>;

// Growable single-producer/single-consumer buffer between two csdr modules.
// Modules run sequentially on the DSP worker; compaction happens only
// between pumps, when no module holds a read or write pointer. `write` is
// what the consumer may read; `filled` (>= write) holds staged input only.
struct Buffer {
  std::vector<Sample> data;
  size_t read = 0;
  size_t write = 0;
  size_t filled = 0;
  void compact() {
    if (read == 0) return;
    const size_t end = std::max(write, filled);
    std::move(data.begin() + read, data.begin() + end, data.begin());
    write -= read;
    if (filled) filled -= read;
    read = 0;
  }
};

class BufferReader final : public Csdr::Reader<Sample> {
 public:
  explicit BufferReader(Buffer& buffer) : buffer_(buffer) {}
  size_t available() override { return buffer_.write - buffer_.read; }
  Sample* getReadPointer() override { return buffer_.data.data() + buffer_.read; }
  void advance(size_t n) override { buffer_.read += n; }
  // Never blocks: the adapter pumps only while canProcess() is true.
  void wait() override {}
  void unblock() override {}

 private:
  Buffer& buffer_;
};

class BufferWriter final : public Csdr::Writer<Sample> {
 public:
  explicit BufferWriter(Buffer& buffer) : buffer_(buffer) {}
  size_t writeable() override {
    constexpr size_t kSpace = 1 << 14;
    if (buffer_.data.size() - buffer_.write < kSpace)
      buffer_.data.resize(buffer_.write + kSpace);
    return buffer_.data.size() - buffer_.write;
  }
  Sample* getWritePointer() override { return buffer_.data.data() + buffer_.write; }
  void advance(size_t n) override { buffer_.write += n; }

 private:
  Buffer& buffer_;
};

template <typename Module>
void pump(Module& module) {
  while (module.canProcess()) module.process();
}
}  // namespace

// OpenWebRX+ f1e0d1ac csdr/chain/selector.py, evaluated for one VFO-centred
// tap at the receiver's actual rate and the DMR fixed IF of 48 kS/s:
//   Decimator: FirDecimate(d, 0.15*out/in, 0.5*d/(in/out), Hamming), then
//              FractionalDecimator(12 Lagrange points, no prefilter) when
//              (in/d)/out != 1, where d = floor(in/out)
//   Bandpass:  FftBandPassFilter(-6250/out, 6250/out, 320/out, Hamming)
//   Squelch:   omitted; DMR forces level -150 dB (always open).
// The initial Shift(-offset/in) is the receiver's own VFO shift: the tap is
// already centred on the tuned frequency. All DSP is the vendored csdr-plus
// f26b520 code; this adapter only moves samples between the modules the way
// pycsdr buffers would.
//
// csdr's FractionalDecimator keeps its read position in a float that is
// renormalised once per process() call, so its output depends on how much
// input each call sees. To be deterministic regardless of the caller's
// chunking, input is released to the chain in fixed blocks of
// kBlockOutputSamples worth of 48 kS/s IF, and every module is pumped
// after each block.
struct ChannelFilter::Impl {
  explicit Impl(uint32_t rate) : input_rate(rate) {
    const double in = rate;
    const double out = kOutputRate;
    const auto decimation = static_cast<unsigned>(in / out);
    block = static_cast<size_t>(decimation) * kBlockOutputSamples;
    const double fraction = in / decimation / out;
    decimator = std::make_unique<Csdr::FirDecimate>(
        decimation, static_cast<float>(0.15 * (out / in)), &window,
        static_cast<float>(0.5 * decimation / (in / out)));
    decimator->setReader(&input_reader);
    decimator->setWriter(&decimated_writer);
    Csdr::Reader<Sample>* bandpass_input = &decimated_reader;
    if (fraction != 1.0) {
      fractional = std::make_unique<Csdr::FractionalDecimator<Sample>>(
          static_cast<float>(fraction), 12);
      fractional->setReader(&decimated_reader);
      fractional->setWriter(&resampled_writer);
      bandpass_input = &resampled_reader;
    }
    std::lock_guard<std::mutex> lock(fftw_planner_mutex());
    bandpass = std::make_unique<Csdr::FilterModule<Sample>>(
        new Csdr::FftBandPassFilter(static_cast<float>(kLowCutHz / out),
                                    static_cast<float>(kHighCutHz / out),
                                    static_cast<float>(320.0 / out), &window));
    bandpass->setReader(bandpass_input);
    bandpass->setWriter(&output_writer);
  }

  ~Impl() {
    std::lock_guard<std::mutex> lock(fftw_planner_mutex());
    bandpass.reset();
  }

  void process(const std::complex<float>* iq, size_t n,
               std::vector<std::complex<float>>& output) {
    input.data.resize(input.filled);
    input.data.insert(input.data.end(), iq, iq + n);
    input.filled += n;
    while (input.filled - input.write >= block) {
      input.write += block;
      pump(*decimator);
      if (fractional) pump(*fractional);
      pump(*bandpass);
    }
    output.insert(output.end(), output_buffer.data.begin() + output_buffer.read,
                  output_buffer.data.begin() + output_buffer.write);
    if_count += output_buffer.write - output_buffer.read;
    output_buffer.read = output_buffer.write;
    // Keep each buffer bounded by its consumer's look-ahead.
    for (Buffer* buffer : {&input, &decimated, &resampled, &output_buffer})
      buffer->compact();
  }

  uint32_t input_rate;
  size_t block = 0;
  uint64_t if_count = 0;
  Csdr::HammingWindow window;
  Buffer input, decimated, resampled, output_buffer;
  BufferReader input_reader{input};
  BufferReader decimated_reader{decimated};
  BufferReader resampled_reader{resampled};
  BufferWriter decimated_writer{decimated};
  BufferWriter resampled_writer{resampled};
  BufferWriter output_writer{output_buffer};
  // Declared after the buffers they reference, so destroyed before them.
  std::unique_ptr<Csdr::FirDecimate> decimator;
  std::unique_ptr<Csdr::FractionalDecimator<Sample>> fractional;
  std::unique_ptr<Csdr::FilterModule<Sample>> bandpass;
};

ChannelFilter::ChannelFilter() = default;
ChannelFilter::~ChannelFilter() = default;
bool ChannelFilter::configure(uint32_t rate) {
  if (rate < kMinInputRate || rate > kMaxInputRate) return false;
  impl_.reset();
  impl_ = std::make_unique<Impl>(rate);
  return true;
}
uint32_t ChannelFilter::input_rate() const { return impl_ ? impl_->input_rate : 0; }
void ChannelFilter::reset() {
  if (!impl_) return;
  const auto rate = impl_->input_rate;
  impl_.reset();
  impl_ = std::make_unique<Impl>(rate);
}
void ChannelFilter::process(const std::complex<float>* iq, size_t n,
                            std::vector<std::complex<float>>& output) {
  if (!impl_ || !iq || !n) return;
  impl_->process(iq, n, output);
}
uint64_t ChannelFilter::output_samples() const { return impl_ ? impl_->if_count : 0; }

struct RrcPulseFilter::Impl {
  explicit Impl(Preset selected) : preset(selected) {
    if (preset == Preset::wide)
      filter = std::make_unique<Digiham::RrcFilter::WideRrcFilter>();
    else
      filter = std::make_unique<Digiham::RrcFilter::NarrowRrcFilter>();
  }
  Preset preset;
  std::unique_ptr<Digiham::RrcFilter::RrcFilter> filter;
  std::vector<float> input;
};

RrcPulseFilter::RrcPulseFilter(Preset preset) : impl_(std::make_unique<Impl>(preset)) {}
RrcPulseFilter::~RrcPulseFilter() = default;
void RrcPulseFilter::reset() { impl_ = std::make_unique<Impl>(impl_->preset); }
void RrcPulseFilter::process(const float* samples, float* output, size_t n) {
  if (!samples || !output || !n) return;
  // Digiham's process signature takes mutable input although it only reads it.
  impl_->input.assign(samples, samples + n);
  impl_->filter->process(impl_->input.data(), output, n);
}
RrcPulseFilter::Preset RrcPulseFilter::preset() const { return impl_->preset; }
}  // namespace sdrcore::dmr

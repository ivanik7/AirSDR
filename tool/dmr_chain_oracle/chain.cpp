// SPDX-License-Identifier: GPL-3.0-or-later
// DMR receive-chain harness. Same source, two builds:
//   -DDMR_PRISTINE: OpenWebRX+ (f1e0d1ac) DMR chain from PRISTINE upstream
//     modules: pycsdr Selector (ShiftAddfast(0) -> FirDecimate ->
//     [FractionalDecimator] -> FftBandPassFilter(+-6250 Hz) -> Squelch at
//     -150 dB) from csdr-plus f26b520's libcsdr++, then DigihamChain
//     (FmDemod -> DcBlock -> WideRrcFilter -> GfskDemodulator(10) ->
//     DmrDecoder) from digiham-plus beec7822 (ICU charset, unshimmed).
//   otherwise: this app's sdrcore::dmr::Channel + sdrcore::dmr::Framing.
//
//   harness iq RATE OUT_PREFIX  < cf32 IQ at RATE (VFO-centred tap)
//   harness dibits OUT_PREFIX   < digiham symbols 0..3, one byte each
// Writes OUT_PREFIX.sym (decided symbols; iq mode only), OUT_PREFIX.ambe
// (9-byte frames in order) and OUT_PREFIX.meta (one line per metadata event:
// "M slot sync type source target alias lat lon", '-' for absent).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <complex>
#include <fstream>
#include <iostream>
#include <iterator>
#include <map>
#include <string>
#include <vector>

namespace {
std::vector<char> read_stdin() {
  return std::vector<char>(std::istreambuf_iterator<char>{std::cin}, {});
}
struct Outputs {
  std::ofstream sym, ambe, meta;
  explicit Outputs(const std::string& prefix, bool symbols)
      : ambe(prefix + ".ambe", std::ios::binary), meta(prefix + ".meta") {
    if (symbols) sym.open(prefix + ".sym", std::ios::binary);
  }
};
}  // namespace

#ifdef DMR_PRISTINE
#include <csdr/dcblock.hpp>
#include <csdr/fftfilter.hpp>
#include <csdr/filter.hpp>
#include <csdr/firdecimate.hpp>
#include <csdr/fmdemod.hpp>
#include <csdr/fractionaldecimator.hpp>
#include <csdr/module.hpp>
#include <csdr/power.hpp>
#include <csdr/ringbuffer.hpp>
#include <csdr/shift.hpp>
#include <csdr/window.hpp>
#include "dmr_decoder.hpp"
#include "gfsk_demodulator.hpp"
#include "meta.hpp"
#include "rrc_filter.hpp"

namespace {
class LineWriter final : public Digiham::MetaWriter {
 public:
  explicit LineWriter(std::ofstream& out) : out_(out) {}
  void sendMetaData(std::map<std::string, std::string> m) override {
    auto field = [&](const char* key) -> std::string {
      auto it = m.find(key);
      return it == m.end() ? "-" : it->second;
    };
    out_ << "M " << field("slot") << ' ' << field("sync") << ' ' << field("type") << ' '
         << field("source") << ' ' << field("target") << ' ' << field("talkeralias") << ' '
         << field("lat") << ' ' << field("lon") << '\n';
  }
 private:
  std::ofstream& out_;
};

template <typename T>
struct Link {
  Csdr::Ringbuffer<T> buffer{1 << 20};
  Csdr::RingbufferReader<T> reader{&buffer};
};

// Pump modules in order until none can make progress (csdr's runner does the
// same with threads; order does not affect the sample values).
void pump(const std::vector<Csdr::UntypedModule*>& modules) {
  bool progress = true;
  while (progress) {
    progress = false;
    for (auto* m : modules)
      while (m->canProcess()) {
        m->process();
        progress = true;
      }
  }
}

template <typename T>
void drain(Link<T>& link, std::ofstream& out) {
  while (size_t n = link.reader.available()) {
    out.write(reinterpret_cast<const char*>(link.reader.getReadPointer()),
              static_cast<std::streamsize>(n * sizeof(T)));
    link.reader.advance(n);
  }
}

template <typename T>
void feed(Link<T>& link, const T* data, size_t n) {
  while (n > 0) {
    const size_t k = std::min(n, link.buffer.writeable());
    std::copy(data, data + k, link.buffer.getWritePointer());
    link.buffer.advance(k);
    data += k;
    n -= k;
    if (n > 0) throw std::runtime_error("input link full");
  }
}
}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "";
  const bool iq = mode == "iq" && argc == 4;
  if (!iq && !(mode == "dibits" && argc == 3)) {
    std::fprintf(stderr, "usage: %s iq RATE PREFIX | dibits PREFIX\n", argv[0]);
    return 2;
  }
  Outputs out(argv[argc - 1], iq);
  const auto input = read_stdin();
  using C = Csdr::complex<float>;

  // DMR decoder (DigihamChain tail), always present.
  Link<unsigned char> symbols, frames;
  Digiham::Dmr::Decoder decoder;
  decoder.setReader(&symbols.reader);
  decoder.setWriter(&frames.buffer);
  decoder.setMetaWriter(new LineWriter(out.meta));

  if (!iq) {
    const auto* d = reinterpret_cast<const unsigned char*>(input.data());
    for (size_t at = 0; at < input.size(); at += 4096) {
      feed(symbols, d + at, std::min<size_t>(4096, input.size() - at));
      pump({&decoder});
      drain(frames, out.ambe);
    }
    return 0;
  }

  const double in_rate = std::atof(argv[2]), out_rate = 48000.0;
  // csdr/chain/selector.py Selector + Decimator, pycsdr constructors.
  Link<C> source, shifted, decimated, fractioned, bandpassed, squelched;
  Csdr::ShiftAddfast shift(0.0f);  // frequencyOffset 0: the tap is VFO-centred
  shift.setReader(&source.reader);
  shift.setWriter(&shifted.buffer);
  const unsigned decimation = static_cast<unsigned>(in_rate / out_rate);
  const float fraction = static_cast<float>(in_rate / decimation / out_rate);
  Csdr::FirDecimate fir(decimation, static_cast<float>(0.15 * (out_rate / in_rate)),
                        new Csdr::HammingWindow(),
                        static_cast<float>(0.5 * decimation / (in_rate / out_rate)));
  fir.setReader(&shifted.reader);
  fir.setWriter(&decimated.buffer);
  std::vector<Csdr::UntypedModule*> chain = {&shift, &fir};
  Csdr::FractionalDecimator<C> fractional(fraction, 12, nullptr);
  Link<C>* last = &decimated;
  if (fraction != 1.0f) {
    fractional.setReader(&decimated.reader);
    fractional.setWriter(&fractioned.buffer);
    chain.push_back(&fractional);
    last = &fractioned;
  }
  Csdr::FilterModule<C> bandpass(new Csdr::FftBandPassFilter(
      static_cast<float>(-6250 / out_rate), static_cast<float>(6250 / out_rate),
      static_cast<float>(320.0 / out_rate), new Csdr::HammingWindow()));
  bandpass.setReader(&last->reader);
  bandpass.setWriter(&bandpassed.buffer);
  chain.push_back(&bandpass);
  // _buildSquelch(): length = outputRate/16, decimation 5, hang 2x, flush 5x;
  // DMR does not support squelch, so dsp.py pins the level at -150 dB.
  const size_t block = static_cast<size_t>(out_rate / 16);
  Csdr::Squelch<C> squelch(block, 5, 2 * block, 5 * block);
  squelch.setSquelch(static_cast<float>(std::pow(10.0, -150.0 / 10.0)));
  squelch.setReader(&bandpassed.reader);
  squelch.setWriter(&squelched.buffer);
  chain.push_back(&squelch);
  // DigihamChain: FmDemod -> DcBlock -> WideRrcFilter -> GfskDemodulator(10).
  Link<float> fm_out, dc_out, rrc_out;
  Csdr::FmDemod fm;
  fm.setReader(&squelched.reader);
  fm.setWriter(&fm_out.buffer);
  Csdr::DcBlock dc;
  dc.setReader(&fm_out.reader);
  dc.setWriter(&dc_out.buffer);
  Digiham::RrcFilter::WideRrcFilter rrc;
  rrc.setReader(&dc_out.reader);
  rrc.setWriter(&rrc_out.buffer);
  Digiham::Fsk::GfskDemodulator gfsk(10);
  gfsk.setReader(&rrc_out.reader);
  gfsk.setWriter(&symbols.buffer);
  // Tap the decided symbols without disturbing the decoder's reader.
  Csdr::RingbufferReader<unsigned char> symbol_tap(&symbols.buffer);
  chain.insert(chain.end(), {&fm, &dc, &rrc, &gfsk, &decoder});

  const auto* samples = reinterpret_cast<const C*>(input.data());
  const size_t n = input.size() / sizeof(C);
  for (size_t at = 0; at < n; at += 8192) {
    feed(source, samples + at, std::min<size_t>(8192, n - at));
    pump(chain);
    while (size_t k = symbol_tap.available()) {
      out.sym.write(reinterpret_cast<const char*>(symbol_tap.getReadPointer()),
                    static_cast<std::streamsize>(k));
      symbol_tap.advance(k);
    }
    drain(frames, out.ambe);
  }
  return 0;
}

#else
#include "dmr/channel.hpp"
#include "dmr/framing.hpp"

namespace {
std::string text(uint32_t v) { return v ? std::to_string(v) : "-"; }
}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "";
  const bool iq = mode == "iq" && argc == 4;
  if (!iq && !(mode == "dibits" && argc == 3)) {
    std::fprintf(stderr, "usage: %s iq RATE PREFIX | dibits PREFIX\n", argv[0]);
    return 2;
  }
  Outputs out(argv[argc - 1], iq);
  const auto input = read_stdin();
  sdrcore::dmr::Framing framing(
      [&](const sdrcore::dmr::AmbeFrame& frame) {
        out.ambe.write(reinterpret_cast<const char*>(frame.bits),
                       static_cast<std::streamsize>(sizeof(frame.bits)));
      },
      [&](const sdrcore::dmr::SlotMeta& m) {
        out.meta << "M " << unsigned(m.slot) << ' '
                 << (m.sync == 2 ? "voice" : m.sync == 1 ? "data" : "-") << ' '
                 << (m.type == 2 ? "group" : m.type == 1 ? "direct" : "-") << ' '
                 << text(m.source) << ' ' << text(m.target) << ' '
                 << (m.alias.empty() ? "-" : m.alias) << ' '
                 << (m.latlon ? std::to_string(static_cast<float>(m.latlon->first)) : "-") << ' '
                 << (m.latlon ? std::to_string(static_cast<float>(m.latlon->second)) : "-")
                 << '\n';
      });
  if (!iq) {
    const auto* d = reinterpret_cast<const uint8_t*>(input.data());
    for (size_t at = 0; at < input.size(); at += 4096)
      framing.on_symbols(d + at, std::min<size_t>(4096, input.size() - at));
    return 0;
  }
  struct Sink final : sdrcore::dmr::SymbolSink {
    sdrcore::dmr::Framing* framing;
    std::ofstream* sym;
    void on_symbols(const uint8_t* dibits, size_t n) override {
      sym->write(reinterpret_cast<const char*>(dibits), static_cast<std::streamsize>(n));
      framing->on_symbols(dibits, n);
    }
  } sink;
  sink.framing = &framing;
  sink.sym = &out.sym;
  sdrcore::dmr::Channel channel;
  if (!channel.configure(static_cast<uint32_t>(std::atoi(argv[2])))) return 3;
  const auto* samples = reinterpret_cast<const std::complex<float>*>(input.data());
  const size_t n = input.size() / sizeof(std::complex<float>);
  for (size_t at = 0; at < n; at += 8192)
    channel.process(samples + at, std::min<size_t>(8192, n - at), sink);
  return 0;
}
#endif

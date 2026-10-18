# DMR channel front end (t_8e3dfcc0)

`native/src/dmr/channel_filter.{hpp,cpp}` isolates the complex 12.5-kHz
channel selector and digiham pulse-shaping presets from the demodulator.
`ChannelFilter::configure(rate)` accepts 48–300 kS/s VFO-centred complex
samples and emits 48 kS/s complex IF over time; constants expose
the required minimum/maximum input, output and ±6250-Hz cutoffs. It runs
OpenWebRX+'s own selector modules at the actual input rate; 48k, 240k,
250k, 288k and 300k are tested sample-for-sample against them.
`RrcPulseFilter` accepts/emits 48 kS/s real discriminator samples, selects
upstream digiham Wide (81 taps, DMR) or Narrow (161 taps, NXDN) presets,
and uses the original coefficients and gain. Both components reset stream
history; no tuner, squelch, or Dart sample flow is involved. `Channel` uses
the filter and DMR Wide preset before its unchanged GFSK(10) stage.

`native/src/dmr/channel.{hpp,cpp}` consumes the existing one-receiver
VFO-centred 200–300 kS/s complex baseband tap (`Decoder::Input::baseband`).
It never tunes or acquires USB. `Channel::configure(baseband_rate)` resets state;
`process()` sends 0..3 digiham dibits to `SymbolSink` at 4800/s; `reset()`
clears filters, symbol-clock recovery and fractional-rate history. The
framing/metadata decoder (t_0c6cc09e) and registry/sink hookup in the DMR
integration card are still required. This library does not advertise DMR to
users or produce decoded calls/audio on its own.

`ChannelDecoder` in `channel_tap.{hpp,cpp}` is the reusable native
`Decoder::process(interleaved CF32, pairs, actual_rate_hz)` input stage for
the full DMR backend: it copies interleaved samples in bounded blocks into
`Channel`, receives 4800 dibits/s through `SymbolSink::on_symbols()`, and
forwards every `Decoder::reset()` to all FIR/DC/symbol-clock state. The full
backend must derive from it, forward symbols to `Framing`, implement config
and event polling, and register `dmr` itself; this stage alone deliberately
does not advertise a partially working decoder. The receiver's existing
VFO branch shifts and integer-decimates source IQ; it supplies the *actual*
tap rate. For example 2.4 MS/s -> 240 kS/s, 2.5 MS/s -> 250 kS/s,
2.88 MS/s -> 240 kS/s, and 576 kS/s -> 288 kS/s. No source retune,
separate receive path, or squelch gate is involved. A changed tap rate
reconfigures the channel before accepting more IQ; a stream/retune reset
discards old IF and symbol history. `sdrcore_dmr_channel_tap` runs synthetic
CU8 through the real `Receiver::set_decoder(Input::baseband)` branch with
manual squelch closed and audio muted, checking rate propagation, 48-kS/s
IF and 4800-symbol/s counts, reset/replay, detach and retune. Live RF and
full framing/voice event output remain unverified here.

Signal path (OpenWebRX+ f1e0d1ac `csdr/chain/selector.py`, pycsdr 041986e5
module parameters, csdr-plus f26b520 code): `FirDecimate(d = floor(in/48k),
transition 0.15*48k/in, cutoff 0.5*d/(in/48k), Hamming)` at the *actual* tap
rate, then `FractionalDecimator(in/d/48k, 12 Lagrange points, no prefilter)`
when that ratio is not 1 (e.g. 250k: d=5, 50k -> 48k), then
`FftBandPassFilter(±6250/48k, transition 320/48k, Hamming)` in a
`FilterModule`. Squelch is omitted (DMR forces it open). The native
adapter then invokes the vendored csdr-plus `FmDemod` (`dphase/pi`), `DcBlock`
(R=0.998), digiham-plus `WideRrcFilter` (the unchanged 81 coefficients and
8.337797030 gain) and `GfskDemodulator(10)` (100-symbol level calibration,
mid-third averaging and variance-based clock slip).

Deviations from OpenWebRX+: its selector starts with `Shift(-offset/in)` on
the full SDR rate; here the receiver's existing VFO tap already shifts and
integer-decimates, so the selector's input rate is the tap rate (e.g.
240 kS/s instead of 2.4 MS/s) and the Shift stage is not repeated. The
adapter releases input to the csdr modules in fixed blocks of
`floor(in/48k) * 1024` samples (`kBlockOutputSamples`): csdr's
`FractionalDecimator` renormalises its float read position once per
`process()` call, so its output otherwise depends on caller chunking. This
adds up to ~21 ms latency and makes output identical for any chunking.
`sdrcore_dmr_channel_filter` drives the pinned csdr modules directly with the
same block size and requires bit-identical output at all five rates.
Gfsk's calibration ring and the RRC delay are zero-initialized
rather than reading indeterminate upstream memory. The RRC coefficient array
is copied on construction because upstream's temporary C++ compound literal
otherwise dangles. The GFSK max-volume initial value is -FLT_MAX (not the
upstream FLT_MIN) so all-negative windows calibrate correctly.
FFTW plan creation/destruction for the FFT bandpass is serialised with the
SSTV decoder through `src/dsp/fftw_planner.hpp`. On Apple/Windows only,
`compat/csdr_sincosf.h` is force-included into `fir.cpp` to supply the GNU
`sincosf()` (sin/cos may differ from glibc by float rounding there).
Air-recording oracle parity remains open.

Vendor provenance: `native/third_party/openwebrx-dmr/` contains source from
luarvique/csdr-plus and luarvique/digiham-plus, pinned in docs/status/dmr.md
(digiham-plus beec7822) and `PROVENANCE-channel.md`. Retain the vendored
license texts. Tests use synthetic baseband and direct discriminator-domain
vectors; DMR framing, OTA decoding, Android hardware and voice are unverified.

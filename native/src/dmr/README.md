# DMR channel front end (t_8e3dfcc0)

`native/src/dmr/channel_filter.{hpp,cpp}` isolates the complex 12.5-kHz
channel selector and digiham pulse-shaping presets from the demodulator.
`ChannelFilter::configure(rate)` accepts 48–300 kS/s VFO-centred complex
samples and emits exactly 48 kS/s complex IF over time; constants expose
the required minimum/maximum input, output and ±6250-Hz cutoffs. The actual
input rate is passed to both FIR stages; 240k, 250k and 288k are tested.
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

Signal path: 127-tap Blackman FIR and integer decimation at the *actual* tap
rate (e.g. 250k -> 50k), then 161-tap, 64-phase low-pass/resampler for a
6250 Hz complex channel at exactly 48 kS/s. There is no squelch. The native
adapter invokes the vendored csdr-plus `FmDemod` (`dphase/pi`), `DcBlock`
(R=0.998), digiham-plus `WideRrcFilter` (the unchanged 81 coefficients and
8.337797030 gain) and `GfskDemodulator(10)` (100-symbol level calibration,
mid-third averaging and variance-based clock slip). The matched-rate test
verifies 24,000 IF samples per 0.5 seconds at 240k, 250k and 288k tap rates.

Deviations from OpenWebRX+: its selector shifts, resamples, and bandpasses
inside libcsdr/pycsdr; here the existing VFO tap already shifts/decimates,
and a causal two-stage FIR/polyphase adapter does the final bandpass and
resampling. This is not a sample-for-sample replica of the FFT/libsamplerate
selector, and no same-recording oracle correlation has been measured yet
(t_371d403a). The 64 fractional phases have <=1/64 stage-rate-sample phase
quantization. Gfsk's calibration ring and the RRC delay are zero-initialized
rather than reading indeterminate upstream memory. The RRC coefficient array
is copied on construction because upstream's temporary C++ compound literal
otherwise dangles. The GFSK max-volume initial value is -FLT_MAX (not the
upstream FLT_MIN) so all-negative windows calibrate correctly.
The retained native 127/161-tap Blackman selector is not the upstream
csdr-plus FFT bandpass/FractionalDecimator implementation; it must not be
represented as an exact upstream algorithm. Direct tone/boundary tests cover
the rate and pass/stop behaviour; air-recording oracle parity remains open.

Vendor provenance: `native/third_party/openwebrx-dmr/` contains source from
luarvique/csdr-plus and luarvique/digiham-plus, pinned in docs/status/dmr.md
(digiham-plus beec7822). Retain the vendored license texts. The extra
`csdr/fftfilter.{cpp,hpp}` files are unused exploratory copies, not needed
in the build. Tests use synthetic baseband and direct discriminator-domain
vectors; DMR framing, OTA decoding, Android hardware and voice are unverified.

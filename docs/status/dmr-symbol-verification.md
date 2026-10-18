# DMR channel symbol verification

This report covers the current native DMR front end, not a registered DMR
receiver. Run from the repository root:

```sh
cmake -S native -B build/native-host-tests -DCMAKE_BUILD_TYPE=Debug
cmake --build build/native-host-tests -j4
ctest --test-dir build/native-host-tests -R '^sdrcore_dmr_channel' --output-on-failure
build/native-host-tests/sdrcore_dmr_channel_test
```

`native/tests/dmr_channel_test.cpp` drives 10 samples/symbol of four discriminator
levels through DC removal, the Wide RRC preset, and GFSK. After calibration,
levels -0.75/-0.25/+0.25/+0.75 must yield digiham dibits 3/2/0/1. A
separate path calls the pinned csdr `DcBlock`, digiham `WideRrcFilter` and
`GfskDemodulator(10)` directly on a changing four-level discriminator stream;
the native `Channel` must match every emitted symbol across 137-sample chunks
and after reset. This checks buffering and adapter parity against the vendored
upstream algorithm, **not** independent over-the-air parity: the same vendored
source is linked on both sides. Synthetic four-level FM IQ at the actual
240/250/288 kS/s baseband rates checks centre decisions across 12-symbol runs
with only fixed group delay/clock phase searched, and not just output counts.

`native/tests/dmr_channel_filter_test.cpp` builds OpenWebRX+'s selector
directly from the pinned csdr-plus modules (`FirDecimate`,
`FractionalDecimator`, `FftBandPassFilter` in a `FilterModule`, with the
selector.py/pycsdr parameters) and requires the native `ChannelFilter`, fed
irregular 1..16384-sample chunks, to produce **bit-identical** IF at
48/240/250/288/300 kS/s for a 4FSK-like signal with an adjacent-channel tone
and noise. Whole-block versus chunked feeding and reset reproduce the same
output; a half-second yields 23,430 IF samples (24,000 less the upstream
start-up latency and the adapter's input block), and ten seconds shows no
rate drift. Positive and negative 0/3/5/6 kHz tones pass; ±6.7/9/13 kHz and
tones that would alias into the channel after integer decimation are
rejected. The original digiham Wide (81 taps) and
Narrow (161 taps) impulse outputs match the adapter exactly over chunk
boundaries and resets; only Wide is selected for DMR. The receiver-level
`sdrcore_dmr_channel_tap` test injects CU8 at 2.4, 2.5, 2.88 MS/s and
576 kS/s: the native receiver supplies 240/250/240/288 kS/s respectively,
then a 48 kS/s IF and one dibit per 10 IF samples (851–894 dibits in the
first 200 ms, after selector start-up) despite analog squelch and mute.

## Results

Upstream-selector parity (feat/dmr-upstream-channel-selector, Linux host,
Debug with -O2 DSP sources): `sdrcore_dmr_channel_filter` reported
`upstream=23430 native=23430 max|d|=0` at all five rates. Before the
change the same test failed against the old Blackman selector (output
lengths and samples differ), which is the RED half of this regression test.
`sdrcore_dmr_channel_test` reported IF=23,430 and 2,342–2,343 symbols per
half-second at 48/240/250/288/300 kS/s; four-level decision and
direct-upstream symbol parity tests are unchanged and pass. Full gate
results for the merge are in the task handoff.

## Upstream reference and deviations

OpenWebRX+ (`luarvique/openwebrx` f1e0d1ac) uses a Shift -> FirDecimate ->
FractionalDecimator -> FFT Bandpass csdr selector (±6250 Hz, 320 Hz
transition), no squelch and 48 kS/s IF followed by
FM demodulation, DC block, Wide RRC and digiham GFSK(10). The copied
`digiham-plus` beec7822 GFSK implementation differs from the local reference
only by zero-initialising its 100-symbol calibration ring and initialising
its maximum to `-FLT_MAX` instead of `FLT_MIN`. This avoids indeterminate
startup symbols and corrects all-negative calibration windows; it does not
change the decisions once a valid bipolar ring is filled. The local RRC copy
owns its coefficient array (upstream passes temporary compound-literal arrays)
and starts its delay at zero rather than uninitialised memory. These changes
make startup/reset deterministic; they can change early symbols versus an
arbitrary upstream process's initial memory contents.

The channel selector now runs OpenWebRX+'s own csdr-plus modules (byte-
identical, `native/third_party/openwebrx-dmr/PROVENANCE-channel.md`). Two
deviations remain. (1) The receiver's own VFO shift and integer decimation
replace OpenWebRX+'s initial `Shift` on the full SDR rate, so the selector
starts from the actual tap rate (e.g. 240 kS/s, not 2.4 MS/s); the native
VFO decimator's filter therefore precedes csdr's. No second tuner, source
retune, or analog squelch gate is inserted. (2) Input enters the csdr
modules in fixed blocks of `floor(rate/48k) * 1024` samples. csdr's
`FractionalDecimator` keeps its read position as a float renormalised per
call, so in OpenWebRX+ its output depends on pycsdr buffer sizes (measured
here: up to 0.86 absolute sample difference at 250 kS/s between block sizes).
Fixed blocks make native output deterministic for any caller chunking, at a
cost of up to ~21 ms latency. Integer-ratio rates (48k, 240k) are unaffected
by block size.

**Missing reference fixture:** no matching OpenWebRX+ IF/IQ recording with
known symbol output is available in this tree. Selector parity is against
the pinned upstream modules driven by an independent test harness, not
against a running OpenWebRX+ instance (pycsdr buffer sizes there are
runtime-dependent, see deviation 2). No bit-error rate on real signals is
claimed. Live DMR air reception,
framing-through-a-registered-backend and audible decoded voice remain
unverified; see `docs/status/dmr.md` for downstream integration status.

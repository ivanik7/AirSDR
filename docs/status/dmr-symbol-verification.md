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

`native/tests/dmr_channel_filter_test.cpp` checks a half-second yields exactly
24,000 complex IF samples at 48/240/250/288/300 kS/s; arbitrary chunk
boundaries and reset reproduce the same output. Positive and negative 3/5 kHz
tones pass; 9/13 kHz and input tones that would alias to 3 kHz after native
integer decimation are rejected. The original digiham Wide (81 taps) and
Narrow (161 taps) impulse outputs match the adapter exactly over chunk
boundaries and resets; only Wide is selected for DMR. The receiver-level
`sdrcore_dmr_channel_tap` test injects CU8 at 2.4, 2.5, 2.88 MS/s and
576 kS/s: the native receiver supplies 240/250/240/288 kS/s respectively,
then a 48 kS/s IF and >900 dibits in 200 ms despite analog squelch and mute.

## Results

On this Linux host, Debug CMake build succeeded; targeted CTest 3/3 passed.
Direct `sdrcore_dmr_channel_test` reported 24,000 IF samples and
2,399/2,400 symbols for a half-second at 48/240/250/288/300 kS/s.
The full 42-test CTest run initially had one unrelated USB direct test fail
(`sdrcore_host_usb_direct`, RTL-SDR configure error -7/-4); its isolated
rerun passed 1/1, and a second complete CTest run passed **42/42**. The
first full run was **41/42**, not silently counted as green.
`flutter analyze` reported no issues; `flutter test --concurrency=1`
finished at +540, 17 skipped; the locked `flutter build apk --debug`
built `build/app/outputs/flutter-apk/app-debug.apk`.

## Upstream reference and deviations

OpenWebRX+ (`luarvique/openwebrx` f1e0d1ac) uses a shift/FFT-based csdr
channel selector, ±6250 Hz bandpass, no squelch and 48 kS/s IF followed by
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

The channel selector is **not** OpenWebRX+'s FFT selector: this port uses a
127-tap Blackman anti-alias FIR with integer decimation at the receiver's
actual native tap rate, then a 161-tap/64-phase Blackman selector/resampler.
Its phase grid has at most 1/64 stage-rate sample quantisation; response,
latency, and noise/interference rejection near ±6250 Hz may differ from the
FFT chain. The tone tests establish coarse pass/stop and alias suppression,
not spectral equivalence at the transition edge. The receiver's own VFO
shift/decimation replaces OpenWebRX+'s initial shift; no second tuner, source
retune, or analog squelch gate is inserted.

**Missing reference fixture:** no matching OpenWebRX+ IF/IQ recording with
known symbol output, nor reproducible pristine OpenWebRX+ FFT-selector output
for the *same* input, is available in this tree. No bit-error rate or
sample-by-sample selector correlation is claimed. The direct-source test
cannot substitute for that independent oracle. Live DMR air reception,
framing-through-a-registered-backend and audible decoded voice remain
unverified; see `docs/status/dmr.md` for downstream integration status.

# STATUS — SSTV native vs OpenWebRX+ oracle (t_9165cc6e)

## What was compared
- **Oracle.** The oracle is the pristine csdr-plus `f26b520`, built by its own CMake (Release `-O3 -ffast-math`) against FFTW 3.3.10 (SIMD, sha256 checked) and libsamplerate 0.2.2. `tool/sstv_oracle/owrx_sstv_harness.cpp` runs `Csdr::SstvDecoder<float>(24000, 300000)`, the same arguments as OpenWebRX+ `SstvDemodulator`. It feeds blocks of 1024 samples, which is the `Command::runModule` clamp. `compare.py` frames the bytes the way `owrx/sstv.py` does: `" [..]"` text, `BM` header with VIS at byte 6, width and `-height`, then BGR rows. This framing was re-implemented; no AGPL code was copied. The oracle is host-only, is never linked into the app, and never runs as a subprocess. Build: `NATIVE_BUILD=build/native-host tool/sstv_oracle/build_oracle.sh WORK`.
- **FFTW control.** `owrx_sstv_harness_vfftw` is the same pristine upstream `sstv.cpp`, built at `-O2` and linked against the app's vendored FFTW. It isolates FFTW rounding from our patches.
- **Native.** `native/tests/sstv_replay.cpp` (CMake target `sdrcore_sstv_replay`) has two modes:
  - `adapter`: WAV → production `create_sstv()` adapter.
  - `receiver`: WAV → CU8 IQ at 240 kS/s, VFO centred → production `dsp::Receiver` with its 24 kHz audio tap → adapter. USB, LSB and NFM are supported.
- **Corpus.** The encoder is pySSTV `d998fad` (MIT; Pillow 12.3.0). Files are mono s16 24 kHz WAVs. The signal sits at 0.25 FS with 1 s of lead-in and 3 s of trailer. Command: `gen_corpus.py OUT` (deterministic; `manifest.json` lists the SHA-256 of every WAV and PNG). There are 23 cases:
  - 9 clean modes: Robot 36, Martin 1/2, Scottie 1/2, PD-90/120/160, Wraase SC2-180;
  - noise: Robot 36 at SNR 10/5/0 dB, Martin 1 and PD-90 at 10 dB;
  - offsets: Robot 36 at +30/−45/+60 Hz, Martin 1 at +40 Hz, Scottie 1 at −30 Hz with 10 dB SNR;
  - clock error: ±500 ppm;
  - VOX preamble;
  - Robot BW24 (VIS 10, unmapped upstream).

  `--full` adds PD-180/240/290, Scottie DX and SC2-120; it was not run because of disk space.
- **Run.** `compare.py --corpus C --oracle owrx_sstv_harness --fftw-control owrx_sstv_harness_vfftw --replay build/native-host/sdrcore_sstv_replay --out R --receiver` (about 6 min). It writes `report.md`, `report.json`, and PNG images for oracle, adapter and receiver.

## Results (cmp3: 356 checks, 2 failed, both PD-90 over NFM; table in tool/sstv_oracle/report-cmp3.md, corpus manifest with SHA-256s in tool/sstv_oracle/corpus-manifest.json)
| Check | Result |
|---|---|
| VIS / mode / dimensions | Equal to the oracle in every decoding case. Native reports the csdr-plus C++ NAME (`PD-90`). The OpenWebRX+ UI shows its own table name (`PD 90`) for the same VIS. |
| Unsupported VIS 10, and the +60 Hz offset | Oracle 0 frames, native 0 frames: parity. Upstream's VIS tolerance rejects 60 Hz. |
| Rows / completion | Every decoded frame has `height` rows, status `complete/end`, and 0 padded rows, the same as the oracle. OpenWebRX+ has no completion message; the oracle counts as complete when it has all rows. |
| Progress | Every row becomes available in the same 1024-sample input block as the oracle's: lag 0..0 in all cases. |
| Pixels, adapter vs oracle | 0–22 of 245k–952k bytes differ (≤0.003 %). Usually \|d\|=1. One noisy Martin 1 pixel differs by \|d\|=20. Adapter vs the vendored-FFTW control: **byte-identical in every case**, so all differences come from FFTW SIMD and fast-math rounding, not from our patches. |
| PSNR vs source, flat patches | Native equals the oracle to 0.01 dB in every case. Clean values are 25.5–31.4 dB, except PD-120 at 18.4 dB, which matches the oracle. 10 dB SNR gives 19.5–22.4 dB, 5 dB gives 15.7, 0 dB gives 10.3. |
| Receiver USB/LSB | Within 0.25 dB of the oracle's PSNR vs source, and 34–46 dB vs the oracle image. On noisy input the receiver is 1.2–2.3 dB *better*, because its channel filter removes out-of-band noise. |
| Receiver NFM | Robot 36 and Martin 1 are fine (≥34.7 dB vs the oracle image). **PD-90 over NFM: 23.5 dB vs source and 25.0 dB vs the oracle; USB gives 29.5.** This is a receiver-path finding, not a decoder one. See the gaps section. |

### Threshold justification
- **Adapter vs oracle.** At most 0.1 % of bytes may differ, and PSNR must be within 0.05 dB. Both sides use the same decoder source and the same input, so only FFTW and fast-math rounding can differ. The control proves exactly that: native is byte-identical to pristine upstream when both use the same FFTW.
- **Absolute PSNR floors.** The floors are 25 dB clean, 20 dB at 10 dB SNR and 14 dB at 5 dB SNR. They are reported but not gated, because the upstream decoder itself misses them for PD-120 (18.4 dB, a 5.6-pixel FFT window on a 640 px line) and for frequency offsets (Robot 36 at +30 Hz: 23.3 dB, at −45 Hz: 20.6 dB, since csdr-plus does no AFC). Native is required to match the oracle instead.
- **Receiver.** On clean input the receiver image must be ≥30 dB vs the oracle image (RMS ≤ 8 levels) and lose ≤1 dB vs source. The flat-patch metric excludes an edge-smear margin of ceil(WINDOW_FACTOR)+1 px.
- **pySSTV line width.** pySSTV sends Martin 2 / Scottie 2 at 160 px per line, while csdr-plus decodes them at 320. The source is therefore scaled ×2 in x with nearest-neighbour before scoring.

## End-to-end UI check (Linux host, real FFI)
`test/native/sstv_replay_e2e_test.dart` with `SDRCORE_HOST_LIBRARY=build/native-host/libsdrcore.so` and `SSTV_REPLAY_IQ=robot36_usb_240k.cu8`. The IQ comes from `sdrcore_sstv_replay make-iq corpus/Robot36_clean.wav robot36_usb_240k.cu8 --mode usb --rate 240000 --vfo 0`; its sha256 is a2c5248a…23ad. The test chain is: the native file source (paced at 240 kS/s, looping) → NativeRadioController → DecoderSession → SstvDecoderPanel. Result: **2/2 passed**.
- **Retune reset.** After 40 rows, a +1 kHz retune closes the frame as `partial/retune` and it goes to the gallery. After tuning back, no stale rows are added and no frame starts without a VIS.
- **Next loop.** The next pass is `Robot 36 vis=8 320x240 rows=240 padded=0 complete/end dropped=0`.
- **UI save.** Thumbnail → dialog → «Сохранить PNG» goes through the real Linux `PlatformSstvImageSaver`. It produced `SSTV-261011-003739-14230.png` (158,967 B), whose pixels are bit-exact with the decoded frame.

## Blockers / gaps
- **Not verified on Android.** The phone save through MediaStore belongs to the separate phone-QA card.
- **No live-air test.** No over-the-air SSTV transmission was available.
- **PD-90 over NFM (resolved by t_b137e226).** The original synthetic FM transmitter used no pre-emphasis. The receiver's csdr NFM de-emphasis FIR tilts 1.2–2.3 kHz tones (relative to 1.5 kHz: +1.0 dB at 1.2 kHz, −1.4 dB at 1.9 kHz, −3.2 dB at 2.3 kHz). This produces an amplitude step at every SSTV tone transition; csdr's FFT-peak search biases toward the louder side, delaying sync and displacing pixels in fast modes. It is not an intrinsic 2.5 kHz-deviation NFM limitation. A Hilbert analytic-envelope limiter on the **NFM decoder tap only**, after the existing FIR, removes the amplitude tilt while keeping the channel filter/de-emphasis. On the same PD90_clean IQ corpus: NFM flat-patch PSNR against the pristine OpenWebRX+ WAV oracle is **46.97 dB**, versus **24.98 dB** before; versus source **29.66 dB** (oracle **29.75 dB**). USB and LSB remain **29.57 dB** vs source / **36.24 dB** vs oracle; no SSB DSP path was modified. The native PD-90/Scottie 1 FM regression compares both flat pixels and bar edges against the direct adapter. A transmitter with a matching pre-emphasis shelf already improved the previous path (PD-90 **36.53 dB** vs oracle); the limiter also works with that shelf (**35.98 dB** vs oracle). These are synthetic IQ results, not a live-air or phone measurement. At RF CNR 20 dB/12.5 kHz the noisy PD-90 simulation improves from **24.11** to **31.70 dB** vs the *clean* oracle image; the clean ≥30 dB gate does not apply at low RF CNR.
- **No license or bandwidth blocker.** pySSTV is MIT and test-only; csdr-plus is GPL-3 and the oracle is host-only. The SSTV band at 24 kHz audio needs any IQ rate ≥ 24 kS/s, so the device bandwidth is not a constraint.

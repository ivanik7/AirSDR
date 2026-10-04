# N2 native receiver DSP (work in progress)

`receiver.cpp` is an original, GPL-3.0-or-later implementation of equivalent
receive primitives, not a vendored SDR++ source file. It is built from source
into `libsdrcore.so` by the native CMake project; no prebuilt DSP dependency
or Dart IQ/PCM transfer is involved. The interface is `receiver.h`, driven by
the ABI-v3 owner in `sdrcore.cpp` on one DSP consumer thread.

- Centered CU8 complex IQ (HackRF CS8 is translated at ingress), complex
  oscillator for one in-band VFO, two windowed-sinc/Blackman FIR decimators,
  and a polyphase 32-tap, 64-phase FIR resampler to 48 kHz.
- 2048-point in-place radix-2 FFT with Hann window and shifted, max-decimated
  dBFS bins; the core stores one latest row only. SSB's frequency reference
  is its lower (USB) or upper (LSB) passband edge.
- FM phase discriminator and deemphasis (WFM/NFM); AM envelope/DC removal;
  DSB/USB/LSB real projection; 700 Hz CW beat; audio high-pass and AGC.
  Stereo sink frames are native. Squelch offers fixed power threshold and
  learned auto threshold (NFM discriminator-noise or low-percentile level),
  with a ramped audio gate. Mute and squared volume operate in the DSP path.
- File IQ (CU8) is paced at its declared rate in ABI v3. Synthetic IQ and
  RTL-SDR/HackRF feed the same bounded 64-slot (512 KiB) ingress; the two USB
  adapters and host-only open-by-bus path remain source-built from the N1
  drivers. One process-wide native USB claim prevents a second native handle
  from opening hardware. Dart/native exclusivity must also be enforced by
  the controller/service owner outside this library.

These are equivalent primitives, not bit-identical SDR++ blocks. WFM currently
demodulates mono and duplicates it to L/R: no FM stereo multiplex/pilot
recovery. Noise reduction is limited to low-pass filtering, deemphasis and
squelch; there is no dedicated FM IF noise-reduction or noise blanker.
Hardware AGC is not exposed by the N1 USB adapters and requesting it returns
`SDR_UNSUPPORTED` rather than a fake success. IQ file format is CU8 only at
this stage, not CS16/CF32/WAV. These gaps require explicit parity review by
the N2 integrator before native can become the default receive engine.

Host proof in this branch: CTest 8/8, 240 kS/s synthetic and paced CU8 file
smokes (240,000 input pairs, 0 dropped, 47,999 audio frames for the file),
and a 10-second RTL-SDR Blog V4 WFM/null-sink smoke at 2.4 MS/s (23,982,080
input pairs, 0 ring drops, 479,642 audio frames, 479,586 non-silent frames).
This is not the required ten-minute Linux/UI/WAV comparative acceptance.
`fft_overwrites` rose because that smoke intentionally did not poll rows.
`sdrcore` still reports ABI 2 until all N2 components integrate; no v3 client
should activate from its version gate yet.

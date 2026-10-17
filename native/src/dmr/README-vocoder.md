# DMR AMBE+2 voice output (native/src/dmr/vocoder.*)

Task t_5b101746. Reproduces the OpenWebRX+ DMR voice path in process:

```
DmrDecoder (t_0c6cc09e)  --AmbeFrame (9 bytes, interleaved, MSB-first)-->
VoiceOutput::on_ambe
  AmbeSynthesizer  = codecserver-softmbe decode_ambe_3600x2450 (mbelib, uvquality 3)
                     -> 160 x int16 @ 8 kHz per frame
  DigitalVoiceFilter (digiham-plus, verbatim)
  Agc<short> (csdr-plus, verbatim; maxGain 30, initialGain 3, other defaults)
  x6 polyphase interpolator (Kaiser sinc, 240 taps) -> 48 kHz float
  bounded queue (100 ms prebuffer, 1 s cap, oldest dropped)
Decoder::read_audio  <- receiver, once per processed block
```

## Integration contract (decoder.hpp)

A backend that synthesizes voice returns `provides_audio() == true` and
implements `read_audio(mono, n)` by forwarding to `VoiceOutput::read_audio`.
The receiver (`receiver.cpp`, `replace_with_decoder_audio`) then REPLACES
the demodulator output of every block with exactly as many decoder samples
as the block would have emitted, applies `volume^2` and mute, does not apply
the squelch gate (OpenWebRX+ DMR: `supportsSquelch() = False`) and fills
underruns with silence. `sdrcore.cpp` keeps the baseband-decoder
mute-while-decoding policy for all other baseband decoders and while a voice
decoder is detached for stale (retune) slots. PCM never crosses the C ABI or
reaches Dart; it goes to the existing AudioSink (AAudio on Android,
ALSA/WAV on Linux).

The DMR backend (card t_bc6f9eeb / t_0c6cc09e) owns one `VoiceOutput`,
passes it as the `VoiceSink` to the framing decoder, calls `reset()` on
`Decoder::reset()` (retune, mode, stop) and maps the decoder config
`{"voice": false}` to `set_enabled(false)`.

`AmbeFrame` lives in `ambe_frame.hpp` and is shared by `framing.hpp` and
`vocoder.hpp`. `Framing` takes a `std::function` voice callback; connect it
with `framing_voice_sink(voice_output)`:

```
VoiceOutput voice;
Framing framing(framing_voice_sink(voice), on_meta);
```

`sdrcore_dmr_framing_voice` (CTest) drives digiham bursts (CACH/TACT, BS
voice sync, 27-byte payload) carrying synthetic AMBE+2 frames through
`Framing` into `VoiceOutput`. It checks that the selected slot's frames arrive
bit-exactly and in order, that 8 kHz and 48 kHz PCM are bit-identical to a
`VoiceOutput` fed the same frames directly, that slot filter 2 selects TS2,
that `{"voice":false}` drops frames, and that `SDRCORE_ENABLE_MBELIB=OFF`
produces no PCM.

## Build option

`SDRCORE_ENABLE_MBELIB` (default ON). OFF: mbelib is not compiled,
`vocoder_available()` is false, frames are counted in `frames_dropped()`,
`read_audio()` returns 0 and the receiver plays silence. Use it for builds
that must not contain the AMBE+2 decoder (patent note: STATUS-dmr.md §5).

## Verification

- `sdrcore_dmr_vocoder` (CTest): mbelib round-trip of the test channel
  encoder, Golay correction counts, erasure/silence frames, repeat/mute
  (`RRRM`), 8 kHz frame accounting (first frame 60 samples due to the AGC
  100-sample look-ahead, then 160), x6 rate, images < 1e-9 of power above
  4.5 kHz, queue bound, reset/disable, determinism.
- `sdrcore_decoder_voice_replace`: receiver replace stage (exact request
  sizes, volume^2, mute, closed squelch does not gate, underrun silence,
  non-voice decoders untouched).
- `sdrcore_decoder_voice_abi`: synthetic source through the DSP worker
  into a real `wav:` sink.
- `tool/dmr_voice_oracle`: bit-exact comparison against pristine
  codecserver-softmbe + mbelib + digiham DigitalVoiceFilter + `csdr agc`.

Test frames come from `native/tests/dmr_ambe_test_encoder.hpp`, an exact
inverse of mbelib's channel decoding for chosen parameter vectors. There is
no open AMBE+2 speech encoder, so these frames are vocoder buzz, not speech;
no over-the-air DMR voice has been decoded yet.

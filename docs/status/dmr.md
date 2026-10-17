# STATUS — DMR audit (OpenWebRX+ chain, digiham, codecserver, mbelib)

Sections 1–8 are the audit and interface definition. Section 9 tracks the
subsequent symbol-level framing port; no live DMR decoder is registered yet.
Work is split into: filter + 4FSK, framing/metadata, AMBE synthesis + audio,
UI, and backend integration.

Labels: **[verified]** = read in the pinned source or primary record listed below.
**[unverified]** = inference or secondary source, not checked against a primary record.

## 1. Pinned reference sources (all local under `<refs>/openwebrx`)

| Repo | Commit (date) | License |
|---|---|---|
| luarvique/openwebrx (OpenWebRX+) `openwebrx-plus/` | f1e0d1ac (2026-09-28) | AGPL-3.0 (Python/JS; used as reference only, nothing copied) |
| luarvique/digiham `digiham-plus/` | beec7822 (2026-08-23) | GPL-3.0 (LICENSE) |
| jketterl/digiham `digiham/` | 410853cf (2024-02-04) | GPL-3.0; DMR/GFSK/RRC/lib sources identical to the plus fork, only `mbe_synthesizer` differs (socket thread) |
| luarvique/pydigiham `pydigiham-plus/` | 9ab0f239 | GPL-3.0 (Python bindings; reference only) |
| jketterl/codecserver `codecserver-master/` | 8caf36aa (2022-06-14) | GPL-3.0 (server + protobuf protocol; not needed in-app) |
| fventuri/codecserver-mbelib-module `ext/` | dae3eb4c (2022-02-08) | GPL-3.0 |
| knatterfunker/codecserver-softmbe `ext/` | 66397fcf (2021-12-14) | GPL-3.0-or-later (debian/copyright) |
| szechyjs/mbelib `ext/mbelib` | 9a04ed5c (2019-05-28), v1.3.0 | ISC-style permissive (COPYRIGHT) + "PATENT NOTICE" in README |
| jketterl/csdr-plus / pycsdr | csdr-plus local, pycsdr 041986e5 | GPL-3.0 |

OpenWebRX+ installs the software vocoder with `luarvique/owrx_docs/install-softmbe.sh`
(fetched 2026-10-09): it builds szechyjs/mbelib and knatterfunker/codecserver-softmbe and adds
`[device:softmbe] driver=softmbe` to codecserver.conf **[verified]**. Feature
`digital_voice_digiham` requires `digiham` + `codecserver_ambe` (owrx/feature.py:84); without an
AMBE-capable codecserver, OpenWebRX+ hides DMR entirely **[verified]**.

## 2. Upstream chain, taps and rates **[verified]**

Mode: `AnalogMode("dmr", "DMR", bandpass=Bandpass(-6250, 6250), squelch=False)` (owrx/modes.py:146).
Chain `csdr/chain/digiham.py` class `Dmr(DigihamChain, SlotFilterChain)`:

```
selector: shift + decimate to fixed IF 48000 complex S/s, bandpass ±6250 Hz, NO squelch
  -> FmDemod (csdr, float, atan2 discriminator)
  -> DcBlock (csdr)
  -> WideRrcFilter (digiham, 81 taps, mkshape -r 6e-02 2.0e-01 81, gain 8.3378)
  -> GfskDemodulator(samplesPerSymbol=10)        => 4800 symbols/s, dibit symbols 0..3
  -> DmrDecoder (digiham)                         => 27-byte voice payloads + metadata
  -> MbeSynthesizer(Modes.DmrMode = TableMode(33), codecserver socket)  => int16 8000 Hz
  -> DigitalVoiceFilter (5th-order Butterworth band-pass 200–3400 Hz @ 8 kHz, gain 1/5)
  -> Agc(Format.SHORT, maxGain 30, initialGain 3)
  -> fixed audio rate 8000 Hz -> client Converter: AudioResampler(8000 -> client rate, libsamplerate SINC_MEDIUM)
```
`getFixedIfSampleRate()=48000`, `getFixedAudioRate()=8000`, `supportsSquelch()=False`.
NXDN/D-Star use NarrowRrc/FskDemodulator; not in scope.

GFSK demodulator details (src/gfsk_demodulator): per symbol, average samples in the middle third
[sps/3, 2sps/3); decision thresholds from min/max of a 100-symbol volume ring:
center=(max+min)/2, umid/lmid = center ± 0.625·(max/min−center). Output: `1` above umid, `0`
(center..umid], `2` [lmid..center], `3` below lmid. Clock recovery: every 100 symbols, pick the
sample phase with minimum variance and slip ±1 sample. No AFC; DcBlock handles offset.

## 3. DMR decoder behaviour (digiham src/dmr_decoder) **[verified]**

- Frame = 144 symbols: CACH 12 + payload 54 + SYNC 24 + payload 54. Sync offset 66.
- SyncPhase: slide symbol by symbol until BS/MS data or voice sync matches with Hamming distance ≤3
  over 24 dibits (tables in dmr_phase.hpp). Both BS and MS syncs accepted.
- Slot tracking: CACH/TACT (Hamming 7,4) gives the slot; `slotStability` hysteresis (0..100).
  Slots otherwise alternate. Switching resets the other slot.
- Sync counters cap at 5; global `syncCount<0` returns to SyncPhase and resets all meta.
- Voice superframe: frame A has voice sync, B–F carry EMB (QR 16,7) + embedded LC fragments,
  LCSS start/continue/stop collected by `EmbeddedCollector` (Hamming 16,11 + 5-bit checksum).
- Data bursts: SlotType Golay(20,8); BPTC(196,96) for VOICE_LC header, TERMINATOR_LC/IDLE soft reset.
  Rate 3/4 data and data headers are **not decoded**. Voice LC header RS(12,9) is a TODO upstream
  (`Lc::parseFromVoiceHeader` does not check it).
- LC opcodes handled: 0 group, 3 unit-to-unit, 4–7 talker alias (header + 3 blocks), 8 GPS.
  Others are logged to stderr and ignored. FLCO PF bit / service options are not inspected.
- Slot filter: bitmask, 1=TS1, 2=TS2, 3=both (default 3). Only one slot outputs voice at a time
  (`activeSlot`); the first voice slot wins until it drops. Changing the filter clears the active slot.
- Voice output: 27 bytes per voice burst = 108 dibits = 3 × 72-bit AMBE frames, **still
  interleaved** (2 × 54 dibits concatenated around the sync). 6 bursts/superframe, 360 ms.
- Color code: parsed by `Emb::getColorCode()` and `SlotType::getColorCode()` but **never used,
  never filtered, never emitted**.

### Metadata emitted (dmr_meta.cpp, serialized by pydigiham PickleSerializer)
Per-slot dict, sent only when dirty:
`protocol:"DMR"`, `slot:"0"|"1"`, `sync:"voice"|"data"` (absent when no sync),
`type:"group"|"direct"`, `source`, `target` (decimal strings, absent when 0),
`talkeralias` (string), `lat`/`lon` (string floats). A full reset sends both slots without sync.
OpenWebRX+ `DmrEnricher` adds `additional` from radioid.net lookups (network, out of scope) and
derives a callsign from talker alias regex `^([A-Z0-9]+)(\s.*)?$`.

**Not provided upstream** (implementations must not invent them): color code, encryption/privacy
flag, call duration, call history, BER/RSSI, emergency/priority flags, data-call contents.
Feasible native additions (documented deviations): color code (already parsed), PI/privacy from
FLCO/service-options bits, duration from voice-sync timestamps. Encryption is only *indicated*,
never decrypted.

### Frontend (htdocs/lib/MetaPanel.js, openwebrx.js) **[verified]**
Two `DmrMetaSlot` cards. Card shows ID = radioid callsign || talkeralias || source, name,
group/direct icon, target, map pin when lat/lon + callsign. Card is `active` only while
`sync=="voice"`; `sync` class while any sync; otherwise cleared. Clicking a timeslot card toggles
`muted`, recomputing the slot-filter bitmask sent as `dmr_filter`. No call history, no CC filter.

## 4. Vocoder: mbelib path **[verified]**

codecserver-softmbe `decode_ambe_3600x2450()` (what OpenWebRX+ installs):
9 bytes -> 72 bits MSB-first -> deinterleave with `dmr_interleave_permutation[72]` ->
`ambe_fr[4][24]` (c0 24, c1 23, c2 11, c3 14 bits) ->
`mbe_processAmbe3600x2450Frame(short out[160], …, uvquality=3)` -> 160 int16 @ 8 kHz per 20 ms.
State `mbe_parms cur/prev/prev_enhanced` per session, reset by `mbe_initMbeParms`.
fventuri's module is equivalent with a configurable `unvoiced_quality`.
mbelib is ~5 C files (mbelib.c, ambe3600x2450.c, ecc.c + consts), C99, libm only; no I/O
except `printf` on bad uvquality. It builds trivially with the NDK and host CMake.

## 5. Licensing and patents

- License compatibility **[verified]**: digiham, csdr, codecserver modules are GPL-3.0(+);
  mbelib is ISC-style permissive, compatible with this GPL-3.0 app. No license blocker.
- mbelib README "PATENT NOTICE": educational description; compiled objects "may be covered by one
  or more patents" **[verified]**. codecserver-softmbe README says the same, authors anonymous;
  jketterl removed in-tree mbelib from OpenWebRX in June 2021 at his employer's request **[verified
  as stated in that README; underlying announcement not re-checked]**.
- US 8,359,197 B2 "Half-rate vocoder" (DVSI, Hardwick), filed 2003-04-01, granted 2013-01-22,
  Google Patents status **Active, adjusted expiration 2028-05-20**; 12th-year maintenance fee paid
  2024-10-02. Independent decoding claims 42, 60, 72 cover extracting/decoding Golay-protected
  pitch/voicing/gain codewords and synthesizing speech **[verified: patents.google.com/patent/US8359197B2]**.
- US 8,595,002 B2 (continuation): **Expired – Fee Related** **[verified: patents.google.com/patent/US8595002B2]**.
- EP 1 465 158 B1 (same family): **Expired – Lifetime, 2024-03-26** **[verified: patents.google.com/patent/EP1465158B1]**.
  Family also had CA/DE/AT/JP members; their individual status was not checked **[unverified]**,
  but 20-year terms from 2004 filings ended in 2024 **[unverified]**.
- US 8,036,886 (pulsed parameter estimation) active to 2029-10-02 but claims encoder-side
  analysis only; a decoder does not practice it **[secondary: rcludwick.github.io/how-ambe-works/16-patents; claims not read]**.
- That DMR "AMBE+2" equals the claimed 3600 bps half-rate frame (72 bits, 49 voice bits,
  Golay 24/12 + 23/12) is community consensus, not a legal finding **[unverified]**.
- No known Kazakhstan/EAEU counterpart was found **[unverified; not searched in KZ/EAPO registries]**.

**Shipping decision (not legal advice):** nothing prevents shipping under GPL-3.0. Residual risk is
a US patent (to 2028-05-20) for builds distributed/used in the US. Plan: vendor mbelib unmodified
under `native/third_party/mbelib-<commit>/` behind CMake option `SDRCORE_ENABLE_MBELIB` (default ON
for personal Linux/Android builds) with the upstream PATENT NOTICE kept and repeated in
the README/About. With the option OFF the DMR decoder still syncs and emits metadata and reports
`voice: unavailable`; it never fabricates audio. Maintainers may flip the
default for US distribution.

## 6. Android/Linux build feasibility

- digiham DMR/GFSK/RRC/DigitalVoiceFilter: plain C/C++17 with **csdr** Module/Reader/Writer base
  classes and **ICU uc** (only `lib/charset.cpp` for talker-alias ISO-8859/UTF-16 decoding).
  Port plan: vendor the DMR/FEC/EC table files unmodified where possible and replace the csdr
  ring buffers with a thin adapter (`Reader/Writer` over std::vector) — no csdr library build.
- ICU: the installed NDK sysroot has no `unicode/ucnv.h` **[verified]** (minSdk 26).
  Replace `Charset::convertToUtf8` with a small native converter for the four TA formats
  (7-bit, ISO-8859-1, UTF-8, UTF-16BE). Documented deviation.
- codecserver + protobuf + unix socket: **not used**. In-process call to mbelib replaces the
  socket (task forbids subprocesses). `MbeSynthesizer` socket thread is not ported.
- mbelib: C99, libm; host + NDK OK.
- CPU: 48 kS/s complex FIR + 81-tap real RRC + GFSK + 50 AMBE frames/s is negligible next to the
  existing receiver.

## 7. Native interfaces for the parallel ports (decisions)

All in `native/src/dmr/` (new), namespace `sdrcore::dmr`, called only on the DSP worker.
No tuner control, no subprocess, no PCM/IQ through Dart.

1. **Channel samples (filter + 4FSK input).** Registered as decoder id `dmr`, `Input::baseband`
   (the existing ~250 kS/s complex VFO-centred tap used by rtl_433), `required_mode`
   UINT32_MAX, `exclusive_receiver=false`. The backend owns: ±6250 Hz low-pass (complex), rational
   resampler to exactly **48000 complex S/s**, then FmDemod (atan2 of conj product, scaled like
   csdr), DcBlock, WideRrcFilter, GfskDemodulator(sps 10).
   `struct ChannelBlock { const std::complex<float>* iq; size_t n; }  // 48 kS/s`
2. **Symbols.** `void SymbolSink::on_symbols(const uint8_t* dibits, size_t n)`; values 0..3 in
   digiham encoding (§2), 4800/s. Test vectors: the four 24-symbol sync words.
3. **Frames / metadata.**
   `struct AmbeFrame { uint8_t slot; uint8_t bits[9]; }` — one 72-bit frame, still interleaved,
   MSB-first, exactly as digiham emits (27-byte burst split into 3). Delivered in order to
   `VoiceSink::on_ambe(const AmbeFrame&)`.
   `struct SlotMeta { uint8_t slot; int sync /*-1,1 data,2 voice*/; int type /*-1,group,direct*/;
   uint32_t source, target; uint8_t color_code /*0xFF unknown*/; bool privacy; std::string alias;
   std::optional<std::pair<double,double>> latlon; }` — emitted on change.
   Config JSON (`sdr_decoder_select` config, schema `"dmr/1"`):
   `{"schema":"dmr/1","slot_filter":3,"color_code":-1,"voice":true}`; `slot_filter` 1/2/3 as
   upstream; `color_code` -1 = off (deviation: upstream has no CC filter).
4. **Events to Dart.** `Result::message`, JSON payload ≤ 64 KiB:
   `{"schema":"dmr/1","protocol":"DMR","slot":0,"sync":"voice","type":"group","source":2620001,
   "target":91,"talkeralias":"…","lat":…,"lon":…,"color_code":1,"privacy":false,
   "voice":"ok|unavailable|muted"}` — upstream keys keep upstream names; numbers are JSON
   numbers; absent keys mean "not decoded", never placeholders. Call history and duration are
   computed in Dart from event timestamps (sequence + wall clock), clearly labelled.
5. **Voice PCM.** `VoiceSink` → mbelib (uvquality 3) → int16 160 @ 8 kHz →
   DigitalVoiceFilter → Agc(maxGain 30, initial 3) → float. Required contract extension in
   `decoder.hpp` (additive, commit before parallel work): 
   `virtual bool provides_audio() const { return false; }` and
   `virtual size_t read_audio(float* mono, size_t max_frames) { return 0; }` producing 48 kHz mono
   (8 k→48 k ×6 polyphase interpolation in the backend). When an audio-providing decoder is
   attached, the receiver replaces (not mixes) its demod audio with `read_audio` output before the
   existing volume/mute stage and AudioSink (AAudio/Linux), feeding silence on underrun. No C ABI
   change needed; `sdrcore_decoder_v1.h` stays at revision 1.

## 8. Remaining gaps / not verified
- Channel filtering is now a self-contained `ChannelFilter` with an explicit
  48–300 kS/s complex baseband input and exact 48 kS/s complex IF output;
  `RrcPulseFilter` exposes 48 kS/s real in/out and the original digiham
  Wide (DMR, 81 taps) and Narrow (NXDN, 161 taps) tables. The original
  channel frontend delegates to both rather than duplicating their state.
  Synthetic tone/stream-boundary and coefficient-parity tests pass at 48k,
  240k, 250k, 288k and 300k baseband rates. The custom native selector
  remains a documented approximation of OpenWebRX+'s FFT selector; a
  same-recording oracle comparison is not yet available.
- No over-the-air DMR test yet; no local DMR IQ recording found. Implementations need a capture
  (Blog V4 on the Linux host) or a synthetic vector generated from the sync/EMB tables.
- Full talker-alias charset cases, nonzero GPS and embedded LC checksum failure
  remain unverified; zero-coordinate/ISO-8859-1/four-fragment paths are tested in section 9.
- Legal status outside US/EP not checked; this is not legal advice.

## 9. Framing port

The GPL-3.0 digiham DMR phase, metadata, LC, CACH, EMB, slot-type, GPS,
talker-alias and FEC sources are compiled as `sdrcore_dmr_framing` from
`native/third_party/digiham_dmr/upstream/` (pinned provenance and local delta in
`native/third_party/digiham_dmr/PROVENANCE.md`). `native/src/dmr/framing.hpp`
exposes streaming 4800-symbol/s dibits to `Framing::on_symbols`, per-slot
`SlotMeta` callbacks and three 9-byte interleaved AMBE frames per accepted
voice burst. The adapter has no second tuner, subprocess, IQ/PCM FFI or audio
sink. `reset()` clears partial bursts, reinitializes digiham and sends no-sync
for both slots. Digiham's first active voice slot wins unless the slot mask
mutes it; optional CC filtering withholds metadata and voice until EMB/slot-type
CC is known. TS1 is slot 0, TS2 is slot 1. Group `target` is the talkgroup;
unit-to-unit `target` is the destination radio ID. Privacy means PI header or
the voice LC service-options privacy bit; the payload is never decrypted.
`duration_ms` counts observed voice frames in 30-ms increments, not wall time.

Host synthetic tests cover four BS/MS sync words at the three-bit-error limit,
rejection above that limit, alternating CACH slot tracking, voice slot selection,
CC filtering, symbol-stream chunk boundaries, AMBE dibit packing, reset,
Hamming/QR/BPTC correction, LC group/direct IDs and privacy, zero-coordinate
GPS, an ISO-8859-1 talker alias and four-fragment embedded LC. The native
target and tests also compile for Android arm64 API 26. No matching DMR air
capture, full BPTC LC over a burst, RS(12,9) verification, or codec PCM
comparison has been exercised here; that end-to-end oracle
check is still open. The demodulator/receiver registration, vocoder and UI are
separate pieces of work; DMR cannot be selected as a live decoder yet.

## 10. Flutter controls and call display

Dart side only; it consumes the §7.3 config and §7.4 events and never
touches IQ or PCM.

- **Catalog.** `dmr` sits in the one decoder list after the v3 demod rows
  (`lib/ui/decoders/decoder_contract.dart`): `voice: true`, `demodMode: null`,
  `input: baseband`. Session logic separates demod rows by `demodMode`, so
  selecting DMR never calls `setMode` and never retunes. Settings and their
  allowed values: `slot_filter` 1/2/3 (default 3), `color_code` -1..15
  (default -1 = off), `voice` true/false. They are stored and restored via
  `decoderId`/`decoderSettings` presets like the other decoders.
- **Config to native.** `DecoderBackend.select('dmr', {"schema":"dmr/1",
  "slot_filter":…, "color_code":…, "voice":…})` is the flat object from
  §7.3, not the `{version, settings}` envelope. Any setting change
  reselects, so the native decoder restarts with the new filter. Values
  outside the allowed set are rejected before they reach native code.
- **Readiness.** DMR uses the same 200–300 kS/s baseband branch as
  rtl_433. Below that rate the panel shows the existing not-ready reason. If
  the native registry lacks `dmr`, which is true today because §9
  registration is not done, the panel says it is unavailable and every
  control is disabled.
- **Events.** Only payloads with `schema=="dmr/1"`, `protocol=="DMR"` and an
  integer `slot` of 0 or 1 are accepted. Upstream keys are kept as-is.
  Missing keys stay null and are never shown as placeholders.
- **Slot cards (OpenWebRX+ `DmrMetaSlot`).** There is one card each for TS1
  and TS2. Each shows sync (voice/data/none), call type (group/direct),
  talkgroup or destination ID, source ID, colour code, an encrypted badge
  when `privacy==true` (indication only), talker alias and GPS. A card
  shows a live call only while `sync=="voice"`. As upstream does, tapping a
  card toggles that slot in the `slot_filter` bitmask. The UI will not mute
  both slots, and a muted slot is labelled "Disabled".
- **Call lifecycle.** A call is identified by slot + source + target + type.
  Alias, GPS, privacy and `duration_ms` persist for the rest of that call,
  because they arrive in separate LC blocks. A call ends and moves to
  history when the source, target or type changes, sync leaves voice, the
  slot gets no event for `dmrCallTimeout` (3 s), or the stream generation
  changes. Retune, rate change, VFO offset change and stop clear the slot
  cards and the history. A filter change clears only the live slot cards,
  not finished calls.
- **History.** It is session-local, newest first, bounded to 100 entries,
  and can be cleared. It shows duration from native `duration_ms` (voice
  frames × 30 ms) when present; otherwise it shows the Dart event span,
  labelled "event-driven".
- **Not implemented, shown honestly.** radioid.net ID lookup, callsign
  enrichment and the map pin need network access, and the panel states
  that lookup is unsupported. The panel has no volume control: DMR voice
  uses the normal audio volume and mute once AMBE PCM is routed
  into the native sink. The `voice` key in events (`ok|muted|unavailable`)
  is displayed when present.
- **Tests.** `test/ui/dmr_session_test.dart` (8) and `test/ui/dmr_panel_test.dart`
  (6) cover config propagation and rejection, both slots, call close and
  history bound, clear on retune/generation/stop, silent-slot expiry,
  history retained across a filter change, metadata persistence within a
  call, malformed/foreign events, the unavailable state, and the slot-tap
  mask at 344 dp and 690 dp. A mutation check confirmed that removing
  history retention, generation clear or expiry fails the matching test.
- **Not verified.** No native `dmr` backend is registered on master, so no
  real event has gone through `NativeDecoderBackend`. Live RTL-SDR/air and
  Android hardware checks have not been done.

## 11. AMBE+2 voice output

`native/src/dmr/vocoder.{hpp,cpp}` (target `sdrcore_dmr_voice`, linked into
libsdrcore) reproduces OpenWebRX+'s DmrMode voice path in process:
codecserver-softmbe `decode_ambe_3600x2450` (DMR deinterleave, mbelib
`mbe_processAmbe3600x2450Frame`, uvquality 3, 160 int16 @ 8 kHz) ->
digiham-plus `DigitalVoiceFilter` -> csdr-plus `Agc<short>` (maxGain 30,
initialGain 3) -> x6 polyphase interpolation to 48 kHz -> bounded jitter
buffer (100 ms prebuffer, 1 s cap). mbelib 1.3.0 (ISC), Agc and
DigitalVoiceFilter are vendored unmodified (`native/third_party/mbelib`,
`native/third_party/openwebrx-dmr`, provenance files there). There is no
codecserver process, socket, protobuf, or Dart PCM path.

Receiver integration: `Decoder::provides_audio()/read_audio()` (additive
`decoder.hpp` extension, C ABI unchanged). When the attached decoder provides
audio, `receiver.cpp` replaces each block's demodulator output with exactly as
many 48 kHz decoder samples. It applies the normal `volume^2`/mute stage,
skips the squelch gate (upstream `supportsSquelch() = False`), and fills
underruns with silence. The result goes to the existing AudioSink (AAudio on
Android, ALSA/WAV on Linux). `sdrcore.cpp` exempts attached voice decoders
from the mute-while-decoding rule for baseband decoders.

Framing connection: `AmbeFrame` is shared via `native/src/dmr/ambe_frame.hpp`.
`framing_voice_sink(VoiceOutput&)` adapts the `VoiceSink` to `Framing`'s
callback. The `sdrcore_dmr_framing_voice` CTest feeds digiham bursts through
Framing into VoiceOutput and gets PCM bit-identical to direct synthesis of the
same frames.

Build option `SDRCORE_ENABLE_MBELIB` (default ON). OFF leaves mbelib out
completely (no `mbe_*` symbols in libsdrcore). Frames are counted as dropped
and no PCM is produced, while framing and metadata keep working.

Verified: `sdrcore_dmr_vocoder`, `sdrcore_dmr_framing_voice`,
`sdrcore_decoder_voice_replace`, `sdrcore_decoder_voice_abi` (DSP worker into
a real `wav:` sink), all also under ASan+UBSan; the OFF build;
`tool/dmr_voice_oracle` bit-exact against pristine codecserver-softmbe +
mbelib + DigitalVoiceFilter + `csdr agc` on synthetic frames.

Not verified / remaining: no open AMBE+2 speech encoder exists, so all test
frames are synthetic parameter vectors (vocoder buzz, not speech). No
over-the-air DMR voice was decoded. Audibility is unconfirmed;
it still requires manual listening. The DMR backend (registry entry, 4FSK channel,
events, `{"voice":false}` mapping) still has to own one
`VoiceOutput` and return `provides_audio() == true`. That wiring is part of
the backend integration. Once the backend is registered, the UI from
§10 needs no volume control of its own.

## 12. Single-receiver channel input stage

`native/src/dmr/channel_tap.{hpp,cpp}` adds `ChannelDecoder`, an abstract
native `Decoder` base with a `SymbolSink`. It accepts interleaved CF32 and
the actual complex sample rate from the receiver's existing `Input::baseband`
VFO branch; a bounded `ChannelTap` copies samples into `Channel` without
aliasing float objects as complex objects. The receiver supplies integer
native decimation and invokes `reset()` on attach, stream restart, rate
change, VFO move and retune. These boundaries reset the 48 kS/s IF, Wide
RRC and GFSK(10) state. Neither the source sample rate nor tuner center is
changed for DMR. The channel retains its ±6250 Hz filter and no-squelch
behavior. This class remains abstract until the backend integration card
attaches `Framing`/`VoiceOutput`, implements configuration/events and
registers the `dmr` factory; the app still shows DMR as unavailable.

`sdrcore_dmr_channel_tap` sends synthetic CU8 through the real receiver
at 2.4, 2.5 and 2.88 MS/s device rates (240, 250 and 240 kS/s taps), plus
576 kS/s (288 kS/s tap). In each 200 ms window it checks 9600–9601 IF
samples and >900 dibits with manual squelch closed and audio muted. It also
checks deterministic reset/replay, detach, rate propagation, VFO changes
and retune. Direct filter and symbol-decision tests are separate; the
downstream oracle card owns reference fixture parity. Live DMR RF reception
and voice output remain unverified.

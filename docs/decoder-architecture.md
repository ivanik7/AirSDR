# Decoder architecture (native contract and UI)

SSTV source audit and the shared native/UI line-event contract are in
[`docs/status/sstv-audit.md`](status/sstv-audit.md). It documents the mapped
csdr-plus VIS list (including disabled AVT-90 and a required PD 290 fix), the
24 kHz audio boundary, source licenses/FFTW build gap, and the bounded
progress/completion schema.
This is a design handoff, not an SSTV implementation or availability claim.
The native backend (vendored csdr-plus `SstvDecoder`, adapter, 24 kHz
receiver audio tap) is described with its verification in
[`docs/status/sstv.md`](status/sstv.md); the Dart UI (live picture, gallery,
saving, underlying demod) is in [`docs/status/sstv-ui.md`](status/sstv-ui.md).

Status: `rtl_433` is an in-process upstream engine on the single native
receiver's tuned complex-IQ branch. `sstv` uses its 24 kHz USB/LSB/NFM audio
tap, and `adsb` uses the tuned 2.4 MS/s IQ tap and embedded dump1090 core.
The v1 decoder extension sends only bounded low-rate JSON events to Dart.

## One decoder list (UI contract)

The Decoder tab and the preset editor show ONE flat list,
`decoderCatalog`: NFM, WFM, AM, USB, LSB, DSB, CW, RAW, then DMR, SSTV,
rtl_433, ADS-B and any later data decoder. There is no generic "Audio"
entry and no second mode picker.

- Demodulator rows have stable IDs `demod:<DemodMode.id>` (`demod:0` NFM,
  `demod:1` WFM, `demod:2` AM, `demod:3` DSB, `demod:4` USB, `demod:5` CW,
  `demod:6` LSB, `demod:7` RAW), built by `decoderIdForMode`. They are
  adapters over the existing native v3 demodulator (`sdr_v3_set_mode`):
  `DecoderDescriptor.demodMode` is set, `voice` is true, and selecting one
  calls `CenteredReceiver.changeMode` (one retune, recentered VFO). They are
  always available because v3 implements them; they never go through the
  optional decoder extension and have no decoder factory.
- `dmr` is a voice mode in the same list but not a v3 demodulator:
  `voice` is true and `demodMode` is null. It is a native decoder-extension
  engine on the baseband tap (docs/status/dmr.md §7, §10, §14); session code tells
  demod rows apart by `demodMode != null`, never by `voice`. Its AMBE audio
  replaces demod audio natively via the existing sink; Dart only shows metadata.
- Data rows (`sstv`, `rtl_433`, `adsb`) are optional native decoder
  extension engines. Their availability comes only from
  `DecoderBackend.availableIds`; `rtl_433` is listed when the native
  library is loaded, but attaches only when the source rate supports a
  200–300 kS/s branch. Otherwise its panel reports a not-ready reason.
- `DecoderSession.selectedId` follows external mode changes (Receive tab,
  bands, channels) while a demodulator row is selected; while a data row is
  selected it stays put, so another surface cannot silently replace the
  preview.

The native decoder C ABI (`sdrcore_decoder_v1.h`) lists
only data engines and never claimed demodulators were unavailable, so
there is no need to duplicate v3 modes there. The "voice vs data" split is
an internal implementation detail of the descriptor.

## Why a separate preview layer for data decoders

The receiver (`RadioController`) is the single source of truth for the one
real VFO/audio stream (see `AGENTS.md` UI invariants). Decoders are an
*additive* feature: a user should be able to look at every catalog entry's
settings UI — even ones no native backend currently implements — without
ever affecting live reception. `DecoderSession` exists precisely to keep
"what the user is looking at in the Decoder tab" separate from "what the
radio is actually doing".

Three invariants are enforced in `lib/ui/decoders/decoder_session.dart` and
covered by `test/ui/decoder_session_test.dart`:

1. **Preview never retunes or restarts the radio.** Choosing `rtl_433` attaches
   to the running VFO without changing frequency, mode, or source rate;
   native audio is silent until a voice row is selected. Unavailable data
   entries remain passive previews.
2. **Backend `availableIds` is the only truth for availability.** An id is
   only ever handed to `DecoderBackend.select` if the backend currently
   reports it in `availableIds`, the radio is running in a compatible mode,
   and the decoder does not require exclusive access. A decoder catalog entry that exists in
   `decoder_contract.dart` but isn't reported by the backend can be
   *previewed* (its settings panel is visible) but can never be *started*.
3. **No fake events.** `rtl_433` polls the oldest native event after its
   sequence cursor. Its 500-row UI log is session-local, newest first.
   Native FIFO capacity is 256; overflow drops the oldest and increments
   `dropped_events`. Stop, deselect, retune and generation changes invalidate
   old events. No raw IQ/PCM crosses FFI.

## Native rtl_433 path

The DSP worker branches from the receiver's existing CU8 input, applies the
same tuned-VFO frequency shift and a low-pass FIR integer decimator, then
passes interleaved complex floats at the integer rate nearest 250 kS/s to
vendored upstream `rtl_433` (`native/third_party/rtl_433/PROVENANCE.md`).
The tuner remains at its user-selected rate; for an unsuitable rate the
decoder is not ready rather than changing the source. The embedded upstream
`r_flow`/protocol registry produces JSON with its native field names and
relative sample time. The branch does not receive the actual RF frequency,
so it deliberately omits synthetic `freq`/`freq1`/`freq2` fields; signal
levels are retained. `{"version":1,"settings":{}}` is the only supported
configuration; frequency belongs to the normal radio/preset, not settings.

`native/tests/rtl433_oracle.py` compares sensor fields against the pinned
upstream CLI on external recordings. `--tap` additionally replays 250 kS/s
CU8 recordings with zero-order interpolation into the tuned 2.5 MS/s branch;
the FIR can change marginal pulse detection, so its match rate is separately
reported. Neither oracle subprocess is part of the app runtime.

## ADS-B input and native snapshot backend

`docs/adsb-snapshot-v1.md` fixes the tuned, undecimated 2.4 MS/s complex-IQ
tap (with a native converter for feasible higher rates), SC16 boundary and
bounded aircraft snapshot fields.
The DSP tap feeds the embedded FlightAware dump1090 core through a 2.4 MS/s
SC16 magnitude converter. `native/src/decoder/adsb.cpp` uses upstream
demodulation, CRC/CPR/Comm-B and track state, and emits a bounded snapshot
about once per second; `adsb` is now available in the native registry. See
`docs/status/adsb-backend.md` and `docs/status/adsb-oracle.md` for the verified boundary
and generated-IQ comparison. `lib/ui/decoders/adsb_panel.dart` displays the
live bounded snapshot, not raw frames. Host RF yielded no aircraft in a
30-second check; this does not establish live reception.

## Meshtastic (LoRa) path

`meshtastic` uses an exact 1 MS/s complex-f32 tap of the tuned VFO (FIR
decimation plus a fractional resampler, `docs/status/meshtastic-mode.md`).
It feeds OE5DXL's author-site lorarx, the demodulator OpenWebRX+ runs,
embedded without IO (`docs/status/meshtastic-phy.md`), started with the
OpenWebRX+ `MeshtasticDemodulator` argv. Each lorarx JSON line goes to the
native `MeshtasticParser` port, which does the header, firmware key/hash
rules, AES-CTR and nanopb decoding (`docs/status/meshtastic.md`). The result
is one `message` event per packet. Voice audio is zero-filled while the
decoder is selected. Dart shows the packet log, text messages, node list
and channel keys (`docs/status/meshtastic-ui.md`). Region quick-tune
buttons (EU_868, US, RU, KZ_863) call `CenteredReceiver.tune`.
Same-IQ parity with lorarx plus the OpenWebRX+ parser is
`docs/status/meshtastic-parity.md`. The host live-air check, CPU numbers
and the Kazakhstan regions are in `docs/status/meshtastic-live.md`. No
packet has yet been received over the air.

## Pieces

- `lib/ui/decoders/decoder_contract.dart` — shared Dart contract
  (catalog, settings schema, `DecoderBackend` interface). Change it together
  with the versioned native descriptor and persistence migrations.
- `lib/ui/decoders/decoder_session.dart` — `DecoderSession`, a
  `ChangeNotifier` constructed once per shell (`LegacyAppShell`), wrapping a
  `RadioController`. Holds the current preview id and per-decoder settings
  (defaulted/validated against `DecoderSetting.allowed`) and the live log.
- `lib/ui/decoders/decoder_panels.dart` — `DecoderSelector` (one scrollable
  dropdown over `decoderCatalog`, data rows marked "Unavailable" unless the
  backend reports them) and the selected-only panels:
  `VoiceDecoderPanel` (bandwidth/squelch/demod options such as WFM stereo),
  live `Rtl433DecoderPanel`, `AdsbPanel` (in `adsb_panel.dart`),
  `SstvDecoderPanel` (in `sstv_panel.dart`), and previews for unavailable decoders.
- `lib/ui/legacy/decoder_screen.dart` — the Decoder tab: selector + exactly
  one panel for `session.selectedId` (selected-only, not all panels stacked).
- `lib/ui/radio_controller.dart` — `RadioController.decoderBackend` getter,
  default `null`; `NativeRadioController` exposes the optional native adapter.
  `lib/main.dart` probes the additive extension without changing v3 requirements.
- `native/include/sdrcore_decoder_v1.h` and `decoder.hpp` define a separate
  versioned C ABI and native C++ processing interface. `native/src/decoder/`
  exposes the in-process `rtl_433`, SSTV and ADS-B factories.
- `lib/ui/favorites/favorites.dart` — storage v3: `Favorite.decoderId` +
  `Favorite.decoderSettings`, with migration/normalization on load (see
  below).
- Wiring: `lib/ui/channels/channel_controller.dart` (`saveAsPreset` accepts
  optional `decoderId`/`decoderSettings`), `lib/ui/legacy/channels_section.dart`
  and `lib/ui/legacy/presets_screen.dart` (both take an optional
  `decoderSession` and carry the current preview into a new preset /
  restore a stored preview when a preset is applied).
  Preset editing can change the selected decoder while retaining options
  when the ID is unchanged. A channel's preview is saved only for the active,
  tuned channel; inactive tiles do not inherit unrelated preview settings.

## Favorites storage versions

`FavoritesRepository.storageVersion = 3`. All versions share one JSON
document under `storageKey`; `version`-gated loading means every save still
round-trips on its *next* load even if it predates decoders:

| version | shape |
|---|---|
| 1 | 12-slot archive built-ins (`builtin-<index>`) always present |
| 2 | adds `seenDefaults`; built-ins are a small fixed list, offered once |
| 3 | adds, per entry: `decoderId` (string), `decoderSettingsVersion` (int, = `FavoritesRepository.decoderSettingsSchemaVersion`), `decoderSettings` (map) |

Normalization on load, in order — a preset is **never dropped** because of
anything decoder-related, only its decoder attachment is cleared:

- v1/v2 entries (no `decoderId` key at all) and the obsolete literal
  `'voice'` load with `decoderId: null`; the list shows them as the
  demodulator row of their stored `mode` (`Favorite.decoderChoice`).
- `decoderId: 'demod:<n>'` is an explicit demodulator choice; the loader
  and `add`/`edit` force `mode` to match it, so ID and mode cannot
  contradict. A data decoder ID keeps its own underlying `mode`.
  Applying a preset retunes to its frequency/mode, then calls
  `DecoderSession.applyStored(decoderId, settings, mode: mode)`, which
  selects that row and attaches `rtl_433` on a running receiver, without a
  separate tuner handoff.
- `decoderId` present but not in `decoderCatalog` (removed/renamed/future
  decoder) → cleared to `null`.
- `decoderSettingsVersion` present but not equal to
  `decoderSettingsSchemaVersion` → cleared to `null` (the settings *shape*
  changed underneath an old save; don't guess).
- `decoderSettings` present but missing/invalid individual keys → each key
  resolves independently to the decoder's declared default
  (`DecoderSetting.defaultValue`); unknown keys are dropped.

Writing always stamps the *current* `decoderSettingsSchemaVersion`, so
round-tripping through this app never downgrades a save.

### Copy isolation

`Favorite.decoderSettings` is a fresh `Map` per instance — `copyWith`,
`add`, and the loader's normalization step all build a new map rather than
reusing a caller- or another-favorite's map. Two presets attached to the
same decoder (e.g. two `rtl_433` presets on different ISM frequencies) can
never alias each other's settings. See
`test/ui/favorites_decoder_test.dart` ("copy isolation").

## Adding a new decoder (recipe)

1. Add a data `DecoderDescriptor` after the demodulator rows in
   `decoder_contract.dart`'s `decoderCatalog` and a matching native
   registry descriptor (`native/src/decoder/registry.cpp`); it appears in
   the same single list automatically. Give it a stable `id`
   (never reused/renamed later — storage normalization keys on it), its
   `DecoderInput`/`DecoderResult`, and any `DecoderSetting`s with an
   `allowed` list if the value space should be restricted.
2. If the decoder needs a bespoke empty-state panel instead of the generic
   `DecoderPlaceholderPanel`, add an entry to `_placeholderMeta` in
   `decoder_panels.dart` (icon, title, empty-state text) — or, for
   genuinely different layout needs, add a new panel widget and branch on
   `descriptor.id` in `decoder_screen.dart`.
3. No other wiring is required for *preview*: `DecoderSelector` iterates
   `decoderCatalog` automatically; `DecoderSession.settingsFor`/`setSetting`
   /`applyStored` are generic over `DecoderSetting`; favorites
   normalization (`_normalizeDecoderSettings`) is generic too.
4. When a real native backend is implemented, wire a single instance to the
   existing handle's DSP input and bounded event queue, enforce required mode
   and sample rate inside the native lifecycle, then report availability.
   Full-band decoders require a safe receiver integration before availability;
   ADS-B now has one. Add real output polling/UI
   before claiming a working decoder. Versioned configuration sent over FFI
   has `{"version":1,"settings":{...}}`; favorites store the same settings
   under the selected ID with `decoderSettingsVersion`.
5. Add/extend tests: `test/ui/decoder_session_test.dart` (session-level
   behaviour), `test/ui/decoder_screen_test.dart` (panel UI, including a
   344dp-width fit/no-overflow case — the Fold cover-screen reference
   width used elsewhere in this app, see `AGENTS.md`), and
   `test/ui/favorites_decoder_test.dart` (storage round trip/migration);
   `test/ui/unified_decoder_selection_test.dart` covers the one-list rules.

A new demodulator is a v3 `DemodMode` change (C ABI task), not a catalog
edit: its row is generated from `DemodMode` order in `decoderCatalog`.

## Known limitations (by design, today)

- **rtl_433, SSTV and ADS-B have selectable data-decoder output.** Implicit WFM RDS
  metadata is active alongside audio. SSTV pictures
  are assembled in Dart from bounded per-row events (`lib/ui/decoders/
  sstv_image.dart`); voice audio keeps playing.
- **No Start/Stop control.** Decoder lifecycle (when a backend exists) is
  expected to be driven by `DecoderBackend.select` as a side effect of
  `DecoderSession.selectPreview`/`applyStored`, not a separate user action —
  there is deliberately no "Start" button to avoid implying a live run that
  isn't backed by anything.
- **The ADS-B backend requires a usable 2.4 MS/s IQ window.** It shares the
  existing tuned receiver; a slower rate or displaced VFO shows not ready.
  rtl_433 is likewise non-exclusive and consumes tuned channel baseband.
- **One shell-scoped session, not per-favorite live state.** `DecoderSession`
  belongs to the shell (`LegacyAppShell`), not to an individual favorite or
  channel. Applying a favorite/channel updates the *shared* session's
  preview; it is not possible to preview two different decoders
  simultaneously in one shell instance (matches the "one real receive
  channel" UI invariant).
- **Settings UI is generic except for bespoke panels.** Placeholder panels
  render each setting as a dropdown of `DecoderSetting.allowed` values.
  SSTV has its own panel (`sstv_panel.dart`): the `underlying` setting
  (`usb|lsb|nfm`) is a segmented control that switches the receiver through
  the normal mode control (`DecoderDescriptor.underlyingModes`), and `mode`
  allows only `auto` because upstream has no forced picture mode.
- **Live-air decoding is unverified.** A host RTL-SDR Blog V4 streamed ADS-B
  at 1090 MHz / 2.4 MS/s, but no aircraft were decoded during the 30-second
  measurement (see `docs/status/adsb.md`). Neither synthetic IQ nor a running tuner
  establishes antenna/analog RF reception or behaviour on real Android hardware.

## WFM RDS integration contract (implemented; validation in docs/status/rds.md)

This section supersedes the earlier RDS/SDR++ suggestion. The implementation target is the
OpenWebRX+ **redsea** chain, not a newly written or simplified RDS decoder.
RDS is implicit in `demod:1` WFM, never a new catalog entry or a selectable
`Decoder` instance. It must not mute/stall the existing stereo audio, change
the tuner rate, claim USB separately, or move the VFO.

### Verified upstream chain and rate boundary

At OpenWebRX+ commit `f1e0d1a`:

1. `csdr/chain/analog.py:45-106` constructs `FmDemod -> Limit ->
   FractionalDecimator(FLOAT, 200000 / audioOutputRate, prefilter=True) ->
   WfmDeemphasis(audioOutputRate, tau)`. `_connect` inserts a FLOAT
   `metaTapBuffer` **immediately after Limit**, before that fractional
   decimator and deemphasis. Therefore the RDS tap is at the *fixed 200 kS/s
   IF*, not at the lower audio output rate. `getFixedIfSampleRate()` returns
   200000. `setMetaWriter` activates the parallel chain only if the `rds`
   feature is available; `stop` stops it. Changing RBDS stops and recreates
   that chain. This is metadata alongside WFM audio, not a separate mode.
2. `csdr/chain/toolbox.py:104-123`: `RdsDemodulator(200000, rbds)` converts
   the tapped FLOAT MPX to SHORT and feeds `RedseaModule` then `RdsParser`;
   its independent 171000 default is *not* the rate chosen by `WFm`.
   `csdr/module/toolbox.py:79-84` actually launches
   `redsea --input mpx --samplerate 200000` plus `--rbds` when requested.
   No `--bler`, `--show-partial`, `--streams`, or `--timestamp` flag is set.
   The input is raw signed 16-bit mono PCM and redsea emits line-delimited
   JSON groups. `owrx/config/defaults.py:22-23` defaults RBDS to false;
   `owrx/controllers/settings/decoding.py:64-67` exposes the North-American
   checkbox, routed through `owrx/dsp.py:563,610`.
3. redsea `src/constants.hh:22-36` requires MPX at **at least 128 kS/s**;
   `src/dsp/subcarrier.cc:95-108,155-218` resamples to 171 kS/s internally.
   It mixes 57 kHz to baseband, low-passes at 2.4 kHz, decimates by 24
   (7.125 kS/s), uses a liquid-dsp RRC symbol synchronizer (2.375 ksym/s),
   PSK phase tracking, biphase pairing and differential decoding to 1187.5
   bit/s. Retain its actual PLL/timing/filtering and multi-group FEC, not
   only the high-level RDS message tables. Default: one RDS1 data stream;
   RDS2 streams require `--streams` and are **not** enabled upstream here.
4. `src/redsea.cc:152-175` feeds a `SubcarrierSet` into a `Channel`, resetting
   subcarrier acquisition/PI after >10 s without block sync (if >5 s since
   prior reset). `src/channel.hh:36-79` confirms a changed PI after three
   consecutive copies; `src/channel.cc:149-168` then creates a fresh Station.
   `src/block_sync.cc` owns 26-bit block synchronization, syndrome/FEC and
   error thresholds. Do not equate a fleeting PI bit error with a new station.

The app's MPX is `value` in `native/src/dsp/receiver.cpp:647-697`, after the
tuned complex-IQ channel FIR/decimation and FM discriminator, but **before**
the 19 kHz pilot stereo branch, 48 kHz audio resampling, deemphasis, squelch,
mute and volume. `if_rate_` is derived from source rate/bandwidth in
`receiver.cpp:181-204`, not fixed at 200 kS/s; the default WFM bandwidth is
150 kHz (`lib/ui/radio_controller.dart:144`). Feed the same mono MPX to a
native RDS-only rate converter targeting 200 kS/s, then let redsea perform
its own 200k -> 171k resampling. **Do not** feed 48 kHz PCM, or assume
`if_rate_` is always above 128 kS/s. The existing channel filter cutoff is
`bandwidth_hz / 2`; for narrow WFM settings excluding the 57 kHz subcarrier,
report no RDS signal/unsupported bandwidth rather than widening or retuning
the user's channel. Compare the two discriminator scales and FLOAT->SHORT
conversion on recorded MPX before asserting oracle parity. Preserve stereo
output unchanged; process RDS only when WFM is active.

### redsea output and OpenWebRX+ accumulation

`src/options.hh:30-56` and `src/station.cc:85-208,216-345,418-509,577-655`
define the default JSON group output. `pi` is a hex string such as `0x1234`;
`group` is the current group ID (not persistent station metadata). `tp` is a
bool; `prog_type` is a **name**, not an integer PTY. RBDS changes the PTY
table and adds `callsign` or `callsign_uncertain` derived from PI (an uncertain
name must not be presented as verified). `ps` is emitted after segment
assembly; `radiotext` after completion/terminator or a repeat-confirmed
nonterminated message; A/B changes clear the redsea RadioText assembly
(`station.cc:458-509`). `ta`, `is_music` and nested `di` flags (including
`di.stereo`, which is *broadcast metadata*, not actual audio pilot lock)
come from group 0. `alt_frequencies_a` is an integer list in **kHz**;
`alt_frequencies_b` has `tuned_frequency`, `same_programme`,
`regional_variants`, also kHz (`station.cc:261-325`, `util/util.cc:79-103,
131-188`). `country` comes from the ECC/PI mapping; `clock_time` is a
formatted timestamp. Additional decoded keys can include
`prog_item_number`/`prog_item_started`, `radiotext_plus` (nested tags),
`pty_name`, `other_network` (EON), `tmc`, `rft`, etc. Keep the underlying
decoder's semantics even when the compact UI does not display every field.

Default `--input mpx --samplerate 200000 [--rbds]` does **not** emit `bler`
(`--bler` is opt-in, averaged over 12 groups), `partial_ps`/
`partial_radiotext`/`partial_alt_frequencies` (`--show-partial`), or an
explicit `sync` field. An Android BLER/sync indicator is an intentional
extension: enable redsea's existing `Options.bler` for a real BLER measurement
and derive sync from its actual block-sync state / fresh valid-group clock;
never invent values or treat `di.stereo` as sync. For strict upstream oracle
comparison disable that extension or exclude only the additional fields.

`owrx/toolbox.py:88-119::RdsParser`: decode each JSON line, remove `group`,
reset to `{mode: 'WFM', frequency: previousFrequency?}` when
`data.get('pi') != cached.get('pi')`, and return no update if incoming
`data.items() <= cached.items()`; otherwise merge the sparse group delta
and return the accumulated map. This includes the literal behavior that a
group *without* `pi` may clear a previously set PI. `setDialFrequency`
unconditionally resets to `{mode:'WFM',frequency: Hz}`. Model our normal
valid-group flow as sparse updates; do not replace the full state with each
group; the upstream `dict.update` is **shallow** (a new `di` object replaces
the previous one, not a deep merge). If the detail UI wants all four DI bits,
accumulate them separately as a documented UI extension rather than claiming
this is upstream parser behavior. Reset on confirmed PI change. If a no-PI
group is forwarded, preserve the parser's literal comparison behavior rather
than silently assigning the old PI.
`htdocs/lib/MetaPanel.js:372-557` shows PS (or RT+ long name), PI/callsign,
PTY, RadioText (RT+ preferred) and local-format CT; it clears on PI change
and after **10 seconds without RDS updates**. The upstream web panel does
not itself display AF/BLER/TP/TA. Our requested detail panel extends it,
but should retain the same partial-field/timeout honesty. Previewing other
data decoders must not produce fake RDS or keep stale WFM metadata visible.

### Source/Android dependency inventory and decision

redsea commit `7555c9f6259d50718697ee8c9f218ea012c6892c`, version 1.3.1
(`meson.build:1-12`). Use its actual sources in `native/third_party/redsea/`
with pinned provenance, `LICENSE` and each original copyright header:

- Keep `src/block_sync.{cc,hh}`, `channel.{cc,hh}`, `group.{cc,hh}`,
  `station.{cc,hh}`, `tables.{cc,hh}`, `rft.{cc,hh}`,
  `text/{rdsstring.cc,rdsstring.hh,radiotext.hh}`,
  `util/{util.cc,util.hh,tree.hh,maybe.hh,csv.cc,csv.hh,base64.hh}`,
  `constants.hh`, `options.hh`, `io/bitbuffer.hh`, `io/output.{cc,hh}`;
  retain `tmc/{tmc.cc,tmc.hh,message.cc,message.hh,eventdb.cc,eventdb.hh,
  events_data.cc,locationdb.cc,locationdb.hh}` if retaining Station's full
  TMC/RDS2/RT+ behavior. `station.hh` depends on `tmc.hh` and `rft.hh`, so
  leaving out TMC is **not** a link-only choice; explicitly gate functionality
  and account for fidelity loss if trimming. Keep
  `dsp/{subcarrier.cc,subcarrier.hh,liquid_wrappers.cc,liquid_wrappers.hh}`
  for the same DSP behavior. `src/redsea.cc`, `options.cc`, `io/input.cc`
  are CLI/arg parsing/file I/O and should not ship in the app. Adapt the
  `MPXBuffer` type out of `io/input.hh`, which currently includes `<sndfile.h>`;
  this is the required small source edit to avoid shipping libsndfile.
- `io/output.cc` uses nlohmann `ordered_json` for upstream-compatible JSON;
  vendor the >=3.9 header/source under its own MIT license, or provide an
  equivalent verified serializer. `text/rdsstring.cc` uses iconvpp/iconv for
  UCS-2 enhanced RDS text **in addition** to its built-in RDS G0 table;
  those tables alone do not guarantee full text parity. Android's Bionic
  iconv availability must be checked by an actual NDK build; replace only
  the UCS-2 -> UTF-8 conversion with a tested native conversion if needed.
  `tmc/locationdb.cc` uses iconv as well if location tables are shipped.
- `meson.build:37-116` declares libsndfile, nlohmann_json, iconv and
  liquid-dsp. The first is file-only; the second is JSON output; iconv is
  enhanced text/TMC locations; liquid is used **at runtime** for AGC, FIR,
  NCO/PLL, RRC symbol sync, PSK modem and rational resampler. Implemented:
  redsea 1.3.1, liquid-dsp 1.6.0 and nlohmann/json 3.11.3 are vendored and
  built from source for host and Android (`native/third_party/RDS-PROVENANCE.md`);
  validation results are in `docs/status/rds.md`. Replacing those DSP blocks with
  homegrown code is *not* automatically more faithful or smaller; only
  select that fallback after a documented, measured build/license obstacle
  and same-MPX oracle comparison. Preserve upstream 57 kHz recovery first.

The repository root `LICENSE` is MIT-form; many redsea `src/*.cc` headers use
the different permissive ISC-style text. Preserve **both** notices, rather
than calling every source file MIT. liquid-dsp is MIT/X11 (upstream
`https://liquidsdr.org/license/`); nlohmann/json is MIT. Check the precise
revision and licenses of every newly vendored dependency, including iconvpp,
before release. The resulting app remains GPL-3.0-or-later; no copyleft
conflict is evident from these permissive licenses. An unverified Android
build is not proof of feasibility.

### Low-rate native -> Dart event schema and lifecycle (v1 proposal)

Reuse `SdrDecoderEvent` (`native/include/sdrcore_decoder_v1.h:14-69`):
`kind=SDR_DECODER_MESSAGE`, UTF-8 JSON <=64 KiB, FIFO <=256, monotonically
increasing `sequence`, stamped `stream_generation`, `dropped_events` counter.
Do **not** call `sdr_decoder_select("rds")`: the existing receiver owns at
most one selected data decoder (`native/src/sdrcore.cpp:988-1040`), and its
consumer currently mutes audio whenever a data decoder is selected
(`sdrcore.cpp:440-463`). Instead add a dedicated internal WFM metadata sink
fed by MPX and enqueue its output into the existing per-handle FIFO; enable
polling even with no selected data decoder. RDS and selectable data decoder
events must never be confused. Existing `rtl_433` payloads remain untouched.

Schema: `{"source":"rds","version":1,"event":"state",` followed by
`"frequency_hz":<integer>,"rbds":<bool>,"fields":{...}}`. `fields` is a
bounded **accumulated snapshot** of redsea's canonical JSON keys (without
`group`), including `pi`, `ps`, `radiotext`, `prog_type`, `tp`, `ta`,
`is_music`, nested `di`, `alt_frequencies_a`/`alt_frequencies_b` in kHz,
`country`, `clock_time`, `callsign`/`callsign_uncertain`, and optionally
`radiotext_plus`, `other_network`, etc. Absent keys mean unknown, not false
or empty. `"sync":<bool>` and optional `"bler":<number>` are top-level
adapter observations (BLER only when measured), not purported default
redsea keys. Separate `{"source":"rds","version":1,"event":"reset",` with
`"frequency_hz":...,"rbds":...,"reason":"retune|mode|generation|pi|rbds|signal_lost"}`
has **no `fields`**. The first subsequent state contains only data obtained
on the new station. Reset must not be coalesced away or hidden by change
rate limiting. Invalid/oversized nested output is dropped and counted,
never truncated into misleading partial JSON.

Emit a snapshot on actual change; cap non-reset updates (e.g. <=4/s), while
preserving the latest complete snapshot across a throttle interval. Emit a
reset immediately when tuned dial frequency changes (including small steps
or drag), before new groups; also on WFM exit, stream start/stop or new
generation, RBDS toggle and confirmed PI switch. LO recenter with unchanged
effective dial frequency need not clear station metadata, but if the DSP
resampler is restarted then reacquire sync without replaying old results.
On 10 s without valid decoded data, emit `signal_lost` and clear visible
fields, matching the OpenWebRX+ panel timeout. Controls can be accepted
asynchronously relative to USB: drop queued old-tune groups and never publish
MPX from `slot_stale` or while `tune_in_progress()`; stamp only coherent
post-tune groups. Dart clears proactively on requested tune/mode changes and
on generation mismatch, discards events whose generation/frequency does not
match applied state, and applies `reset` before any later state. Sequence
cursors must advance across resets; do not reset the global sequence to zero.
As the FIFO currently clears on deselect/retune and drains only when a data
decoder is attached, the native child must update **both** drain/invalidating
paths; keep rtl_433's existing selection and FIFO semantics intact. WFM
settings storage: `rbds` defaults false, belongs to WFM (`demod:1`) preset
settings and changes in place without tuner or stereo interruption. Define a
small additive native control method for it rather than changing v3 structs.

Oracle for the children: replay **identical** saved post-discriminator MPX
into the embedded branch and `redsea --input mpx --samplerate 200000
[--rbds]` (same quantization, same record window). Compare group JSON
before our event coalescing, excluding only explicitly added BLER/sync keys;
also test native block/FEC and PI/PS/RT A/B reset against redsea's included
`test/resources/mpx-testfile-yksi.flac` and `rds2-minirds-192k.flac` after
license-safe decoding. Check no WFM stereo underruns, rate/bandwidth gating,
generation/tune resets, Android arm64 linkage and size. Results of these
checks are recorded in `docs/status/rds.md`.

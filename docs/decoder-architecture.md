# Decoder architecture (native contract and UI)

Status: `rtl_433` is an in-process upstream engine on the single native
receiver's tuned complex-IQ branch. `sstv` and `adsb` remain unavailable.
The v1 decoder extension sends only bounded low-rate JSON events to Dart.

## One decoder list (UI contract)

The Decoder tab and the preset editor show ONE flat list,
`decoderCatalog`: NFM, WFM, AM, USB, LSB, DSB, CW, RAW, then SSTV,
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

## Pieces

- `lib/ui/decoders/decoder_contract.dart` — shared Dart contract
  (catalog, settings schema, `DecoderBackend` interface). Change it together
  with the versioned native descriptor and persistence migrations.
- `lib/ui/decoders/decoder_session.dart` — `DecoderSession`, a
  `ChangeNotifier` constructed once per shell (`LegacyAppShell`), wrapping a
  `RadioController`. Holds the current preview id and per-decoder settings
  (defaulted/validated against `DecoderSetting.allowed`) and the live log.
- `lib/ui/decoders/decoder_panels.dart` — `DecoderSelector` (one scrollable
  dropdown over `decoderCatalog`, data rows marked "Недоступен" unless the
  backend reports them) and the selected-only panels:
  `VoiceDecoderPanel` (bandwidth/squelch/demod options such as WFM stereo),
  live `Rtl433DecoderPanel`, and previews for unavailable decoders.
- `lib/ui/legacy/decoder_screen.dart` — the Decoder tab: selector + exactly
  one panel for `session.selectedId` (selected-only, not all panels stacked).
- `lib/ui/radio_controller.dart` — `RadioController.decoderBackend` getter,
  default `null`; `NativeRadioController` exposes the optional native adapter.
  `lib/main.dart` probes the additive extension without changing v3 requirements.
- `native/include/sdrcore_decoder_v1.h` and `decoder.hpp` define a separate
  versioned C ABI and native C++ processing interface. `native/src/decoder/`
  exposes the in-process `rtl_433` factory and unavailable future entries.
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
   Full-band decoders remain preview-only until a safe receiver integration
   is designed. Add real output polling/UI
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

- **Only rtl_433 has real decode output.** SSTV and ADS-B are preview-only.
- **No Start/Stop control.** Decoder lifecycle (when a backend exists) is
  expected to be driven by `DecoderBackend.select` as a side effect of
  `DecoderSession.selectPreview`/`applyStored`, not a separate user action —
  there is deliberately no "Start" button to avoid implying a live run that
  isn't backed by anything.
- **Full-band decoders are preview-only.** ADS-B has no backend. rtl_433 is
  explicitly non-exclusive and consumes the tuned channel baseband.
- **One shell-scoped session, not per-favorite live state.** `DecoderSession`
  belongs to the shell (`LegacyAppShell`), not to an individual favorite or
  channel. Applying a favorite/channel updates the *shared* session's
  preview; it is not possible to preview two different decoders
  simultaneously in one shell instance (matches the "one real receive
  channel" UI invariant).
- **Settings UI is generic, not decoder-tailored.** The remaining SSTV `mode`
  setting renders as a dropdown of
  `DecoderSetting.allowed` values. A decoder needing a different control
  (free-text, slider, etc.) will need a bespoke branch in
  `decoder_panels.dart`, not just a new `decoderCatalog` entry.
- **No device-visible receiver acceptance in this task.** The host did not
  enumerate a Blog V4 during the final checks. Native/Flutter/Linux host
  gates are reported separately in the task handoff; subjective Android audio
  quality and phone screen appearance are not inferred from host tests.

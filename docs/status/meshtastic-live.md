# Meshtastic: live-air check on the Linux host and Kazakhstan regions

This report covers the root Meshtastic card (t_afd3e5ae), branch
`feat/meshtastic-live-check`. The PHY, packet layer, receiver tap, UI and
OpenWebRX+ parity were delivered by the child cards, see
`docs/status/meshtastic.md`, `meshtastic-mode.md`, `meshtastic-phy.md`,
`meshtastic-ui.md` and `meshtastic-parity.md`. This change closes the
remaining gaps the children could not: the RTL-SDR Blog V4 is now attached to
the host (`lsusb`: `0bda:2838`, "RTLSDRBlog, Blog V4"), so the live-air
receive path and its host CPU cost could be measured.

## Result

No Meshtastic packet was received on air. The host antenna setup, location
and on-air activity are unknown to this run, and no transmitter (Heltec or
other) was keyed. This is a negative observation, not a decoder failure: the
same chain decodes every supported preset on identical IQ with the upstream
lorarx + OpenWebRX+ parser (`meshtastic-parity.md`).

## What was run

### 1. App receive path on real hardware

`sdrcore_host_meshtastic_live` (new, `native/tests/host_meshtastic_live.c`,
manual tool, not a CTest) drives the same C ABI the app uses: one v3
session, normal tuned controls with `vfo_offset 0` (centre == tuned),
2.4 MS/s, gain 40.0 dB, then `sdr_decoder_select("meshtastic")` on the
running handle and FIFO polling. It prints every `message` event and
periodic stats; the config is never printed.

| Tuned | Region / preset | Duration | Messages | IQ ring drops | Native errors |
|---|---|---|---|---|---|
| 869.075 MHz | RU / LongFast | 412 s | 0 | 0 | none |
| 866.875 MHz | KZ_863 / LongFast | 600 s | 0 | 0 | none |
| 869.525 MHz | EU_868 / LongFast | 25 s (smoke) | 0 | 0 | none |

Input rate stayed at 2.399 MS/s. `audio_nonsilent_frames` was 0 while the
decoder was selected (voice silent as specified) and 2,880,279 in the
no-decoder baseline below.

### 2. Offline survey with the upstream oracle

Raw 2.4 MS/s `rtl_sdr` captures (same Blog V4, 40 dB) were shifted and
resampled to 1 MS/s cf32 and passed to the unmodified upstream `lorarx`
(oracle build of the vendored source) with the exact OpenWebRX+
`MeshtasticDemodulator` argv plus `-s 12`, for bandwidth indices 8, 7 and 6
(250 / 125 / 62.5 kHz):

- 600 s centred at 869.2 MHz, decoded at 869.075 (RU LongFast slot),
  869.525 (EU_868 LongFast) and 868.125 MHz.
- 120 s centred at 866.875 MHz (KZ_863 LongFast slot).
- 120 s centred at 869.2 MHz, decoded at 869.075 and 868.1 MHz.

Across all runs lorarx reported no frame with `crc:1`. It did report a few
hundred header-level detections per run, mostly with an implausible sync word,
SNR at the per-SF squelch floor (about −13 dB at SF7), and either `crc:0` or
no CRC. The ones with `net:43` (Meshtastic sync word, 19 in the 600 s survey)
all have `crc` 0 or −1, so they are noise-triggered detections, not packets.
Both the OpenWebRX+ parser and the native backend drop them (`crc < 1`),
which matches the zero native messages in part 1.

Spectrum survey (4096-pt FFT, 0.1 s rows) of the same captures showed
bursts near 868.0–868.2 MHz and a broadband event at t≈106 s. None of them
decoded as LoRa with a valid CRC under any of the bandwidths tried. They were
not identified further.

### 3. CPU on the Linux host

Process CPU (`clock()`) of the live tool over 60 s at 2.4 MS/s, 866.875 MHz,
Release build, null audio sink. The number covers the USB, DSP, decoder and
polling threads:

| Session | Process CPU / 60 s |
|---|---|
| NFM voice, no decoder | 6.02 s (≈10 % of one core) |
| Meshtastic selected | 16.22 s (≈27 % of one core) |

The Meshtastic tap plus embedded lorarx (five SF demodulators at 250 kHz)
therefore costs about 10 CPU-s per 60 s, i.e. ≈17 % of one Ryzen 7 5700G core,
on top of the receiver. The 412 s RU run used 119.9 CPU-s (≈29 %).
Android CPU is still not measured.

## Kazakhstan regions

Meshtastic firmware v2.8.1 (`src/mesh/RadioInterface.cpp` at tag
`v2.8.1.8e6a88d`, fetched from GitHub raw this run) defines

    RDEF(KZ_433, 433.075f, 434.775f, 100, 10, false, false, PROFILE_STD, PRESET(LONG_FAST), 0)
    RDEF(KZ_863, 863.0f,   868.0f,   100, 30, false, false, PROFILE_STD, PRESET(LONG_FAST), 0)

with firmware issue #7204 as the reference. Both regions were missing from
the Dart region table and are now added, `PROFILE_STD`, with no spacing,
padding or override slot. The existing firmware slot formula gives, for
LongFast:

- KZ_863: 20 slots, djb2("LongFast") % 20 + 1 = slot 16, **866.875 MHz**.
- KZ_433: 7 slots, slot 6, **434.450 MHz**.

Neither centre is in the OpenWebRX+ band table, so both are labelled
**Unverified frequency**, like RU 869.075 MHz. A `KZ_863` quick-tune button
sits next to EU_868 / US / RU and uses the normal `CenteredReceiver.tune`
path. `KZ_433` and `KZ_863` are accepted `region` setting values, so presets
round-trip. The native backend ignores `region` (Dart quick-tune only), so
the C ABI and the native config are unchanged.

Tests (RED first):

- `test/ui/meshtastic_tuning_test.dart`: KZ_863/KZ_433 bounds, slot and
  centre, unverified flag, PROFILE_STD preset list.
- `test/ui/meshtastic_panel_test.dart`: the KZ_863 quick tune at 344 dp is
  labelled unverified, tunes to 866.875 MHz, keeps centre == tuned and offset
  0, and throws no layout exception.
- `test/ui/meshtastic_mode_panel_test.dart`: now expects exactly two
  unverified quick-tune labels (RU, KZ_863).

## Reproduce

```sh
cmake -S native -B build/mesh-live -DCMAKE_BUILD_TYPE=Release
cmake --build build/mesh-live -j3 --target sdrcore_host_meshtastic_live lorarx_oracle
build/mesh-live/sdrcore_host_meshtastic_live --seconds 600 --freq 866875000 --region KZ_863
build/mesh-live/sdrcore_host_meshtastic_live --seconds 60 --freq 866875000 --decoder none
```

## Not verified

- Reception of a real Meshtastic packet over the air. No node was heard in
  about 17 minutes of live listening plus about 14 minutes of offline survey
  across RU, EU_868 and KZ_863. A keyed transmitter, such as Ivan's Heltec
  LoRa32 on a known preset, is needed for a positive live check.
- Desktop UI with live packets: without packets the Linux panel would show
  only an empty log. No new Linux screenshot was taken. Panel layout is
  covered by widget tests and the earlier emulator run.
- KZ_433 / KZ_863 centres against an independent published source (firmware
  source only).
- Android CPU and on-device decoding (no USB SDR on the emulator; phones are
  not used).
- The Blog V4 driver prints `rtlsdr_demod_write_reg failed with -9` at
  close, as noted in `docs/status/adsb.md`. Streaming counters were clean.

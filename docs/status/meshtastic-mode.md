# Meshtastic receiver mode

This card added the single-receiver mode contract. The `meshtastic` registry
descriptor is a 1,000,000 complex-S/s baseband tap, independent of voice
demodulation, with message events. Its factory is the embedded lorarx PHY
(`docs/status/meshtastic-phy.md`), so the descriptor reports `available=1`.
Selecting a non-audio decoder uses the existing worker's audio zero-fill policy.

## Tuned IQ path

`Receiver::set_decoder(decoder, Input::baseband, 1000000)` requests the exact
rate. The worker mixes the *normal tuned VFO* (LO + offset) to zero without
claiming another USB device or changing the source sample rate, then applies an
integer low-pass FIR decimator and, if required (e.g. 2.4→1.2→1 MS/s), a
streaming symmetric 48-tap/128-phase fractional FIR converter. The tap is idle
unless selected. The 1 MS/s window must fit around the tuned VFO in the source
band; a source below 1 MS/s, or an offset with less than ±500 kHz available,
returns rate zero / not-ready. Existing rtl_433 200–300 kS/s and ADS-B 2.4 MS/s
branches are unchanged. Attach/detach, retune, rate and stream resets clear
the new converter and squelch state. The native C ABI did not change.

On manual squelch, the 1 MS/s complex stream uses mean squared magnitude
sampled at 1/5 rate over 62,500 IQ frames, with a 125,000-frame hang and a
312,500-frame zero flush, then stops feeding until the signal returns. Level
is the existing manual dB threshold converted as 10^(dB/10). Off passes IQ.
Auto voice squelch derives metrics after voice demod and cannot correctly gate
LoRa IQ; it is intentionally not applied here (auto passes IQ). This differs
from a user-configured OpenWebRX+ IQ squelch threshold and needs a dedicated
IQ auto-threshold if wanted. No packet metadata is manufactured by the tap.

## Presets, region slots and limits

`lib/ui/decoders/meshtastic_tuning.dart` transcribes v2.8.1 firmware
`MeshRadio.h::modemPresetToParams` (SF/BW/CR, including MediumSlow and
ShortFast at **250 kHz**). `RadioInterface.cpp::regions` and
`applyModemConfig` provide the receive-only region ranges, spacing, padding,
slot override and djb2 channel-name hash. Default LongFast EU_868 869.525 MHz
and US 906.875 MHz are also in the OpenWebRX+ bands. RU 869.075 MHz is
calculated from the firmware but not independently checked against the Meshtastic
published documentation, so its quick-tune button says **Unverified frequency**.
Other model-computed region/preset frequencies carry the same unverified flag.
Quick tunes for EU_868, US and RU call `CenteredReceiver.tune` (device range,
step snapping, band selection and recenter); the UI reports a snapped value
rather than claiming the exact firmware center if the grid changes it.

The UI enumerates full firmware PHY tuples but does not silently replace them.
The OpenWebRX+ lorarx invocation searches only SF7–SF11: LongSlow/SF12 is
explicitly unsupported. Tiny 15.6 kHz is not configured by the current chain;
2.4 GHz `wideLora` variants are outside the RTL-SDR Blog V4 tuning range, and
an 1,625 kHz-wide signal also exceeds the 1 MS/s branch. A source <1 MS/s
or insufficient VFO window is not ready; 500 kHz bandwidth *is* within the
1 MS/s branch's 450 kHz one-sided low-pass cutoff. Regional legality is not
inferred from a receive-only frequency list. Region/preset settings are
catalogued for preset persistence but the preview does not present them as a
working decoder control before the backend/UI cards land.

Sources: OpenWebRX+ `owrx/modes.py`, `csdr/chain/{selector,lora}.py` at
f1e0d1ac7dfa; Meshtastic firmware v2.8.1 `src/mesh/RadioInterface.cpp`,
`src/mesh/MeshRadio.h` at 8e6a88d0. See `docs/lora-upstream-feasibility.md`
and `docs/status/meshtastic.md` for the separate packet layer.

## Checks and gaps

- Native `sdrcore_meshtastic_tap` exercises DC translation, 2.4/2/1.024/1
  MS/s inputs, below-rate and edge-window rejection, manual squelch/hang/flush,
  and retune. `sdrcore_decoder_abi` checks the descriptor (`available=1`).
- Flutter model tests check firmware tuples, region hashes/slots and explicit
  rate limits; panel widget test exercises quick-tune at 344 dp.
- The PHY/backend and its evidence are in `docs/status/meshtastic-phy.md`.
  Still open: native sample-stream oracle against a running OpenWebRX+,
  CPU measurement at 1 MS/s on Android, and over-the-air reception evidence.

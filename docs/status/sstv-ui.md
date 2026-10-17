# SSTV UI status (live picture, gallery, saving, settings)

Native backend: `docs/status/sstv.md`. Event contract and
upstream audit: `docs/status/sstv-audit.md`.

## What is in the tree

- `lib/ui/decoders/sstv_image.dart` — `SstvReceiver` assembles pictures
  from the frozen v1 events (`start`, `line`, `image_complete`) that come
  from the existing `sdr_decoder_poll` FIFO. No second format was added.
  - `start` is validated before a frame opens: source/version, decimal
    `frame_id`, VIS mapped to the 24 audited modes with exact name and
    dimensions, UTC timestamp, `underlying` in usb/lsb/nfm, and
    `frequency_hz` equal to the receiver's current tuned frequency. A start
    stamped with another frequency is stale (pre-retune) and is ignored.
  - Rows must arrive in order with exactly `width*3` BGR bytes. A gap, a
    malformed row or FIFO overflow (`droppedEvents` growth) closes the
    frame `partial/lost`. Rows are never drawn out of order and are never
    interpolated.
  - `image_complete` is `complete` only if `status=complete`, `reason=end`,
    the counts match what Dart received and every row is present. Anything
    else is `partial` with the native or UI reason.
  - Retune, sample-rate restart, mode change, stop, stream-generation
    change and deselect close an open frame `partial` with that reason.
    Rows already received are kept and shown as partial.
  - A frame with zero rows is not added to the gallery. The panel shows the
    reason instead (for example a Scottie start-sync timeout).
  - The gallery holds at most 8 frames, newest first, and lasts for this
    app session. The worst case is about 16 MB RGBA (8 × PD-290). Clearing
    the gallery or disposing the session frees it.
- `lib/ui/decoders/sstv_panel.dart` — the SSTV panel in the Decoder tab:
  - Status line: waiting for VIS / receiving <mode> / not ready (with the
    needed demod) / stopped / unavailable. Also shows frequency, demod,
    24 kHz and lost-event count.
  - A live picture redraws on every row. Rows not yet received are
    transparent. The summary line shows mode, size, rows received/height,
    padded rows, status/reason, UTC time, frequency and demod.
  - Gallery thumbnails, with tap to enlarge (pinch zoom). The dialog has
    "Save PNG", which shows the saved location or the error.
  - Settings:
    - The demod segmented control (USB default, LSB, NFM) switches the one
      receiver through the normal centered mode control, the same path the
      mode selector uses. The decoder then reattaches in that mode.
    - "SSTV mode" offers only "Auto (VIS)". The note explains that
      OpenWebRX+/csdr-plus have no forced mode and lists the supported
      families.
  - Voice audio keeps playing. Native audio-tap decoders do not mute
    (`sdrcore.cpp`), as in OpenWebRX+.
- `lib/ui/decoders/sstv_save.dart` — saving:
  - The PNG is encoded in Dart (RGB, zlib, CRC). It contains only the
    received rows, so a partial picture is never padded out to full height.
  - The file name follows OpenWebRX+ `Storage.makeFileName("SSTV-{0}",
    freq)`: `SSTV-<yyMMdd-HHmmss UTC>-<kHz>.png`. Partial pictures get
    `-partial`. The time is the native capture timestamp.
  - Linux writes to `$XDG_PICTURES_DIR/AirSDR`, falling back to
    `~/Pictures/AirSDR`. Files are created exclusively and get a `-2`, `-3`…
    suffix instead of overwriting.
  - Android uses `MediaStorePlugin.kt` on channel `sdr/media`, through
    `lib/platform/media_store.dart`:
    - API 29+: MediaStore `Pictures/AirSDR` with `IS_PENDING`. No storage
      permission is needed.
    - API 26–28: app-specific external `Pictures/AirSDR`, which is not
      visible in the gallery. Files there are not overwritten either.
  - Sharing is not implemented (optional).
- Catalog/session:
  - `sstv` now declares `underlyingModes` (USB/LSB/NFM) and has no fixed
    `requiredMode`. Settings v1 are `{mode: auto, underlying: usb|lsb|nfm}`,
    exactly as the native adapter's `configure()` accepts.
  - Stored presets with the old `martin_m1`/`scottie_s1` normalize to
    `auto`.
  - When the receiver runs in another supported demod, the stored
    `underlying` follows it. A preset's own mode therefore wins over a
    stale stored choice.

## Verification (the Linux host, 2026-10-11)

| Check | Result |
|---|---|
| `flutter analyze` | No issues |
| `flutter test` (full) | 486 passed, 14 skipped |
| New tests: `test/ui/sstv_model_test.dart` (13), `sstv_session_test.dart` (9), `sstv_panel_test.dart` (3, 344 dp), `test/platform/media_store_test.dart`, plus a legacy-mode normalization test | pass. The session/model tests were RED before the session wiring. The 344 dp panel test caught a real dialog button overflow, which is fixed. |
| `SDRCORE_HOST_LIBRARY=<host build>/libsdrcore.so flutter test test/native/` | 111 passed, 6 skipped |
| `SDR_HW_TEST=1 SDRCORE_V3_PROBE_LIBRARY=… flutter test test/native/sstv_session_hw_test.dart` with the attached RTL-SDR Blog V4 | pass (see below) |
| `flutter build linux --debug`, then 20 s `xvfb-run` launch | built. The app detected the Blog V4 and ran until `timeout` (exit 124). |
| `flutter build apk --debug`; `android/gradlew :app:testDebugUnitTest` | both succeeded |

The hardware session test uses the real FFI library, the Blog V4 and
`DecoderSession` as the Decoder tab drives it, at 14.230 MHz. It covers:

- The native backend accepts the UI's v1 settings.
- USB→LSB through the demod control retunes the mode and reattaches.
- WFM reports "Not ready".
- Choosing USB again reattaches.
- A ±1 kHz retune keeps the decoder attached.

During a 20 s listen it reported `current=- rows=0 gallery=0 dropped=0`.
No SSTV signal was received (no antenna/band activity was checked), so
this proves no live-air decode.

## Not verified / gaps

- Live-air SSTV picture through the UI: NOT DONE. No transmission was
  received during the hardware run. Oracle and pysstv recordings are in
  `docs/status/sstv-oracle.md`.
- No Linux UI screenshot of the SSTV panel. The host has no X screenshot
  tool (`xwd`, `import`, `scrot` and `ffmpeg` are absent), and the
  `flutter screenshot --type=skia` route was not completed. The panel
  layout is covered by widget tests at 344 dp.
- Android MediaStore save on real hardware: unverified. The plugin is built
  into the debug APK and the Dart channel contract is unit-tested; check the
  save flow on the Android emulator.
- No forced picture mode (upstream has none). No sharing.

# Legacy UI migration status

Branch/worktree: `wip/legacy-ui` in `~/prj/wt/legacy-ui`. Implementation commit: `25a697ae3ab1fe840b9373fd5b76c64620eea3ef` (prior feature commits: `deb5426`, `bed2681`, `3b96d64`, `4870d7e`).

## Implemented

- `lib/main.dart` now opens `LegacyAppShell` with three bottom tabs: Приём, Пресеты, Настройки. Near-black/olive-green tokens, large MHz readout, keypad, arrow/drag ruler, single current-channel card, and styled spectrum/waterfall panel adapted from archive layouts. IBM Plex Sans/Mono are bundled locally with their IBM license, not fetched at runtime.
- Preserved the working `RadioController`/`SdrRadioController` device and DSP path. The panel uses existing `SdrUiState`, `SpectrumPainter`, `FrequencyScalePainter`, `WaterfallPainter`, and `WaterfallModel` receiving live `FftRow`s. No legacy SDR engine/USB/audio/DSP/C++ imports. When stopped, live spectrum is obscured and no made-up levels are shown.
- `CenteredReceiver` is the only new UI tuning policy. Keypad OK, arrows, ruler drag, preset apply, every mode switch, and Start use `setTuning(centerFrequency: hz, vfoOffset: 0)`. Shell resets a persisted nonzero offset after `SdrRadioController.ready` and recovers from any later backend offset state. Single VFO/audio channel only; additional channels and scanning are visibly unavailable, with no timers/monitors or phantom levels.
- Favorites repository: exact 12 archive pool entries and categories, first nine enabled by default, deterministic built-in/user IDs, SharedPreferences JSON storage, stable order, toggling built-ins, add arbitrary current frequency with hardware bounds, rename/edit mode/category, delete user entry, duplicate/name/category validation, serialized saves, and async-load/user-action guard. Applying any entry tunes the single current receiver rather than a monitoring slot.
- Settings expose real USB/source settings sheet (Bias-T/PPM etc.), device enumeration, sample rate, gain/AGC, volume, squelch, stats/errors and start/stop. Recording/rtl_tcp/notifications/scanning are labeled unavailable; no fake functional toggles.
- Kept `lib/ui/main_screen.dart` and its widgets. Existing old-screen widget tests now mount `MainScreen` explicitly so their original interactions remain covered despite the new production home.

## Compact Приём (task t_7f55e98d)

Supersedes the ruler/device-bar notes above for the Приём tab.
- The frequency is the topmost element; the device list, Start/Stop and USB retry live in Settings (`legacyDevice`, `legacyRetryUsb`). Auto-connect is unchanged.
- `_FixedFrequencyRow` (`legacyFrequencyField`): one font size per screen width/text scale, sized for 11 monospace characters (keypad entry limit), fixed height; value length, partial entry and mute ↔ «Очистить ввод» do not move anything.
- Mode = one `PopupMenuButton` (`legacyModeSelect`); the step button (`legacyStep`) sits to its right. The tuning ruler and ◀/▶ are gone: retune by horizontal drag on the spectrum/waterfall (one retune + centering on End/Cancel), keypad, presets, channels.
- No vertical scroll: the waterfall takes the remaining height.
- Channels: header «КАНАЛЫ · N» + «+ канал» + «Скан», then ONE horizontal row of fixed-size tiles (`channelsRow`); block height depends only on text scale. No channel limit, no «Все каналы / Свернуть». The active channel (and the scanner's tuned one) scrolls into view; a dragged tile scrolls the row at its edges (36 dp zone).
- Channels have no own names: `ChannelController.displayName` = preset name at exactly the same Hz, else `<mode> <MHz>`; stored names are ignored (old manual names included). Rename was removed. «Сохранить как пресет» asks for a name (prefilled, empty rejected, Отмена = no-op).

## Verification

- `flutter analyze`: **No issues found!**
- `flutter test --reporter compact`: **398 tests passed** at merge; **412** after phone-QA fixes. New tests cover persistence, filtering/add/edit/delete/toggle/validation, tabs/keypad/preset apply, USB/LSB and all demod modes' centered VFO, ruler drag, late offset reset. Existing UI/backend tests remain green.
- `git diff --check`: clean. No changes under `lib/drivers`, `lib/usb`, `lib/sdrpp/dsp`, `lib/sdrpp/signal_path`, `lib/sdrpp/modules`, or `android`.

## Limitations / handoff

- Phone QA was done after the merge to master. See "Phone QA" below.
- The old app uses another Android package; its sandboxed SharedPreferences cannot be read directly. New repository starts with the archived pool; there is no cross-package migration.
- Landscape and the 1812 px inner (unfolded) screen were not checked on the physical handset (the phone stayed folded; inner display was OFF). Widget tests cover 300/344/690 dp widths. Live RF level meters for untuned favorites are intentionally absent.

## Phone QA (2026-09-28, SM-F936B cover display 904×2316 @2.625, RTL-SDR Blog V4, debug APK, `install -r`, data kept)

Screenshots: `~/prj/docs/screens/legacy/qa-*.png` (`qa-00` = bug before the fix). Marker centering was measured by pixel scan of the accent line against the panel edges. In every screenshot below the marker is at x=450–453 px and the panel centre is 451.5 px.

### Bugs found and fixed
1. **Status line overflow** ("RIGHT OVERFLOWED BY 193 PIXELS" while receiving). The stats text was an unconstrained `Text` in a `Row` after a `Spacer`. It is now `Expanded` and single-line with an ellipsis, using the shorter `compactStatsLine` (`2.40 MS/s · USB drops N · audio drops N`). The full stats remain in Settings. Tests: `test/ui/legacy_layout_test.dart` renders all 3 tabs at 344/690/300 dp with 9-digit counters, a long error and a long preset name. With the old layout this test fails with a 643–1033 px overflow.
2. **◀/▶ nudge buttons rendered as orange emoji tiles** on Samsung. Replaced with `Icons.chevron_left/right`.
3. **Preset save error showed a blank reason** ("Не удалось сохранить: " when the name was empty or the frequency was a duplicate). `favoriteErrorText` now maps to Russian reasons, and the stale message clears on the next action.
4. **Edit dialog showed the currently tuned frequency** instead of the preset's own frequency. Fixed.
5. **Demod mode/bandwidth/squelch did not persist across restarts.** `DspEngine` set the `radio_config.json` path, but `RadioModuleFactory.init()` overwrote it with null. The path is now passed via `configPath`. Test: `test/runtime/dsp_engine_config_test.dart`. On the phone, after force-stop the app relaunched in NFM, and `files/radio_config.json` now exists.

### Verified on device (final build)
- Keypad entry + OK: 101.7, 104.0, 145.500, then NFM. The RTL log shows `Tune: 101700000/104000000/145500000`. The axis label under the marker matches the readout.
- All 8 mode chips (WFM/NFM/AM/USB/LSB, plus DSB/CW/RAW reached by horizontal scroll): the BW label updates and the marker stays centred.
- ▶×2 at the 12.5 kHz step gives 145.525. Step cycling works (5/6.25/12.5/25/100 kHz). ◀ at 25 kHz steps back correctly. Ruler drag changes frequency.
- Presets:
  - The FM category filter works.
  - Apply (Симплекс 2м) tunes the single receiver to 145.500 NFM and switches to the Приём tab, with the marker centred.
  - Add current frequency (100.500 "QAtest") works, and so do rename + NFM mode edit ("QA99E" at 99.900) and deleting a user entry.
  - Toggling a built-in (Радио 88.6) works.
  - After `am force-stop` + relaunch: 10 saved, QA99E/NFM still present, 88.6 still off, QAtest still deleted.
- Settings: device, USB sheet (opens), sample rate (disabled while running), AGC, RF gain, volume, squelch, and state Start/Stop all work. Later-only features are shown as unavailable text. The "+ канал · позже" card is inert.
- Start/Stop: cycles from the header and from Settings. After the activity was destroyed with Back, the old session logged `device lost … Stop!`, and a new Start reopened the RTL at 2.4 MS/s without errors.
- Logcat: no Flutter exceptions or overflow errors. The only exceptions are system-side (WindowManager `DeadObjectException` at force-stop, and GMS `Bundle` casts).
- Audio: `dumpsys audio` shows an AAudio playback `u/pid:10329/<app pid> state:started` while receiving. Audibility is left to the user to confirm.
- The app was left running at **106.200 MHz WFM**.

### Remaining
- USB drops are ~100–140 shortly after each start, the same as before this change. Not investigated here.
- Inner-screen/landscape checks were not done on the device.
- No `Semantics`/uiautomator labels were checked (QA used coordinates + screenshots).

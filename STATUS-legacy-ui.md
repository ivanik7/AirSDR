# Legacy UI migration status

Branch/worktree: `wip/legacy-ui` in `~/prj/wt/legacy-ui`.

## Implemented

- `lib/main.dart` now opens `LegacyAppShell` with three bottom tabs: Приём, Пресеты, Настройки. Near-black/olive-green tokens, large MHz readout, keypad, arrow/drag ruler, single current-channel card, and styled spectrum/waterfall panel adapted from archive layouts. IBM Plex Sans/Mono are bundled locally with their IBM license, not fetched at runtime.
- Preserved the working `RadioController`/`SdrRadioController` device and DSP path. The panel uses existing `SdrUiState`, `SpectrumPainter`, `FrequencyScalePainter`, `WaterfallPainter`, and `WaterfallModel` receiving live `FftRow`s. No legacy SDR engine/USB/audio/DSP/C++ imports. When stopped, live spectrum is obscured and no made-up levels are shown.
- `CenteredReceiver` is the only new UI tuning policy. Keypad OK, arrows, ruler drag, preset apply, every mode switch, and Start use `setTuning(centerFrequency: hz, vfoOffset: 0)`. Shell resets a persisted nonzero offset after `SdrRadioController.ready` and recovers from any later backend offset state. Single VFO/audio channel only; additional channels and scanning are visibly unavailable, with no timers/monitors or phantom levels.
- Favorites repository: exact 12 archive pool entries and categories, first nine enabled by default, deterministic built-in/user IDs, SharedPreferences JSON storage, stable order, toggling built-ins, add arbitrary current frequency with hardware bounds, rename/edit mode/category, delete user entry, duplicate/name/category validation, serialized saves, and async-load/user-action guard. Applying any entry tunes the single current receiver rather than a monitoring slot.
- Settings expose real USB/source settings sheet (Bias-T/PPM etc.), device enumeration, sample rate, gain/AGC, volume, squelch, stats/errors and start/stop. Recording/rtl_tcp/notifications/scanning are labeled unavailable; no fake functional toggles.
- Kept `lib/ui/main_screen.dart` and its widgets. Existing old-screen widget tests now mount `MainScreen` explicitly so their original interactions remain covered despite the new production home.

## Verification

- `flutter analyze`: **No issues found!**
- `flutter test --reporter compact`: **398 tests passed**. New tests cover persistence, filtering/add/edit/delete/toggle/validation, tabs/keypad/preset apply, USB/LSB and all demod modes' centered VFO, ruler drag, late offset reset. Existing UI/backend tests remain green.
- `git diff --check`: clean. No changes under `lib/drivers`, `lib/usb`, `lib/sdrpp/dsp`, `lib/sdrpp/signal_path`, `lib/sdrpp/modules`, or `android`.

## Limitations / handoff

- As directed, no APK build/install or phone/RTL Blog V4 QA was performed in this worktree. Parent integrator must build, install without clearing data, verify display/audio and persistence on device, and capture screenshots/logs.
- The old app uses another Android package; its sandboxed SharedPreferences cannot be read directly. New repository starts with the archived pool; there is no cross-package migration.
- Landscape/small-screen fidelity has not been checked on the physical handset. Receive content scrolls vertically where needed. Live RF level meters for untuned favorites are intentionally absent.

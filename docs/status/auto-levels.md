# STATUS — waterfall auto-contrast (t_16c68e1b)

## What was done
- `lib/ui/auto_levels.dart` — the algorithm. Per FFT row: noise floor = 20th percentile of valid bins
  (NaN/−inf and "zeros" ≤ −190 dB discarded), peak = maximum. Rows are aggregated into one-second buckets
  (mean of noise, max of peak), in a 30 s ring (it also expires by time — a background pause does not keep stale data).
  Targets: `min = floor − 5`, `max = max(floor + 25, peak + 3)`. Smoothing: range expansion τ=0.25 s,
  narrowing τ=1.5 s; for 2 s after a reset — fast in both directions; changes < 0.5 dB do not redraw the waterfall.
  All constants are in `AutoLevelTuning`.
- Window reset: LO center / sample rate / view change (`viewChanged`), gain, AGC, device, start/stop,
  and any row with a different frequency range.
- `SdrUiState`: `autoLevels`, `setAutoLevels()` (persisted in SharedPreferences `waterfall_auto_levels_v1`),
  `loadSettings()`, `autoNoiseFloor`/`autoPeak`. `setLevels()` is unchanged in meaning.
- UI: `main_screen.dart` — an "Auto" checkbox next to the Max slider (in both places: the landscape panel and the portrait expander).
  Legacy (the real app): Settings → new "WATERFALL" section: an "Auto contrast" switch showing the current
  "Noise … dB · peak … dB over 30 s", Max/Min sliders (the legacy UI did not have them before).
- UX decision: in Auto mode the sliders show the auto values and are locked; turning Auto off
  keeps the current levels as the starting point for manual adjustment.

## Tests
- `test/ui/auto_levels_test.dart` (10): noise → min≈floor−5, max=floor+25; a carrier appearing → max goes up;
  carrier gone → held until it leaves the window, then goes down; narrowing is smooth; range change → reset;
  reset(); DC spike/zeros/NaN/edge roll-off do not break the floor; empty rows; bucket limit; pause > window.
- `test/ui/auto_levels_ui_test.dart` (8): integration with SdrUiState (off by default, retune/gain reset,
  turning off keeps levels, persistence), MainScreen and legacy settings widgets.

## Checked on the phone (SM-F936B, RTL-SDR Blog V4, cover screen)
Screenshots `~/prj/docs/screens/t_16c68e1b-*.png`:
- 104.2 WFM, Auto on: noise −58, peak −29 → Min −63 / Max −26; FM stations clearly visible (03, 07).
- 145.5 NFM (empty segment): after ~5 s it settled at Min −64 / Max −33..−34, the waterfall is flat noise without
  "mush" and without saturation (05, 06, 08, 09). Peak −36..−39 is noise outliers (max over ~10⁵ bins per window),
  the top is held by floor+25.
- Back on 104.2 — again Min −63 / Max −26.
Left as is: Auto is on on the phone (an app setting, persisted).

## Not done / possible later
- Constants are not exposed as settings (optional per the spec).

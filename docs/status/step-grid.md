# STATUS — step-based frequency grid (t_33f07c06)

The selected step (the "STEP" button: 5 / 6.25 / 12.5 / 25 / 100 kHz) defines the grid of allowed
receive frequencies: multiples of the step relative to 0 Hz. Code: `lib/ui/legacy/step_grid.dart`
(pure functions in integer Hz), applied by `CenteredReceiver` (`lib/ui/legacy/centered_receiver.dart`).

## Rules
- An arbitrary frequency (keyboard, preset, channel, restored state, drag release)
  is rounded to the nearest grid node. Exactly half a step rounds up (towards the higher frequency):
  150 kHz → 200 kHz, 118.150 → 118.200 MHz at a 100 kHz step.
- ◀ ▶ — the neighbouring node strictly below/above the current frequency: from 118.180 ▶ = 118.200, ◀ = 118.100
  (not "current ± step").
- The result never leaves the device range: if the nearest node is out of range,
  the nearest node inside is used. Input outside the range is still rejected ("Invalid frequency").
- Changing the step immediately moves the current frequency onto the new grid (one LO retune).
- The step is persisted (`SharedPreferences`, key `receiver_step_hz_v1`); until it is loaded
  the frequency is not rounded (to avoid rounding twice on different grids).
- Drag: the VFO moves along grid nodes (the raw finger position accumulates separately), the LO follows
  t_a4e4db6a/t_de5c40c5 (at most once per 250 ms, band edge); on release the frequency is on the grid,
  offset 0, marker centered. One ruler division = one node.
- Presets (favorites) are not rewritten; channel slots store the receiver frequency (after
  a retune it is already on the grid).
- The frequency is shown with at least 3 MHz decimals, more only when needed
  (6.25 kHz: 118.20625): main readout, channel tiles, presets, settings.
- If the backend cannot retune the LO (a file source with a fixed center), there are no repeated
  attempts (`needsRecenter` remembers the non-retunable frequency).

## Tests
`test/ui/step_grid_test.dart` (rounding, tie, bounds, ◀▶, step change, drag, preset/channel,
restore, shell widget test: text = controller = LO),
`test/ui/step_grid_real_controller_test.dart` (real SdrRadioController + DSP isolate:
saved 118.180 at a 100 kHz step → UI / controller / DSP `centerFreq` = 118.200).

## Phone check (SM-F936B + RTL-SDR Blog V4, master build 6c7be15)
LO taken from the driver log (`logcat -s flutter:I`, `RTLSDRSourceModule 'RTL-SDR': Tune: …`):
- step 100 kHz, input 104.330 → screen and channel tile 104.300, `Tune: 104300000`;
- step 12.5 kHz, input 104.3375 → `Tune: 104337500`; switch to 25 kHz → `104350000`
  (exactly half a step → up); ▶ `104375000`; ◀◀ `104350000`, `104325000`; screen/channel
  104.325, marker centered;
- ruler drag ~1.5 s (25 kHz step): LO during the gesture about once per 250 ms, all values
  multiples of 25 kHz; after release 104.475, marker centered;
- force-stop and relaunch: 25 kHz step restored, auto-receive, `Tune: 104475000`.
- found on the phone: the channel tile rounded 104.3375 to "104.338" → fixed (formatMhz
  at all frequency output sites), regression test in step_grid_test.dart. After reinstalling
  (master 58b8a08) on the phone: 6.25 kHz step, ▶ → screen and tile "104.20625", `Tune: 104206250`.
Phone state restored: 104.200 MHz, 12.5 kHz step. Screenshots: `~/prj/docs/screens/t33-*.png`.
Audio was not verified by ear.

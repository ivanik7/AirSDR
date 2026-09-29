// SPDX-License-Identifier: GPL-3.0-or-later
//
// Frequency step grid of the legacy receiver (task t_33f07c06).
//
// The selected step defines the set of allowed receive frequencies: integer
// multiples of the step relative to 0 Hz (100 kHz step → …, 118.100, 118.200 MHz).
// All arithmetic is done in integer Hz so repeated steps never drift.
//
// Rounding rule for arbitrary input (keypad, preset, channel, drag, restored
// state): nearest node; an input exactly half a step between two nodes goes to
// the HIGHER node (round half up: 150 kHz → 200 kHz at a 100 kHz step).
// Results are always kept inside [min, max]: when the nearest node lies outside
// the range, the nearest node inside the range is used instead. Only when the
// range contains no node at all (narrower than one step) is the clamped input
// returned unchanged.

/// Largest node ≤ [max] and smallest node ≥ [min] (null if there is none).
(int, int)? _nodeRange(int step, int min, int max) {
  final lo = ((min + step - 1) ~/ step) * step; // ceil(min / step) · step
  final hi = (max ~/ step) * step; // floor(max / step) · step
  return lo <= hi ? (lo, hi) : null;
}

int _clampToRange(int hz, int min, int max) =>
    hz < min ? min : (hz > max ? max : hz);

/// Nearest grid node to [hz] (ties go up), limited to [min]..[max].
int snapToStep(int hz, int step, {int min = 1, int max = 999999999999}) {
  if (step <= 0) throw ArgumentError.value(step, 'step');
  if (hz < 0) hz = 0;
  final nodes = _nodeRange(step, min, max);
  if (nodes == null) return _clampToRange(hz, min, max);
  final node = ((2 * hz + step) ~/ (2 * step)) * step; // round half up
  return _clampToRange(node, nodes.$1, nodes.$2);
}

/// Neighbour node of [hz] in [direction] (±1): the first node strictly above /
/// below [hz]. From an off-grid 118.180 MHz at 100 kHz: ▶ 118.200, ◀ 118.100.
/// At the range edge it stays on the last node inside [min]..[max].
int stepFrom(
  int hz,
  int step,
  int direction, {
  int min = 1,
  int max = 999999999999,
}) {
  if (step <= 0) throw ArgumentError.value(step, 'step');
  if (hz < 0) hz = 0;
  final nodes = _nodeRange(step, min, max);
  if (nodes == null) return _clampToRange(hz, min, max);
  final node = direction > 0
      ? (hz ~/ step + 1) * step
      : direction < 0
      ? (hz <= 0 ? 0 : ((hz - 1) ~/ step) * step)
      : ((2 * hz + step) ~/ (2 * step)) * step;
  return _clampToRange(node, nodes.$1, nodes.$2);
}

/// MHz text of an integer frequency: at least 3 decimals (kHz), more only when
/// the frequency needs them (6.25 kHz grid: 118.20625). Exact, no float.
String formatMhz(num hz) {
  final v = hz.round();
  final neg = v < 0;
  final a = v.abs();
  var frac = (a % 1000000).toString().padLeft(6, '0');
  while (frac.length > 3 && frac.endsWith('0')) {
    frac = frac.substring(0, frac.length - 1);
  }
  return '${neg ? '-' : ''}${a ~/ 1000000}.$frac';
}

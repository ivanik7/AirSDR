// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/math/{hz_to_rads.h, normalize_phase.h, phasor.h, sinc.h,
// fast_atan2.h, step.h} (@8c9f5ee). Each function is a one-liner in C++; they are collected
// into one Dart library (docs/02 §6.1 item 6).
import 'dart:math' as math;

import 'constants.dart';

export 'constants.dart';

/// hz_to_rads.h:6 — `2π·freq/samplerate`.
@pragma('vm:prefer-inline')
double hzToRads(double freq, double samplerate) => 2.0 * dbMPi * (freq / samplerate);

/// normalize_phase.h:6 — wrap to (−π, π] with a single ±2π (float constant FL_M_PI).
@pragma('vm:prefer-inline')
double normalizePhase(double diff) {
  if (diff > flMPi) {
    diff -= 2.0 * flMPi;
  } else if (diff <= -flMPi) {
    diff += 2.0 * flMPi;
  }
  return diff;
}

/// sinc.h:5 — `sin(x)/x`, 1 at 0.
@pragma('vm:prefer-inline')
double sinc(double x) => (x == 0.0) ? 1.0 : (math.sin(x) / x);

/// fast_atan2.h:9 — piecewise-linear atan2 (argument order (x, y) as in C++: x = re, y = im).
double fastAtan2(double x, double y) {
  const coef1 = flMPi / 4.0;
  const coef2 = 3.0 * coef1;
  final absY = y.abs();
  double r, angle;
  if (x == 0.0 && y == 0.0) {
    return 0.0;
  }
  if (x >= 0.0) {
    r = (x - absY) / (x + absY);
    angle = coef1 - coef1 * r;
  } else {
    r = (x + absY) / (absY - x);
    angle = coef2 - coef1 * r;
  }
  if (y < 0.0) {
    return -angle;
  }
  return angle;
}

/// step.h (float variant): `x > 0 ? 1 : -1`.
@pragma('vm:prefer-inline')
double step(double x) => (x > 0.0) ? 1.0 : -1.0;

/// phasor.h:6 returns complex_t {cosf(x), sinf(x)}. Dart callers use [math.cos]/[math.sin]
/// directly to avoid allocating; this helper writes into [out] at complex index [i].
@pragma('vm:prefer-inline')
void phasorInto(double x, List<double> out, int i) {
  out[2 * i] = math.cos(x);
  out[2 * i + 1] = math.sin(x);
}

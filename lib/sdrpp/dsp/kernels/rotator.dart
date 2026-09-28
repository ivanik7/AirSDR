// SPDX-License-Identifier: GPL-3.0-or-later
// Dart replacement for volk_32fc_s32fc_x2_rotator2_32fc (used by SDR++
// core/src/dsp/channel/frequency_xlator.h:47): out[i] = in[i]·phase; phase *= phaseDelta,
// with the phase renormalised to |1| every ROTATOR_RELOAD = 512 samples.
//
// Differences to VOLK (documented, intentional):
//  * phase and phaseDelta are kept in double precision (VOLK: float) — less drift;
//  * renormalisation happens every 512 samples of the *absolute* sample count (VOLK: every
//    512 samples of each call + once at the end of the call). This makes the output
//    independent of how the input is chunked, which the port's block-boundary tests require.
import 'dart:math' as math;
import 'dart:typed_data';

/// ROTATOR_RELOAD in VOLK.
const int rotatorReload = 512;

/// Rotator state: phase (re, im) and phase increment (re, im).
class Rotator {
  double phaseRe = 1.0;
  double phaseIm = 0.0;
  double deltaRe = 1.0;
  double deltaIm = 0.0;
  int _sinceReload = 0;

  static final Float32List _f = Float32List(2);

  /// Sets the increment to e^(j·omega). Like C++ (`lv_cmake(cos(offset), sin(offset))`, an
  /// lv_32fc_t) the increment is rounded to float32, so the tiny frequency error of SDR++ is
  /// reproduced exactly.
  void setDelta(double omega) {
    _f[0] = math.cos(omega);
    _f[1] = math.sin(omega);
    deltaRe = _f[0];
    deltaIm = _f[1];
  }

  /// Resets the phase to 1+0j.
  void resetPhase() {
    phaseRe = 1.0;
    phaseIm = 0.0;
    _sinceReload = 0;
  }

  /// Rotates [count] complex samples from [input] (starting at complex index [inOff]) into
  /// [output] (starting at complex index [outOff]). In-place allowed.
  @pragma('vm:unsafe:no-bounds-checks')
  void rotate(int count, Float32List input, Float32List output, {int inOff = 0, int outOff = 0}) {
    double pRe = phaseRe, pIm = phaseIm;
    final dRe = deltaRe, dIm = deltaIm;
    int since = _sinceReload;
    int a = inOff * 2, o = outOff * 2;
    for (int i = 0; i < count; i++) {
      final re = input[a], im = input[a + 1];
      output[o] = re * pRe - im * pIm;
      output[o + 1] = re * pIm + im * pRe;
      a += 2;
      o += 2;
      final nr = pRe * dRe - pIm * dIm;
      pIm = pRe * dIm + pIm * dRe;
      pRe = nr;
      if (++since == rotatorReload) {
        since = 0;
        final m = math.sqrt(pRe * pRe + pIm * pIm);
        pRe /= m;
        pIm /= m;
      }
    }
    phaseRe = pRe;
    phaseIm = pIm;
    _sinceReload = since;
  }
}

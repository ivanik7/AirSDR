// SPDX-License-Identifier: GPL-3.0-or-later
// Force-included into the vendored csdr-plus fir.cpp on Apple and Windows.
// glibc and Android bionic declare the GNU sincosf() extension; Apple libm
// and the MinGW CRT do not reliably do so. The macro is defined only after
// <cmath> is included, so it renames calls in fir.cpp, never a libm
// declaration. The upstream source stays byte-identical.
#pragma once

#include <cmath>

static inline void sdrcore_compat_sincosf(float x, float* s, float* c) {
  *s = std::sin(x);
  *c = std::cos(x);
}

#define sincosf sdrcore_compat_sincosf

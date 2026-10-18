// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <mutex>

namespace sdrcore {

// FFTW's planner (fftwf_plan_*, fftwf_destroy_plan) is process-global and not
// thread-safe; fftwf_execute() on an existing plan needs no guard. Every
// vendored csdr object that creates or destroys plans (SSTV decoder, DMR FFT
// bandpass) is constructed and destroyed under this one lock. The inline
// function guarantees a single mutex across all translation units of a binary.
inline std::mutex& fftw_planner_mutex() {
  static std::mutex mutex;
  return mutex;
}

}  // namespace sdrcore

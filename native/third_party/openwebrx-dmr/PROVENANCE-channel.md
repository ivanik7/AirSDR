# Provenance: DMR channel selector files in native/third_party/openwebrx-dmr

The DMR channel selector (`native/src/dmr/channel_filter.cpp`) links these
csdr-plus modules unmodified. Each file was checked byte-identical
(`sha256sum`) against the pinned checkout under `~/prj/ref/openwebrx`.

| File | Upstream (luarvique/csdr-plus) | Commit | License |
|---|---|---|---|
| csdr/firdecimate.hpp, .cpp | `include/firdecimate.hpp`, `src/lib/firdecimate.cpp` | f26b52071c4a127fc8193d058c249cac57585de4 | GPL-3.0-or-later |
| csdr/fractionaldecimator.hpp, .cpp | `include/fractionaldecimator.hpp`, `src/lib/fractionaldecimator.cpp` | f26b52071c4a127fc8193d058c249cac57585de4 | GPL-3.0-or-later |
| csdr/fftfilter.hpp, .cpp | `include/fftfilter.hpp`, `src/lib/fftfilter.cpp` | f26b52071c4a127fc8193d058c249cac57585de4 | GPL-3.0-or-later |
| csdr/fir.hpp, .cpp | `include/fir.hpp`, `src/lib/fir.cpp` | f26b52071c4a127fc8193d058c249cac57585de4 | GPL-3.0-or-later |
| csdr/filter.hpp, .cpp | `include/filter.hpp`, `src/lib/filter.cpp` | f26b52071c4a127fc8193d058c249cac57585de4 | GPL-3.0-or-later |
| csdr/window.hpp, .cpp | `include/window.hpp`, `src/lib/window.cpp` | f26b52071c4a127fc8193d058c249cac57585de4 | GPL-3.0-or-later |

Module parameters follow OpenWebRX+ (luarvique/openwebrx) f1e0d1ac
`csdr/chain/selector.py` and the pycsdr 041986e51f9b191021325f67b2387a47731a0fc7
bindings (`src/firdecimate.cpp`, `src/fractionaldecimator.cpp`,
`src/bandpass.cpp`: Hamming windows, 12 polynomial points, no fractional
prefilter, `FftBandPassFilter` inside a `FilterModule`). pycsdr itself is
not vendored; `channel_filter.cpp` reproduces its constructor calls.

`fftfilter.cpp` needs FFTW single precision: it links the in-tree
`sdrcore_fftw3f` target (`native/third_party/fftw.cmake`, GPL-2.0-or-later).

`compat/csdr_sincosf.h` is project code, not upstream. On Apple and Windows
builds only, CMake force-includes it into `csdr/fir.cpp` to provide the GNU
`sincosf()` extension that glibc and Android bionic already declare. The
upstream file stays byte-identical.

# Embedded rtl_433 provenance

Source: https://github.com/merbanan/rtl_433, pinned upstream commit
`02cd4b69270cb27d4cb1a318d5a549fa8e848dc8` (also available at
`~/prj/ref/openwebrx/ext/rtl_433`). `src/` and `include/` are verbatim
copies of the upstream directories; `COPYING` is upstream's license text.
Upstream files retain their original copyright and GPL-2.0-or-later headers.
The AirSDR adapter under `native/src/decoder/rtl433*` is separate code.
No upstream executable is launched by the application.

Update by replacing both directories and COPYING from a pinned upstream
revision, recording the new hash here, and rerunning the engine/oracle suite.
The adapter uses upstream's `r_api` and `r_flow`, not a protocol reimplementation.
The embedded build excludes the CLI (`rtl_433.c`) and unused radio/network
sources via CMake; those original files remain present to preserve provenance.

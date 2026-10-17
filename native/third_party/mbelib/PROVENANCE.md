# Provenance: native/third_party/mbelib

Vendored unmodified for DMR AMBE+2 voice synthesis (task t_5b101746).

- Upstream: mbelib (szechyjs/mbelib), the copy OpenWebRX+ ships in
  `~/prj/ref/openwebrx/ext/mbelib`, commit `9a04ed5c78176a9965f3d43f7aa1b1f5330e771f`
  ("fixes for MSVC 14.1"), library version 1.3.x.
- License: ISC (see `COPYRIGHT`), compatible with GPL-3.0-or-later.
- Files: mbelib.c/.h, mbelib_const.h, ecc.c, ecc_const.h, ambe3600x2450.c,
  ambe3600x2450_const.h, ambe3600x2400.c, ambe3600x2400_const.h,
  imbe7100x4400.c, imbe7200x4400.c, imbe7200x4400_const.h, config.h,
  COPYRIGHT, README.md, CHANGELOG. Every file is byte-identical to upstream
  (checked with `cmp` against the pinned checkout).
- Not vendored: CMake/pkg-config/debian packaging, `test/`, the author PGP key.
- Build: `native/src/dmr/dmr_voice.cmake` target `sdrcore_mbelib`, only when
  `SDRCORE_ENABLE_MBELIB=ON` (default). Only `mbe_processAmbe3600x2450Frame`
  is reachable from the app; unused codecs are dropped by `--gc-sections`.
- Patent note: AMBE+2 is covered by DVSI patents; see docs/status/dmr.md §5
  (US 8,359,197 listed active until 2028-05-20). Building with
  `-DSDRCORE_ENABLE_MBELIB=OFF` removes this library completely; DMR then stays
  metadata-only and never produces voice PCM.

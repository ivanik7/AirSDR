# miniaudio — `miniaudio/`

- Upstream: https://github.com/mackron/miniaudio, release tag **0.11.25**
  (tarball https://github.com/mackron/miniaudio/archive/refs/tags/0.11.25.tar.gz,
  sha256 `b900edcffe979816e2560a0580b9b1216d674b4f17fbadeca8f777a7f8ab0274`).
- Vendored files, **unmodified**: `miniaudio.h` (single-file library,
  sha256 `ac7af4de748b7e26b777f37e01cee313a308a7296a3eb080e2906b320cc55c89`)
  and `LICENSE`.
- License: choice of **Public Domain (Unlicense)** or **MIT No Attribution**
  (`LICENSE`); both are GPL-3.0-compatible.
- Used by `native/src/audio/miniaudio_sink.cpp` (desktop playback sink). The
  implementation is compiled once in `native/src/audio/miniaudio_impl.c` with
  the options of `native/src/audio/miniaudio_config.h`:
  `MA_NO_DECODING MA_NO_ENCODING MA_NO_GENERATION MA_NO_RESOURCE_MANAGER
  MA_NO_NODE_GRAPH MA_NO_ENGINE`, plus `MA_NO_RUNTIME_LINKING` on Apple
  (CoreAudio frameworks linked at build time, as upstream recommends for
  notarized apps). Not built for Android.

# Provenance: DMR voice files in native/third_party/openwebrx-dmr

Originally vendored unmodified for the OpenWebRX+ DMR voice path (task t_5b101746).
The csdr base files (module/source/sink/reader/writer/complex, LICENSE-GPL)
and `digiham/LICENSE` are shared with the DMR channel card (t_8e3dfcc0) and
were byte-identical to the same upstream files before the portability patch below.

| File | Upstream | Commit | License |
|---|---|---|---|
| csdr/agc.hpp, csdr/agc.cpp, csdr/ringbuffer.hpp | csdr-plus `include/agc.hpp`, `src/lib/agc.cpp`, `include/ringbuffer.hpp` | f26b52071c4a127fc8193d058c249cac57585de4 | GPL-3.0-or-later |
| digiham/digitalvoice_filter.hpp, .cpp | digiham-plus `include/digitalvoice_filter.hpp`, `src/digitalvoice_filter/digitalvoice_filter.cpp` | beec78229edb8e049f8b82729498def952b79cc1 | GPL-3.0 |
| softmbe/interleaver_permutations_const.hpp, softmbe/LICENSE | codecserver-softmbe `src/interleaver_permutations_const.hpp`, `LICENSE` | 66397fcff051a91371673dcdc82b50bd05ac9c53 | GPL-3.0 |

All files were checked byte-identical with `cmp` against the pinned checkouts
under `~/prj/ref/openwebrx`. `ringbuffer.hpp` is included only because
`agc.hpp` includes it; its mmap implementation (ringbuffer.cpp) is not built.

What is NOT ported, and why:
- codecserver (server, protobuf protocol, socket) and digiham's
  `MbeSynthesizer` client: they only move 9-byte frames and 160-sample PCM
  blocks between processes. `native/src/dmr/vocoder.cpp` calls the same
  softmbe decode steps in-process (no subprocess, no socket).
- `softmbesession.cpp` itself is not compiled into the app because it
  requires codecserver/protobuf headers; its `decode_ambe_3600x2450` body is
  reproduced step for step in `AmbeSynthesizer::decode` and the host oracle
  (`tool/dmr_voice_oracle`) compiles the PRISTINE file to prove bit-exactness.

## Windows Source portability

`csdr/windows-source.patch` guards the unused POSIX `TcpSource` declaration,
implementation, explicit instantiations and networking includes with
`#ifndef _WIN32` in `csdr/source.hpp` and `csdr/source.cpp`. The embedded DMR
chain uses in-process `Source` writers, whose behavior is unchanged. POSIX
builds retain TCP support. No DSP code or license header is changed.

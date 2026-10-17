# Provenance: vendored csdr-plus SSTV decoder

## Upstream pin

Source: `csdr-plus`, commit `f26b52071c4a127fc8193d058c249cac57585de4`
(local reference checkout `~/prj/ref/openwebrx/csdr-plus`).
Files copied verbatim unless noted otherwise below.

## Files in this directory

| File | Origin | License | Notes |
|---|---|---|---|
| `include/sstv.hpp` | `include/sstv.hpp` | BSD-3-clause-style (Marat Fayzullin) | Patched, see below. Header preserved verbatim. |
| `src/sstv.cpp` | `src/lib/sstv.cpp` | BSD-3-clause-style (Marat Fayzullin) | Patched, see below. Header preserved verbatim. |
| `include/module.hpp` | `include/module.hpp` | GPL-3.0-or-later (Jakob Ketterl) | Verbatim. |
| `include/source.hpp` | `include/source.hpp` | GPL-3.0-or-later (Jakob Ketterl) | Verbatim. |
| `include/sink.hpp` | `include/sink.hpp` | GPL-3.0-or-later (Jakob Ketterl) | Verbatim. |
| `include/reader.hpp` | `include/reader.hpp` | GPL-3.0-or-later (Jakob Ketterl) | Verbatim. |
| `include/writer.hpp` | `include/writer.hpp` | GPL-3.0-or-later (Jakob Ketterl) | Verbatim. |
| `include/ringbuffer.hpp` | `include/ringbuffer.hpp` | GPL-3.0-or-later (Jakob Ketterl) | Verbatim. Not actually used by the adapter (it uses a plain `MemoryReader`-style custom reader instead; `RingbufferReader`/`Ringbuffer` are vendored for completeness/future reuse and are compiled but otherwise unreferenced by `sstv.cpp` / `native/src/decoder/sstv.cpp`). |
| `include/complex.hpp` | `include/complex.hpp` | GPL-3.0-or-later (Jakob Ketterl) | Verbatim. Not used by the `SstvDecoder<float>` instantiation (no complex IQ involved) but required transitively by `module.hpp`/`source.hpp`. |
| `src/module.cpp` | `src/lib/module.cpp` | GPL-3.0-or-later (Jakob Ketterl) | Verbatim. Explicit template instantiation list unmodified; `Module<float, unsigned char>` is already instantiated upstream (line 109 `template class Module<float, unsigned char>;`), which is exactly what `SstvDecoder<float> : Module<float, unsigned char>` needs. |
| `src/source.cpp` | `src/lib/source.cpp` | GPL-3.0-or-later (Jakob Ketterl) | Verbatim. Only `Source<unsigned char>` template instantiation is used (line 123); the `TcpSource<T>` template is also instantiated upstream but is dead code here (never constructed) and not used by the adapter. |
| `src/sink.cpp` | `src/lib/sink.cpp` | GPL-3.0-or-later (Jakob Ketterl) | Verbatim. `Sink<float>` instantiation used (line 46). |
| `src/ringbuffer.cpp` | `src/lib/ringbuffer.cpp` | GPL-3.0-or-later (Jakob Ketterl) | Verbatim. Compiled for completeness (see ringbuffer.hpp note); not exercised by the adapter's own `MemoryReader`-style byte buffer in `native/src/decoder/sstv.cpp`. |
| `sdr_flutter.patch` | n/a | n/a | Unified diff of `sstv.hpp`/`sstv.cpp` against the pristine upstream pin. |

No minimal GPL-3.0-or-later shim .cpp was required: `module.cpp`, `source.cpp`
and `sink.cpp` compile standalone and already explicitly instantiate every
template specialization (`Module<float, unsigned char>`, `Source<unsigned
char>`, `Sink<float>`) that `SstvDecoder<float>` needs, because upstream's own
explicit-instantiation lists in those three files already cover the SSTV
decoder's types (`Module<T, unsigned char>` with `T=float`). They do **not**
pull in any other module (fftfilter, agc, etc.) — those are separate
translation units not referenced by sstv.cpp/module.cpp/source.cpp/sink.cpp.

The native adapter (`native/src/decoder/sstv.cpp`, owned separately — not
in this directory) implements its own minimal `Csdr::Reader<float>` and
`Csdr::Writer<unsigned char>` (a bounded byte-vector reader/writer) rather
than using `Ringbuffer`/`RingbufferReader`, because the adapter needs
fine-grained control over how much input is buffered and compacted per
`process()` call, and `Ringbuffer` requires an mmap-double-mapped circular
buffer sized at construction time that doesn't fit the "append variable
amounts, compact after `canProcess()`" usage pattern as directly.

## Allowed patches applied (see `sdr_flutter.patch`, each marked `// sdr_flutter:` in-line)

1. **`MAX_LINE_WIDTH` 640 -> 800.** PD-290 is 800 pixels wide
   (`PD290::LINE_WIDTH = 800` in `sstv.hpp`). The unmodified upstream bound of
   640 is smaller than that, so `linebuf[2][MAX_LINE_WIDTH]` and the
   `convertPD`/`convertR36`/`decodeLine` local buffers sized from
   `MAX_LINE_WIDTH` would overflow for PD-290 (this is exactly the defect the
   audit (`docs/status/sstv-audit.md` §"Framing, fidelity...") flags: "Do not ship
   or test PD 290 with the unmodified upstream bound"). Fixed by raising the
   bound to the largest mapped `LINE_WIDTH` (800, used only by PD-290).
   Verified by a full PD-290 decode (616 rows, byte-identical to the patched
   upstream engine) in `sdrcore_sstv_test`, also run under ASan/UBSan (see
   `docs/status/sstv.md`).

2. **`decodeLine` output-capacity guard `LINE_WIDTH*LINE_STEP` ->
   `LINE_WIDTH*LINE_STEP*3`.** The guard checked `writer->writeable() >=
   mode->LINE_WIDTH*mode->LINE_STEP` immediately before calling one of the
   `convert*` functions, every one of which writes `LINE_WIDTH*3` bytes per
   physical row (and `LINE_STEP` physical rows for PD modes via `convertPD`'s
   two row writes). The unmodified guard under-counts the actual write size
   by a factor of 3, which could let `convert*()` call `writeData()` past the
   real `writeable()` capacity (writeData() itself double-checks and would
   refuse to write beyond `writeable()`, so this was not exploitable as a
   buffer overflow by itself, but it silently drops rows instead of
   respecting `canProcess()`'s own writeable-space contract). Corrected per
   the audit's explicit instruction (§"FFTW3 ... ": "decodeLine:575-576 tests
   output capacity as width*LINE_STEP rather than width*3*LINE_STEP").

3. **`printBmpEmptyLines` VLA `char buf[size] = {0}` -> fixed
   `unsigned char buf[3*MAX_LINE_WIDTH] = {0}`.** `size` is
   `mode->LINE_WIDTH * 3`, a runtime value, so `char buf[size]` is a
   variable-length-array (VLA) with a non-trivial (zero) initializer; clang
   (including the Android NDK's clang) rejects VLA initializers at
   `-std=c++17`. Replaced with a fixed-size stack buffer sized by the
   (already raised) `MAX_LINE_WIDTH` bound, writing exactly `size` bytes via
   `writeData(buf, size)` — identical byte content and count to the original,
   just backed by a buffer that is never smaller than needed.

4. **`print()`'s `vsprintf` -> `vsnprintf(buf, sizeof buf, ...)`.** Bounds
   the write to the fixed 256-byte stack buffer; `print()` is only reachable
   when `dbgTime != 0`, which the adapter never sets (`dbgTime=0`, see below),
   so this patch is defensive/hygiene rather than exercised by the adapter in
   production, but keeps the vendored code safe if `dbgTime` is ever enabled
   for debugging.

5. **Minimal instrumentation hooks**: `std::function<void(bool padded)>
   onRowWritten` and `std::function<void(bool naturalEnd)> onFinishFrame`,
   both public members defaulting to empty (no-op `std::function`, which is
   falsy and skipped by the `if(onRowWritten) ...` guards). `onRowWritten` is
   invoked once per `writeData()` call that writes a full scanline
   (`LINE_WIDTH*3` bytes) — once from each of the five `convert*()` functions
   (`padded=false`, i.e. genuinely decoded; `convertPD`'s line-0 duplicate
   write also reports `padded=false`, since it is the same genuinely decoded
   pixel data merely written twice to satisfy PD's "first line has no
   predecessor to average with" rule) and once per line from
   `printBmpEmptyLines`'s loop (`padded=true`, used for both missed-line
   fill-in during `process()` and `finishFrame()`'s tail fill of
   never-reached lines). `onFinishFrame` is invoked once per `finishFrame()`
   call that had an actively selected mode (`curMode && curState>=0`), with
   `naturalEnd = (curState >= curMode->LINE_COUNT)` computed from the
   pre-reset state — true iff every scanline was accounted for (decoded or
   padded), matching the adapter's need to distinguish `reason:"end"` from
   `reason:"sync_lost"`. Neither hook changes any BMP byte emitted or any
   control-flow branch taken; they are pure read-only observation points
   added at the exact call sites that already decide the information the
   adapter needs (`padded` vs not, `naturalEnd` vs not) and that cannot be
   reconstructed later from the BMP byte stream alone (as the audit's Frozen
   v1 contract explicitly requires: "BMP row bytes alone cannot reveal this
   distinction").

   `onFinishFrame(false)` additionally fires from `finishFrame()` when
   `curMode && curState==STATE_SYNC`: a start-sync mode (Scottie 1/2/3/4,
   Scottie DX) writes its BMP header on VIS and then waits in `STATE_SYNC`;
   when that wait times out, upstream abandons the frame without rows and
   without ever reaching the `curState>=0` branch. The extra `else if`
   only observes that case so the adapter can close the announced frame as
   `partial`/`sync_lost`; output bytes and control flow are unchanged
   (covered by `test_scottie_start_sync_timeout` in
   `native/tests/sstv_test.cpp`, which also checks the upstream engine
   wrote only the 54-byte header).

## Explicitly NOT patched (per task constraints)

- **`SYNC_PULSE*32.0` / `LINE_TIME*8.0` timeouts** in `process()`'s
  `STATE_SYNC` and default-scanline-decode branches: these compare a
  millisecond wall-clock-like counter (`msecs()`) against a threshold derived
  from a mode's timing constants expressed in **seconds** (`SYNC_PULSE`,
  `LINE_TIME`), multiplied by small constants (32, 8) with no unit
  conversion — i.e. `msecs() > lastLineT + round(SYNC_PULSE_IN_SECONDS *
  32.0)` compares milliseconds against a bare number derived from seconds.
  This is an upstream quirk: the added slack is a few milliseconds, not the
  intended multiple of a pulse/line. For Martin 1, `round(0.004862*32.0)` =
  `round(0.156)` = 0 ms and `round(LINE_TIME*8.0)` = `round(3.57)` = 4 ms.
  In practice the timeout fires on the first failed search once the stream
  time has passed `lastLineT`. Upstream `canProcess()` only runs `process()`
  with at least 2 s (`sampleRate*2`) of buffered input, so each search covers
  that window before giving up. `test_scottie_start_sync_timeout` exercises
  the `STATE_SYNC` path, and the byte-identical row comparisons exercise the
  scanline path. Left unmodified and documented, as instructed.
- **Forced-VIS option**: not added. Only `mode=auto` is accepted by the
  adapter's `configure()` (see decoder.hpp contract / audit §"Actual chain").
- **`createPlans`/`destroyPlans` cache-ordering "bug"**: `createPlans` caches
  `(sampleRate, fftOut, fftIn)` and short-circuits a second call with the
  same triple *before* clearing the cache in `destroyPlans()`
  (`destroyPlans()` unconditionally zeroes `sampleRate`/`fftOut`/`fftIn` at
  the end, so a subsequent `createPlans()` call after any `destroyPlans()`
  call always regenerates the plans — the "shortcut" only ever fires on the
  very first `createPlans()` call per `SstvMode` instance, inside
  `SstvDecoder`'s own constructor, where it is harmless because each
  `SstvMode` is freshly constructed and only `createPlans()`'d once per
  `SstvDecoder` instance). Not modified, per task constraint. The ASan/UBSan
  run of `sdrcore_sstv_test` constructs and destroys a fresh decoder for
  every test case (several dozen instances) with no reports.
- **Destructor**: unmodified.
- **FFTW**: not dropped; linked via `sdrcore_fftw3f` (see
  `native/third_party/fftw.cmake`, built from vendored source).

## Why no additional GPL-3.0-or-later shim was needed

The task anticipated that `module.cpp`/`source.cpp`/`sink.cpp` might not
compile standalone because they "instantiate many types / pull other
modules." In practice, each of these three translation units:
- `#include`s only its own matching header (`module.hpp`, `source.hpp`,
  `sink.hpp`) plus their transitive dependencies (`reader.hpp`, `writer.hpp`,
  `complex.hpp`), none of which reference any other csdr-plus module
  (fftfilter, agc, deemphasis, ...).
- Has its own explicit template-instantiation block (`namespace Csdr { ...
  }` at file end) that is self-contained and does not require any other
  `.cpp` file to resolve the specific instantiations
  (`Module<float,unsigned char>`, `Source<unsigned char>`, `Sink<float>`)
  that `SstvDecoder<float>` needs through its inheritance chain
  `SstvDecoder<float> : Module<float, unsigned char> : Sink<float>,
  Source<unsigned char>`.

So all three compile and link cleanly as vendored verbatim sources with no
shim, confirmed by the host/ASan/NDK builds in the verification report.

## FFTW3 planner thread-safety

`fftwf_plan_dft_r2c_1d` (called from both `SstvDecoder`'s constructor and
every `SstvMode::createPlans()`) is not thread-safe against concurrent plan
creation/destruction in other threads per FFTW's own documentation. The
native adapter (`native/src/decoder/sstv.cpp`) guards every
`SstvDecoder<float>` construction and destruction with one process-wide
`std::mutex`, matching the one-DSP-worker-thread, one-decoder-instance model
of this app (the adapter itself is only ever driven from the native DSP
worker per `decoder.hpp`'s contract) while still being safe if two handles
each select SSTV concurrently. `fftwf_execute()` (called per audio sample
batch from `process()`) is thread-safe against concurrent execution of
different plans and is not additionally guarded.

## dbgTime

The adapter constructs `SstvDecoder<float>(24000, /*dbgTime=*/0)`. OpenWebRX+
constructs `SstvDecoder(24000, 300000)` (`csdr/chain/digimodes.py:180-195`),
but `dbgTime` only gates periodic textual debug printouts
(`SstvDecoder::printDebug`/`printString`) written into the same output
`Writer<unsigned char>` stream as the BMP bytes when no image is currently
being received (`curState<0`). With `dbgTime=0` those calls never fire
(`if(dbgTime && ...)`), so no debug text can ever be interleaved into the
byte stream the adapter parses as BMP header + rows. This is a deliberate
divergence from OpenWebRX+'s value, justified because OpenWebRX+'s Python
parser (`owrx/sstv.py`) scans for a ` [` marker to split log text from BMP
data — a parsing strategy this adapter does not replicate (see
docs/status/sstv-audit.md: "must not copy its [owrx/sstv.py, AGPL] code, only
reproduce observable framing").

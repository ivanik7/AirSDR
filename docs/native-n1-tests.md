# N1 host-side native tests — scope, commands, and limits

Owner of this document and the files it describes: the `n1-host-tests` test
task (branch `wt/n1-host-tests`). Scope is strictly test and test-support
code: `native/tests/`, `test/native/`, and this file. It does **not** modify
`native/src/`, `native/include/sdrcore.h`, `native/CMakeLists.txt`, Kotlin,
or `AGENTS.md`; the native implementation (`native/src/sdrcore.cpp`) is
owned by a parallel worker and is treated here as a fixed contract defined
by `native/include/sdrcore.h`.

## What is tested, and how

Everything below drives the real `libsdrcore.so` through its public C ABI
(`native/include/sdrcore.h`, revision 2) with real host file descriptors —
pipes, a TCP loopback socket pair, and regular files. There is no mock or
simulated "hardware" layer standing in for a device; where the ABI cannot
yet do something for real (USB acquisition), the tests assert that it
honestly reports `SDR_UNSUPPORTED` rather than faking success.

| Area | File | What it covers |
|---|---|---|
| ABI lifecycle | `native/tests/abi_test.c` (existing, extended) | `sdr_create`/`sdr_destroy` distinct-pointer allocation across cycles, `NULL` handling, argument validation for sample rate / frequency ceiling / gain range from the header's documented bounds. |
| Streaming invariants | `native/tests/stream_test.cpp` (existing, extended) | Synthetic and file sources end-to-end; `input_samples == processed_samples + dropped_samples` after `stop()`; fd duplication (native closes its own dup, not the caller's original); destroy() while a producer is actively running; repeated start/stop cycles for state-leak freedom. |
| fd ownership, ring overflow, abnormal fd failure | `native/tests/fd_lifecycle_test.cpp` (new, standalone) | fd dup survives caller closing the original; `close()` is one-shot and the handle stays reusable; `sdr_v2_open_usb` never fakes success for RTL-SDR/HackRF enum values; a TCP loopback pair forcibly RST'd (`SO_LINGER{on,0}` + `close()`) maps to `SDR_IO_ERROR`/`SDR_ERROR` (never `SDR_DEVICE_GONE`, which is reserved for `ENODEV`); sustained writer pressure against the 8×8192-byte ring produces drops while preserving the accounting invariant; `destroy()` while blocked in `poll()` and while busy both join cleanly; 15 repeated start/stop cycles. |
| Independent checksum oracle | `native/tests/checksum_oracle_test.c` (new, standalone) | Reimplements FNV-1a-64 from the public specification (not by reading `sdrcore.cpp`) and compares it against `sdr_v2_stats().checksum` after a complete, backpressure-free run over a known CU8 file, including the documented "trailing odd byte is dropped" rule and the "0 complete pairs" edge case. |
| Dart FFI, ABI 1 lifecycle | `test/native/sdr_core_test.dart` (existing) | `lib/native/sdr_core.dart` wrapper semantics with fake bindings (no native library needed). |
| Dart FFI, ABI 2 synthetic smoke | `test/native/sdr_core_ffi_integration_test.dart` (existing) | Real `libsdrcore.so` through the wrapper: synthetic source start/stop/stats. |
| Dart FFI, ABI 2 file/usb/configure | `test/native/sdr_core_abi2_ffi_test.dart` (new) | The parts of ABI 2 the current `lib/native/sdr_core.dart` wrapper does not expose yet (`sdr_v2_open_file`, `sdr_v2_open_usb`, `sdr_v2_configure`): binds the C symbols directly with `dart:ffi` the same way `test/usb/usbfs_sys_test.dart` binds libc directly, since extending the wrapper's public surface is native-task work, not test-task work. |

### Why TCP loopback instead of a pipe or AF_UNIX socket for the "abnormal fd
failure" case
A plain pipe only ever gives a clean `EOF` (`read() == 0`) when the write
end closes — never an I/O error — so it cannot reach the
`errno == ENODEV ? SDR_DEVICE_GONE : SDR_IO_ERROR` branch at all. An
`AF_UNIX` `socketpair()` was tried first and also does not generate `RST`
on close (`read()` on the peer still returns clean `EOF`, confirmed by a
standalone probe during development). A connected TCP loopback pair closed
with `SO_LINGER{1, 0}` reliably sends a real `RST`, and the peer's next
`read()` fails with `ECONNRESET`, landing in the generic I/O-error branch.
This is **not** a USB detach test — the comment in the test file says so
explicitly — but it is the closest honest approximation available without
hardware of "the fd died abnormally mid-read", which real USB unplugging
would eventually also produce once it reaches a native read loop (through
a completely different path: Kotlin's `UsbManager`/`UsbDeviceConnection`,
not a raw socket).

### What is intentionally not claimed
- No USB device is opened, emulated, or faked as succeeding. `sdr_v2_open_usb`
  is asserted to keep returning `SDR_UNSUPPORTED`.
- The TCP-RST scenario is not a stand-in for real USB detach semantics;
  see above.
- Ring overflow under `TestRingOverflowUnderBackpressure` is scheduler-timing
  dependent. Ten trials of sustained write pressure reliably produced at
  least one overflow in repeated local runs, but the test logs a warning
  (not a hard failure) if a given run happens to see zero drops, since that
  is host-load dependent rather than a correctness regression.

## Commands

All commands assume `source ~/prj/env.sh` has been run (for `flutter`/`dart`
on `PATH`; the native build itself does not need it, but it provides a
`cmake` fallback path is still needed — see below).

### One-shot runner (recommended)

```sh
native/tests/run_host_tests.sh [build_dir]
```

Builds `libsdrcore.so` for the host with CMake (default
`<repo>/build/native-host-tests`), runs the CMake-wired `ctest` suite
(`sdrcore_abi`, `sdrcore_stream` — defined in `native/CMakeLists.txt`, not
modified by this task), then builds and runs the two new standalone
programs (`fd_lifecycle_test`, `checksum_oracle_test`) against the same
`.so`. It looks for `cmake` on `PATH` first and falls back to the Android
SDK's bundled copy (`~/sdk/android/cmake/*/bin/cmake`) if none is found —
this host build is plain Linux x86_64, not an Android/NDK build; the SDK
copy is just a convenient, already-present CMake binary.

Observed output (debian-ai host, repeated 3× for stability):

```
== Running CMake-wired ctest suite (sdrcore_abi, sdrcore_stream) ==
100% tests passed, 0 tests failed out of 2
== Running standalone fd/lifecycle test ==
[ok] fd dup survives caller close
[ok] double close rejected, handle remains reusable
[ok] open_usb never fakes success
[ok] abnormal fd failure surfaces as SDR_IO_ERROR
[ok] ring overflow observed under sustained backpressure
[ok] destroy() while running (blocked and busy) joins cleanly
[ok] 15 repeated start/stop cycles, no state leakage
All fd/lifecycle checks passed.
== Running standalone checksum oracle test ==
case=odd_length_small input=2048 processed=2048 dropped=0 checksum=0xef3be429c58e501e expected=0xef3be429c58e501e
case=64kib_block input=32768 processed=32768 dropped=0 checksum=0x39ef3e04faa87522 expected=0x39ef3e04faa87522
case=single_byte_no_pair input=0 processed=0 dropped=0 checksum=0xcbf29ce484222325 expected=0xcbf29ce484222325
All checksum oracle comparisons matched.
```

### Dart FFI tests

```sh
source ~/prj/env.sh
export SDRCORE_HOST_LIBRARY=<build_dir>/libsdrcore.so   # printed by run_host_tests.sh
flutter test test/native
```

Without `SDRCORE_HOST_LIBRARY` set, the tests that need the real library
report `Skip: Set SDRCORE_HOST_LIBRARY to the host CMake libsdrcore.so
path` and the suite still exits green — they do not silently pass as
no-ops without explanation, and they do not fail the build for developers
who have not built the native core yet.

```sh
flutter analyze test/native native/tests   # 0 issues
flutter analyze                            # repo-wide, 0 issues (checked during this task)
```

## Known gaps / out of scope for this task

- **No real USB hardware or Blog V4 run.** `sdr_v2_open_usb` is fixed at
  `SDR_UNSUPPORTED` in the current native implementation; there is nothing
  to test beyond "it says unsupported honestly". The eventual 2.4 MSPS
  ≥10 min phone gate from `docs/native-n1-status.md` is a separate,
  hardware-dependent task.
- **Kotlin fd-handoff lifecycle** (serializing fd ownership between Dart and
  native, detach ordering) is explicitly out of this task's file ownership
  (`native/tests/`, `test/native/` only) and is being developed on another
  branch (`n1-kotlin-fd` per the worktree list at task start).
- **`native/CMakeLists.txt` is untouched.** The two new standalone programs
  (`fd_lifecycle_test.cpp`, `checksum_oracle_test.c`) are deliberately not
  added as CMake targets; the native lead owns that file and its test
  target list. `run_host_tests.sh` builds them directly with `g++`/`gcc`
  against the CMake-built `libsdrcore.so` instead.
- **Ring-overflow determinism.** See "What is intentionally not claimed"
  above — the backpressure test's drop assertion is a soft warning, not a
  hard failure, because it depends on host scheduling.

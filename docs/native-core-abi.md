# ADR — N0 C ABI and native engine ownership

Status: accepted for N0; the "Next stages" section is a design contract, **not an implemented API**.
Historical N0 document: for the current partial ABI 2 and the N1 limits see `docs/native-n1-status.md`
and `native/include/sdrcore.h`; the version 1 described below applies to N0 only.
For the integrated N1 ABI 2 contract, use `docs/native-n1-adr.md` and the public header;
the N0 version-1 table below is retained as historical context.
For the N2 ABI 3 radio contract, use `docs/native-n2-adr.md` and
`native/include/sdrcore_v3.h`. Since the N2 integration `sdr_version()` returns 3
and exports the `sdr_v3_*` symbols; ABI 2 symbols are unchanged.
Basis: `~/prj/docs/40-native-core-plan.md` (section "Target scheme", N0–N5),
`native/include/sdrcore.h`. On conflict with the earlier Dart-only description in
`~/prj/docs/10-architecture.md`, `AGENTS.md` and plan 40 take precedence.

## Decision and the N0 boundary

`native/` is a shared C++17/CMake tree for the Linux host and Android (`externalNativeBuild`,
`libsdrcore.so`). The only public binary boundary is the C ABI in
`native/include/sdrcore.h`; C++ classes and exceptions do not cross it.
N0 contains **only an inert handle**: creating it does not open USB and does not start
DSP, audio, or a receive stream. Neither the FFI wrapper nor the native skeleton is a
replacement for the working Dart receiver. The UI and user data stay on the previous
path until parity on the phone. `RadioController` (`lib/ui/radio_controller.dart`)
remains the UI contract when the implementation is switched in the future.

Currently exported functions (C linkage, `SDRCORE_API`):

| Signature | N0 contract |
|---|---|
| `uint32_t sdr_version(void)` | Returns `1`, the C ABI revision, not the app/SDR++ version and not an indication that reception is ready. Needs no handle. |
| `SdrHandle* sdr_create(void)` | Creates a new opaque inert object; `NULL` only on allocation failure. Each successful call gives the caller exclusive ownership of a separate handle. |
| `void sdr_destroy(SdrHandle* handle)` | Releases one previously created handle; `NULL` is allowed and does nothing. For a non-null pointer it is called exactly once. |

N0 returns no diagnostic string or error code: out-of-memory is signalled by `NULL`;
`sdr_version` cannot report an error; `sdr_destroy` returns no result. Passing a
foreign or already freed pointer, or a double free, violates the contract (it is not
an idempotent stop mechanism). After `destroy` all access to the handle is forbidden.
Creating again is allowed.
Dart FFI must check the version **before** using symbols/the handle, check
`NULL` after create, and release each successful handle once (an explicit
`dispose` guarded against repeated calls); do not rely solely on the GC.
In N0 there are no concurrent calls on one handle: its creation and release are
serialized by the owner. There are no thread-safety promises for future operations.

The version is an integer contract revision: `1` now. When extending, this ADR and
the header are updated first, then the implementation and bindings/tests.
Existing symbols and their values/semantics do not change silently; on
incompatibility the revision is raised and the binding refuses before creating a handle,
instead of trying to work with an unknown ABI. New capabilities are not inferred from
the version number without checking the corresponding contract and the presence of symbols;
the N0 client uses only the three existing symbols. The version number does not
imply support for commands, events, or devices.

## Process and thread ownership — target model (not implemented in N0)

The engine must be an object of the **application process**, not of `FlutterActivity` nor
of a Dart isolate. The Android `ReceptionService` is responsible for foreground mode,
the notification, and the wakelock; a process-scoped owner (for example, a component of
`Application` accessible to the Service) holds the single native handle and
serializes commands. The Activity/Flutter UI only attaches and detaches,
without creating a second receiver when the screen is recreated. The Service controls
continuing/stopping reception in the background, but the existing `ReceptionService`
implementation with the Dart engine is not to be replaced in N0. Leaving the UI is not a stop;
the Activity's `onDestroy` does not release a running engine. Death of the Android process
closes native resources; do not plan automatic resumption without permissions and
an explicit check of foreground restrictions. Do not start
reception before a successful foreground start; a start failure and a Stop request must
lead to a stop, not to invisible work.

One active hardware source, one VFO, and one audio stream. Ownership of the USB fd
and its duplication/closing between Kotlin and C++ must be fixed separately
before N1: do not keep an fd whose lifecycle belongs to the Activity;
on loss of USB permission/detach, stop the stream and return an error.
The native engine owns the USB reader, DSP, and audio threads. Their shutdown order:
cancel pending operations → stop reading/decoders/DSP and audio → wait for the
threads → release their buffers and the fd → release the handle. `destroy` of a running
engine after N0 must either synchronously finish all threads before returning,
or require a separate confirmed stop; fix the choice when
extending the ABI, before implementing. Do not allow a callback after
the handle is released or its address is reused.

## Next stages: design contract for commands and events

Below is the boundary for N1–N3, **not a set of functions exported today**.
Do not add calls to Dart that are absent from `sdrcore.h`.

- Control commands go UI → `RadioController` → FFI → native owner:
  source selection, start/stop, retuning, mode/bandwidth, gain,
  squelch, and volume. They require explicit units (Hz, dB), fixed-width types,
  struct size/revision, and range checks; one serialized
  command stream per handle. The result must distinguish `OK`, invalid argument,
  invalid state, incompatible ABI, USB/permission/device error,
  internal error, and unsupported function. A command error is not presented
  as a successful state change in the UI. Events confirm asynchronous start/stop
  transitions and stream errors. Exact C signatures, codes, and the parameter format
  are fixed by a new ADR/header version **before** parallel implementation.
- Native events → UI: state, statistics/drops, decoded
  messages/images, and FFT rows decimated to the UI width. For delivery,
  `Dart_PostCObject` (`dart_api_dl`) to a current `NativePort` is allowed,
  or a bounded ring buffer with explicit reads. A Dart port must not be kept
  as an indefinite dependency: attach/detach on isolate recreation,
  UI close, and post failure, with reception safely continuing without the UI.
  Events carry a type, length, timestamp/sequence, and handle
  generation, to discard stale events. The queue is bounded;
  FFT/statistics may drop old frames under overload, while errors and the final
  state must not vanish silently. The overflow policy and serialization
  format are to be fixed before a concrete event API is introduced.
- IQ and audio sample buffers are **never passed through Dart** (including
  in isolate/`NativePort` messages and in FFI callbacks). Their memory belongs
  to the native graph stages: the producer hands ownership of a slot to the next
  consumer, and it returns to the pool only after processing finishes; stopping
  waits for all busy slots. For the UI only small
  self-contained events and prepared FFT rows are allowed: when passed by copy,
  the receiver owns its copy; when read from a ring, the memory belongs to
  native until the read is acknowledged. No side keeps a pointer to
  another side's temporary buffer after the call ends. The frame/image format and
  memory release must be documented in the concrete ABI.
- Decoders (after N0) receive audio/baseband/raw IQ **inside the native graph**;
  they hand out only results. Wideband modes that capture the whole
  tuner are mutually exclusive with normal reception, rather than creating a second channel. Sources
  and licenses: plan 40 and `~/prj/docs/30-openwebrx-decoders-plan.md`.

## Boundary verification

For N0: the C test `native/tests/abi_test.c` checks the revision, distinct handles,
`destroy(NULL)`, and re-creation; host CMake/CTest and inclusion of the .so in the APK
are verified separately. An FFI call from Dart is a separate downstream task.
Neither the N0 test nor the APK build confirms USB, DSP, audio, background operation on the device,
or audibility: those are separate N1/N2 gates and hardware QA.

## N5 addendum: RTL-SDR tuner gain-list query (`sdr_v3_rtl_tuner_gains`)

Added for the N5 transition, after the Dart receive path (including
`RtlSdrSourceModule`/`RtlSdrDev.getTunerGains()`) was deleted. This is a pure
ABI-3 addition: `sdr_version()` stays 3, every existing `sdr_v3_*` signature
and struct layout is unchanged, and this symbol is additive-only in
`native/include/sdrcore_v3.h`.

```c
int32_t sdr_v3_rtl_tuner_gains(SdrHandle* handle, int32_t* gains,
                                 uint32_t capacity, uint32_t* count);
```

Contract (see the header comment for the authoritative text):

- Returns the RTL-SDR tuner's supported gain values in tenths of a dB,
  **sorted ascending**, through the handle's already-open `usb_adapter`
  (`RtlSdrAdapter::get_tuner_gains`, `native/src/usb_rtlsdr_adapter.cpp`).
  No second USB claim is ever made; the call only queries the existing
  rtlsdr device handle created by `sdr_v2_open_usb`/`sdr_host_open_usb`.
- This is an **exact migration** of the deleted Dart gain path: the old
  `rtl_sdr_source.dart` called `RtlSdrDev.getTunerGains()..sort()` and then
  indexed the sorted list by `gainId` to build its gain stepper UI. The
  native implementation calls librtlsdr's `rtlsdr_get_tuner_gains()` (which
  is not guaranteed sorted for every tuner table) and explicitly sorts
  ascending before returning, so a client reproducing the old
  `gainList[gainId]` index lookup gets byte-for-byte the same table and
  order as before deletion.
- `capacity == 0` with `gains == NULL` is a valid count-only probe: `count`
  receives the required capacity and the call returns `SDR_OK` without
  touching `gains`, regardless of how many gain steps exist (including 0,
  e.g. tuners with no adjustable gain such as FC2580).
- A nonzero but insufficient `capacity` returns `SDR_V3_BUFFER_SMALL`;
  `count` still reports the required capacity, and `gains` is left
  completely unmodified (verified by filling it with a sentinel before the
  call in both the white-box and real-hardware tests).
- A non-RTL-SDR source (file, synthetic, HackRF) or a handle without a USB
  claim returns `SDR_UNSUPPORTED` with `count = 0`. `IDLE` (never opened)
  returns `SDR_INVALID_STATE`. `NULL` handle or `NULL` `count`, or a nonzero
  `capacity` with a `NULL` `gains` pointer, returns `SDR_INVALID_ARGUMENT`.
- Thread-safe and serialized with the rest of the v3 control lifecycle: the
  implementation takes the handle's existing `mutex`, the same lock guarding
  `set_controls`/`start`/`stop`/`close`/`snapshot`; callers must still
  serialize this call with other commands on the handle per the existing v3
  ADR (`docs/native-n2-adr.md`), and it never races `destroy`.
- Internal seam: `UsbRxAdapter::get_tuner_gains` (`native/src/usb_adapter.h`)
  gained a virtual method with a default implementation (`SDR_UNSUPPORTED`,
  `count = 0`) so `HackRfAdapter` and any future adapter need no change
  unless they expose a real discoverable gain table.

Verification (host, `native/tests/`, wired into CMake/CTest):

- `rtl_gain_list_test.cpp` — white-box (includes `sdrcore.cpp` directly, no
  real USB device): full query against a deliberately **unsorted** fake
  gain table proves the sort is actually applied (not just a pre-sorted
  fixture passing by accident); count-only probe; `BUFFER_SMALL` with array
  non-modification; exact-capacity boundary; empty gain table is `SDR_OK`
  with `count=0` (not `SDR_UNSUPPORTED`); non-RTL source (synthetic/file) is
  `SDR_UNSUPPORTED`; an adapter that does not override the method falls back
  to the `UsbRxAdapter` default; `IDLE` handle is `SDR_INVALID_STATE`; `NULL`
  argument combinations are rejected; three threads concurrently querying a
  running handle all observe the identical sorted table.
- `host_rtl_gain_test.c` — real-hardware (opt-in by presence, SKIP+exit 0
  without attached hardware): opens the attached RTL-SDR Blog V4 through
  `sdr_host_open_usb`, confirms a second handle cannot claim the same
  bus/address while the first owns it (no second USB claim), then exercises
  the count-only probe, `BUFFER_SMALL`, exact and over-sized capacity, and
  ascending order against the real `rtlsdr_get_tuner_gains()` table, both in
  `OPEN` and while a v2 diagnostic stream is `RUNNING`.
- Both pass in this worktree's `native/tests/run_host_tests.sh` run,
  including against the physical Blog V4 on `debian-ai`: the R828D tuner
  reports 29 gain steps, ascending from 0 to 496 tenths dB (0.0–49.6 dB),
  matching librtlsdr's `r82xx_gains` table.

The N5 Dart FFI binding (`FfiNativeRadioApi.rtlTunerGains`) probes and copies
this list after USB open. `NativeRadioSettings` retains the legacy index and
device name until a serial-matched dongle opens; the controller selects that
exact sorted entry before the first start and writes the dB gain only after
successful start. Invalid index, missing serial or failed query leave the
index pending and use default gain. A manual gain adjustment replaces it.

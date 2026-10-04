# ADR: N2 native radio contract (ABI revision 3)

Status: **implemented and integrated (t_848e6a1c)**. The declarations in
`native/include/sdrcore_v3.h` are the binary authority. `sdr_version()` returns
**3** and all seven `sdr_v3_*` symbols are exported. ABI 3 is a strict superset:
legacy ABI 2 clients (Dart `SdrCore`, Kotlin `NativeUsbSession`) accept versions
2..3. Results and remaining gaps: `STATUS-n2-integration.md`.

## Decision and compatibility

N1 (accepted on the RTL-SDR Blog V4) and L1 (Linux desktop host target) precede
N2. Keep the existing ABI-1 symbols and ABI-2 signatures, struct layout,
result/state/source numeric values, fd duplication and host-only `sdr_host_*`
extension unchanged. A v3-aware client checks `sdr_version() == 3` **before**
looking up v3 symbols or creating its production controller. An ABI-2-only
client must reject version 3, as `lib/native/sdr_core.dart` already does; the
N2 FFI adapter must explicitly accept v3 only after all symbols and tests land.
Do not silently change `SdrStats` or substitute a diagnostic v2 stream for N2.
Version 3 adds an N2 operating mode on the same opaque `SdrHandle`: open with
an existing v2 file/CU8, synthetic or USB function, or Linux
`sdr_host_open_usb`; then set v3 controls/display/sink and call `sdr_v3_start`.
The Android Kotlin owner keeps its Java `UsbDeviceConnection` alive until native
teardown returns, as in `docs/native-n1-android-lifecycle.md`. Exactly one
hardware claim (Dart **xor** native) and one native receive channel/VFO/audio
stream exist. `sdr_v2_close` and `sdr_destroy` must tear down either operating
mode synchronously; a v2 diagnostic start/stop cannot operate on an active v3
session. Host-only enumeration/open symbols remain optional and absent on
Android. No simultaneous diagnostic and DSP consumer on a single IQ ring.

C ABI calls are serialized by one process owner, except `snapshot` and
`read_fft`, which may run concurrently while the handle remains live. No call
may race `destroy`; the owner must stop polling and wait for outstanding reads
first. No C++ exception escapes any export. Exact-sized revision-3 structs
reject mismatches without modifying the destination or native state. All
reserved input bytes/fields are zero; a client zero-initializes each struct,
sets `size=sizeof(struct)` and `revision=3`, and uses fixed-width integer
fields—not a Dart `double` as the wire type for RF Hz or counters. Command
failures return a negative `SdrResult`; pollers additionally use
`SDR_V3_NO_DATA=1` and `SDR_V3_BUFFER_SMALL=-7`. This contract does not overload
v2 error codes. An asynchronous error is sticky in the snapshot and increments
`error_sequence` until the next successful open, including after stop; multiple
errors never silently overwrite the first failure. Synchronous validation
errors do not poison the stream.

## Radio and UI behavior

`sdr_v3_set_controls` accepts a **complete** desired radio configuration in
OPEN or RUNNING: LO Hz, signed VFO reference offset Hz, complex sample rate,
SDR++ mode ids (NFM=0, WFM=1, AM=2, DSB=3, USB=4, CW=5, LSB=6, RAW=7),
channel bandwidth Hz, gain in tenths dB, hardware AGC where supported, squelch
off/manual/auto, manual dBFS threshold, auto offset dB, volume and mute.
Validate the entire request (including effective tune = LO + offset within
source passband, finite floats, mode-specific bandwidth, auto squelch available
only on appropriate modes) before changing DSP or hardware. Unsupported device
controls must return `SDR_UNSUPPORTED`, not appear to work in the UI. A
successful return means the requested configuration is applied; a failed or
partial hardware retune must leave the snapshot truthful. For a RUNNING LO,
sample-rate or gain change, serialize the internal stop/configure/restart while
retaining the device claim. A VFO-only change stays within the sampled band and
uses a native digital shift; mode, filter, squelch, mute and volume changes do
not require a second USB stream. The mode defines the passband reference:
USB's reference is lower, LSB's upper, other modes' center, matching
`RadioController.vfoCenterOffset`. A full restart advances the stream
generation. Sink selection happens in OPEN; `set_audio_sink` copies a bounded
UTF-8 spec and does not retain a Dart pointer. Linux defaults to null and
supports WAV/ALSA; Android defaults to AAudio. WAV/null are legitimate
non-audible host acceptance sinks, never proof of acoustic output.

`RadioController` in `lib/ui/radio_controller.dart` stays the only UI contract.
The N2 adapter maps its getters, setters, link states, status, error, mute,
source settings and `FftRow` to this ABI, preserving `SdrDeviceInfo`, favorites
and the Receive/Presets/Settings UI. `setTuning(centerFrequency, vfoOffset)`
represents an atomic UI tune. At rest center=tuned and offset=0; during a drag
an in-band offset may move the one VFO; End/Cancel retunes the LO **once** to
tuned and resets offset to zero. The existing UI tuner and step grid choose the
frequency/snap policy. Sequential `ChannelScanner` in
`lib/ui/channels/channel_scanner.dart` visits saved channels using the **same**
receiver, mode and auto-squelch status; the adapter must clear squelch readiness
on each new tune/mode/stream generation so scanner dwell never sees stale
status. Manual changes cancel scanning; an explicit Stop remains stopped until
Start or a new attach per the existing controller. `setFftWidth` and
`setFftView` build `SdrV3Display` without synchronous `notifyListeners` in a
layout callback. No fake parallel channels or silent 'supported' controls.

The working Dart receiver remains the Android default/selectable fallback
through N2; never open the same USB device concurrently, and switch only after
native stop/close and claim release. L1's Linux Dart receiver is not supported:
show native-required state if the v3 library cannot load, not synthetic rows.
After the complete Linux-host acceptance override in task `t_58a4efeb`, native
may become the Android default; N5, not N2, removes Dart DSP/drivers later.
This ADR supersedes the old phone-only N2 gates in plan 40; the phone check is
separate and non-blocking.

## Data, buffer lifetime and backpressure

Native USB callbacks produce bounded IQ slots; native DSP consumes and returns
slots to its pool after work, audio frames stay native in the sink, and stop
joins all workers and drains or releases outstanding slots before fd/audio
close. Neither IQ nor audio samples, device pointers nor native ring slots pass
to Dart through FFI, JNI, MethodChannel, NativePort or isolates. A producer
never blocks a USB callback on UI delivery; IQ overflow drops whole incoming
pairs with an explicit `dropped_samples` count (distinct from USB transport
loss). Audio sink drops stereo frames non-blockingly with a separate count.
Stop/detach/restart invalidate old FFT and squelch state and create a new stream
generation; errors persist until a new successful open. The sample sink remains
one; loss of Android focus mutes/pauses as appropriate and is reported, not a
second audio route.

N2 chooses **pull/poll**, not `Dart_PostCObject`, to avoid an unbounded Dart
mailbox. DSP replaces a single latest completed FFT slot at up to 30 rows/s;
its overwrite counter increments when an unread row is replaced. DSP decimates
power (dBFS) by max to the requested 1..2048 display columns and records
absolute low/high Hz, sequence, generation, control sequence and monotonic time
with the row. FFI polls at most 30/s only while the UI needs FFT, passes an
array with capacity at most 2048 floats, and copies before releasing the native
lock. It discards rows from earlier generations or control sequences, and
never retains native pointers after the call. NO_DATA leaves metadata/bins
unchanged; BUFFER_SMALL only reports required width, allowing a bounded retry.
The maximum one row is 8192 bytes plus metadata regardless of UI lag. Metadata
and statistics are atomic caller-owned copies, polled at most 5/s by the UI;
when the UI is detached there is **no** growing event queue. State, first async
error plus `error_sequence`, and cumulative counters are retained in the
snapshot so UI backpressure cannot silently lose a terminal failure. The
controller must respond to an ERROR snapshot by stopping/releasing ownership,
updating `DeviceLinkState` and preserving `lastError`. Detached UI resumes by
fetching the current snapshot; sequence/generation reject stale rows.

The `SdrV3Snapshot` reports applied LO/offset/mode, source/state, squelch
readiness/metric/threshold and cumulative IQ/audio/FFT-drop counters. Its
`audio_nonsilent_frames` is useful for WAV/null acceptance but does not prove
human audibility. Sample count and rate conventions match ABI 2 (complex IQ
pairs per second); audio counts are stereo frames and WAV output is 16-bit
stereo, typically at 48 kHz. CPU/memory/drops are measured separately against
recorded input and the host `rtl_test` baseline; ring drops are *not* USB loss.

## Android service ownership and failure order

On Android a process-scoped owner reachable from `SdrApplication` and
`ReceptionService` owns the sole handle and USB claim; a Flutter Activity
merely attaches/detaches its view and polling. A native-only stream is started
only after service foreground promotion and wakelock/focus setup; failure of
promotion or audio focus denies start and leaves no running receiver. The
service must not depend on a live Activity, Dart isolate or UI poller for DSP
and audio. Activity recreation neither opens another device nor stops a live
session. Notification Stop and UI Stop converge on one serialized, idempotent
owner teardown: mark stopping/reject commands -> cancel reader -> join
DSP/audio workers and close sink -> v2 close/destroy -> release native dup and
Java USB connection -> release audio focus and wakelock -> stop foreground
service. USB detach follows the same ordered teardown with a sticky
`SDR_DEVICE_GONE`/I/O error. `onDestroy` of a service must await shutdown (off
main thread) before dropping foreground/wakelock, not merely call fire-and-
forget `stopNativeStreams`. Existing N1 service/session code is not yet this
contract and must be adapted and host/JVM-tested by the audio/lifecycle worker.
On an unrecoverable teardown timeout, terminate the process rather than leave
zombie playback or USB access. Android process death naturally closes owned
fds; do not automatically restart reception on a sticky service invocation.

## Acceptance and ownership of follow-up files

This card owns `native/include/sdrcore_v3.h` and this ADR, **not** DSP, sink
implementation, FFI/controller or fixtures. Implementers must not silently
change the header; propose changes through the integrator. N2 may turn the
version gate to 3 only when the full header is implemented on Linux and Android
and new and legacy clients/tests have been updated. Build from source with
license checks; no prebuilt binaries. Linux host Blog V4 proof must include
>=10 minutes 2.4 MSPS, spectrum/waterfall screenshots, retune/gain,
AM/NFM/WFM/SSB/CW producing non-silent frames in WAV/null, stop/restart, drop
stats compared with `rtl_test`, and a short local-FM WFM WAV for manual listening. Run host
CTest/oracles and Flutter analyze/test, Linux debug/release, Android debug and
arm64 release, ABI exports and 16 KiB page alignment. Android-only
ForegroundService, AAudio and fd handoff need unit/host tests; actual phone
behavior is **unverified** in N2 without a separate phone-check task and does
not block Linux acceptance. The Dart receiver remains available until N5.

## N2 close-out: Android wiring and default engine (t_58a4efeb)

Decided by the N2 lead before delegating the remaining glue; workers must not
change these shapes.

Engine selection (`lib/main.dart`). `SDR_ENGINE` (environment wins over
`--dart-define`) now defaults to **`native`**; `dart` selects the old engine
until N5 deletes it. Linux: native v3, or the honest native-required state if
the v3 library cannot load. Android: native when API level >= 26 (AAudio) and
`sdr_version() == 3`; otherwise the Dart engine (a real receiver, not a fake),
with the reason logged. The API level comes from `sdkInt` on `sdr/background`
(returns `Build.VERSION.SDK_INT`). Only one engine object exists per process,
so the two never open the same USB device. On Android the native engine takes
the USB fd from the existing Dart-owner `open`/`close` of `UsbSdrPlugin`
(`AndroidNativeDeviceSource`); `sdr_v2_open_usb` dup()s it, and the Java
connection stays open until the controller has destroyed the handle.

Android service handshake on MethodChannel `sdr/background` (Dart -> Kotlin):
- `promote {frequency:int, mode:String}`: start `ReceptionService`, and reply
  `success(null)` **only after** `startForeground`, the partial wake lock and
  `AUDIOFOCUS_GAIN` are all held. Any failure, or a Stop already in progress,
  replies `error("PROMOTION_FAILED", reason)` and leaves no foreground
  service. A second `promote` while promoted succeeds immediately. This is
  `NativeRadioController.beforeStart`; `sdr_v3_start` runs only after success.
- `release`: the native handle is already stopped/closed and the USB fd
  released by Dart. The service drops focus, wake lock and foreground and
  stops itself **without** calling `stopReception` back. Idempotent; replies
  `success(null)` immediately, also when no service runs. This is `afterStop`.
- `update` is unchanged. `start`/`stop` remain the Dart-engine protocol.
- Notification Stop, focus loss and owned USB detach keep using the existing
  ordered teardown (Kotlin -> `stopReception` -> controller `stop()` ->
  `release`). A `release` arriving while that teardown runs replies success at
  once and does nothing else (the teardown awaits the `stopReception` reply,
  which itself awaits `release`, so waiting would deadlock); the teardown then
  finishes normally.
- `BackgroundReception` sends `start`/`stop` only for controllers that do not
  own their service lifecycle; for `NativeRadioController` it sends only
  `update` and still handles `stopReception`/`serviceFailed`/`openReceive`.

Persistence parity (`NativeRadioController(configDir: ...)`): file
`native_radio.json` in the app support directory holds tuned frequency,
mode, per-mode bandwidth, sample rate, gain, squelch type/level/auto offset.
First run without it migrates from the Dart engine files (`config.json`
frequency + `vfoOffsets.Radio`, `radio_config.json` selected demod and
per-demod settings) and from the L1 `linux_host_radio.json`; missing or
corrupt files fall back to defaults and never throw. Mute is never restored
(every session starts muted, as in the Dart engine). Volume is fixed at 1.0
(the UI has no volume control; the Dart engine also forces 1.0).

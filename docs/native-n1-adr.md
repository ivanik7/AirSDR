# ADR: N1 native USB IQ acquisition (ABI revision 2)

Status: ABI 2 implementation integrated; phone acceptance pending. The authoritative binary declarations are in `native/include/sdrcore.h`. This ADR does not promise DSP, audio, a production native UI controller, or device parity.

## ABI and lifecycle

ABI 2 is an incompatible *capability extension* of ABI 1: the first three
symbol signatures and handle ownership remain stable, but `sdr_version()` now
returns 2. Clients must reject an unknown version before creating a handle and
resolve `sdr_v2_*` symbols only for revision 2. The C header is the executable
signature/enum/layout authority; no v2 operation is exposed by an ABI-1 binary.
`SdrStats` is a fixed-layout, by-pointer snapshot: the caller writes its exact
`sizeof(SdrStats)` and revision 2, then native copies the whole struct under a
lock. A different size/revision is rejected without modifying the output.

The original `sdr_version`, `sdr_create`, and `sdr_destroy` symbols retain their signatures. `sdr_version()` returns 2. A single process-scoped owner serializes commands on a handle: `sdr_v2_open_usb(handle, borrowed_usbfs_fd, SDR_RTLSDR|SDR_HACKRF)`, `sdr_v2_configure(handle, rf_hz, complex_samples_per_second, gain_tenths_db)`, `sdr_v2_start`, `sdr_v2_stop`, `sdr_v2_close`, `sdr_destroy`. `sdr_v2_stats` returns a copied snapshot with `size == sizeof(SdrStats)` and `revision == 2`. Values are fixed-width C integers; no C++ exception crosses the ABI. Native stops and joins producer and consumer threads synchronously before closing its resources; `destroy` also stops an active engine. The caller may not reuse a destroyed handle.

States: IDLE → OPEN → RUNNING → OPEN → IDLE; asynchronous input failure records ERROR and a negative `last_error` until stop. Results distinguish invalid argument/state, unsupported, I/O, missing device, internal failure. Before a USB stream starts, configure its RF frequency, complex sample rate, and single gain value. File and synthetic configuration only changes metadata. Reconfiguration while RUNNING is not in ABI 2: stop → configure → start. Gain for HackRF is necessarily an approximate mapping onto LNA/VGA/RF amp; fine-grained controls need a future ABI revision. No claims of seamless mid-stream retune or gain adjustment.

| Command | Required state | Success / failure contract |
|---|---|---|
| `create` | n/a | New IDLE handle or NULL on allocation failure. |
| `open_file(fd, rate)` / `open_synthetic(rate)` | IDLE | OPEN; rate 1,000–20,000,000 complex pairs/s; file fd borrowed and duplicated. |
| `open_usb(fd, source)` | IDLE | OPEN for source 3 (RTL-SDR) or 4 (HackRF); valid, permitted usbfs fd required. Failed open leaves IDLE and never consumes caller fd. |
| `configure(rf_hz, rate, gain)` | OPEN | RF 0–7,250,000,000 Hz, rate 1,000–20,000,000 complex pairs/s, gain −1,000..1,000 tenths dB; on failure snapshot metadata is unchanged, though a partially failed hardware configuration must not be assumed rolled back. Device-specific rates/gains can be rejected. |
| `start` | OPEN | RUNNING; USB requires successful configure. Repeated start returns INVALID_STATE. |
| `stop` | RUNNING or ERROR | Synchronously cancel, join and drain into OPEN. A second stop returns INVALID_STATE. Preserve counters and last_error; restart is allowed after a successful stop. |
| `close` | OPEN, RUNNING or ERROR | Join and release owned descriptors into IDLE; repeated close returns INVALID_STATE. Reopen on the same handle is allowed. |
| `stats` | any live state | Atomic copied snapshot; cannot race with destroy. |
| `destroy` | any live state | Synchronous teardown and free; NULL accepted, non-NULL exactly once. |

All v2 commands return `SDR_OK=0` or a negative result:
`SDR_INVALID_ARGUMENT=-1` (NULL/invalid fd, source, range or stats layout),
`SDR_INVALID_STATE=-2` (illegal transition), `SDR_UNSUPPORTED=-3`
(capability/device setting), `SDR_IO_ERROR=-4` (other I/O),
`SDR_DEVICE_GONE=-5` (detach/ENODEV) and `SDR_INTERNAL_ERROR=-6`
(worker setup). Async reader errors appear in `stats.state=SDR_ERROR` and
`stats.last_error`; command failures are returned synchronously. Polling stats
is the ABI-2 asynchronous error notification mechanism; there is no callback or
NativePort contract in this revision. After stop, `last_error` remains available
until the next successful open resets the snapshot. All commands, including
destroy, are serialized by the process owner; only stats may be polled from
another thread while the handle remains alive. A stopped Flutter Activity must
not implicitly destroy an active process/service-owned handle.

The Kotlin `UsbSdrPlugin` owns the original `UsbDeviceConnection` and fd. It serializes Dart versus native ownership by device name; native `open_usb` duplicates the borrowed fd before libusb wraps it, and the adapters close exactly that duplicate after the async driver has stopped. The caller keeps its Java connection live until native stop/close/destroy returns. Activity detach for configuration changes leaves the engine attached. USB detach closes the native session before the Java connection. A new plug requires a fresh permission/open and session. The engine is not activated automatically; the working Dart receiver and user settings remain unchanged. JNI functions `Java_net_ivanik_sdr_1flutter_JniSdrNativeBridge_native*` carry only commands and a ten-number statistics snapshot over MethodChannel; no IQ or audio flows through Dart or JNI.

## Streaming, counters, and sources

Native owns a bounded ring of 8192-byte CU8 IQ blocks (eight slots in N1; 64 slots, ~109 ms at 2.4 MS/s, since the N2 integration) and producer/consumer threads. RTL-SDR callback buffers are split into 8192-byte ring chunks; HackRF CS8 bytes are offset into CU8. Full ring drops new complete IQ pairs and increments `dropped_samples`. `input_samples == processed_samples + dropped_samples` after a stopped, drained stream. `checksum` is diagnostic FNV-1a of consumed bytes; it is not demodulation or audio. The counters do not include losses inside the device/USB controller, so a zero ring-drop value alone cannot prove lossless reception. File and synthetic sources remain host diagnostics. This is a single source/one receive channel, not a multi-device receiver.

The producer copies complete IQ pairs into its bounded native ring; the
consumer returns each slot to that ring after processing. On overflow it drops
the incoming chunk, never blocks the USB callback awaiting Dart. Input,
processed and dropped counters are cumulative since the latest successful
open (across stop/start) and count complex IQ pairs, not bytes. The diagnostic
checksum uses the consumed CU8 byte stream (FNV-1a); a trailing unpaired file
byte is ignored. No pointer to a ring slot survives close/destroy, and neither
IQ nor audio is passed over FFI, JNI, MethodChannel, or Dart isolates. Future
FFT/event transport requires a separately specified bounded protocol.

Vendored source revisions, patch provenance, licensing, and build selection are listed in `native/third_party/NOTICE.md`. Source-built libusb, rtl-sdr (including Blog V4 detection/tuner path), and HackRF are linked into `libsdrcore.so`; the Android build uses NDK arm64 and 16 KiB LOAD alignment. The physical Blog V4/HackRF signal path is *not verified* merely by successful cross-compilation.

## Verification and acceptance boundary

On host: CMake/CTest (four targets), fake-fd ownership/error/lifecycle, independent checksum oracle, Kotlin JUnit fake-bridge tests, and real Dart FFI calls into the host `.so`. Android arm64 `.so`, debug APK, and release APK are build gates. These tests do not substitute for on-device proof of libusb open-by-fd, 2.4 MSPS throughput, USB detach, or foreground lifecycle. Native commands run on the plugin's serial `sdrcore-control` thread, not the main thread (see `docs/native-n1-android-lifecycle.md`); open/stop/detach latency on hardware is unmeasured and must be checked during phone QA.

Acceptance requires an Android phone with RTL-SDR Blog V4 connected over OTG and exclusive ADB permission: native open/configure at 2.4 MSPS, at least ten minutes of timestamped counters, stop/restart, stop → retune/change gain → restart, physical detach/replug, teardown with no fd leak/double close, and comparison with the Dart receiver without clearing data. HackRF hardware is unavailable and remains unverified. Keep N2 gated and the Dart path the default until phone acceptance is recorded.

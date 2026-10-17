# STATUS-usb — Android USB layer (worker `usb`, branch `wip/usb`)

## Done
| File | What |
|---|---|
| `lib/usb/usbfs_abi.dart` | `_IOC` encoding, `USBDEVFS_*` numbers (via `sizeOf<>` of the structs), `struct usbdevfs_ctrltransfer/_bulktransfer/_urb` (dart:ffi `Struct`), `USBFS_CAP_*`, URB flags/types, errno. `usbfsAbiSupported` (64-bit only). |
| `lib/usb/usbfs_sys.dart` | libc `ioctl` (VarArgs), `lseek`+`read`, errno (`__errno_location` on glibc / `__errno` on bionic) from `DynamicLibrary.process()`. `UsbfsSys` interface (returns `-errno`) so the transport can run against a fake kernel. |
| `lib/usb/usbfs_transport.dart` | `UsbfsDeviceHandle implements UsbDeviceHandle` over an fd (port of `linux_usbfs.c`: `op_wrap_sys_device/initialize_device/initialize_handle`, `op_set_configuration`, `claim/release_interface`, `op_clear_halt`, `op_reset_device` with re-claim). GET_CAPABILITIES (ENOTTY falls back to `CAP_BULK_CONTINUATION` as in libusb; ENODEV maps to noDevice). Device descriptor: `lseek(0)+read()` from the fd as in libusb, falling back to GET_DESCRIPTOR(DEVICE) on EP0. Sync CONTROL/BULK ioctl (bulk is split into 16 KiB chunks without `CAP_NO_PACKET_SIZE_LIM`). errno→`UsbError` mapping. Does not close the fd (Kotlin owns it). Non-64-bit → `UsbException(notSupported)`. |
| `lib/usb/usbfs_bulk_stream.dart` | `UsbfsBulkInStream`: reader isolate, N URBs + (N+spare) `malloc` slots, blocking REAPURB, hands over `(slot<<32)|len` via SendPort, slots returned by `release()`→SendPort; no free slot → drop + counter (in shared native memory), the URB is resubmitted immediately. `cancel()`: stop flag + DISCARDURB of all URBs from the consuming isolate (repeated every 50 ms until the reader exits), the reader drains (reaps) all URBs, then the memory is freed. ENODEV/ESHUTDOWN (URB status, REAPURB, SUBMITURB) → stream error `UsbException(noDevice)` and close. EPIPE/EOVERFLOW/EPROTO… → the URB is retired (as in `_libusb_callback`: only COMPLETED is resubmitted); when all are retired → pipe/overflow/io error. `UsbfsDeviceHandle.wrap` has a `spareBulkSlots` parameter (default = numBuffers). |
| `lib/usb/usb_descriptors.dart` | `parseDeviceDescriptor`, port of `libusb_get_string_descriptor_ascii` (langid from index 0, non-ASCII → '?'). |
| `lib/usb/mock_transport.dart` | `MockUsbDeviceHandle`: trace of all calls (`UsbTraceEntry`: type/req/value/index/wLength/data; stable text format `C 40 00 2000 0110 0002 0102` for diffing against the C oracle), IN responses via the `onControlIn(req, resp)` callback, `onControlOut`, `onBulk`, strings, `unplug()`. `MockBulkInStream`: `push/pushAll/end/addError`, data is copied into malloc slots (same `UsbBlock` contract), dropped when slots are busy. |
| `lib/usb/android_usb.dart` | Channel wrapper: `listDevices`, `open`→`{fd,vid,pid}` (PlatformException→`UsbException`), `close`, `hasPermission`, `initialDevice`, `events` (attached/detached). |
| `android/.../UsbSdrPlugin.kt` | FlutterPlugin+ActivityAware: `sdr/usb` (listDevices/open/close/hasPermission/initialDevice), `sdr/usb/events`. Permission: `PendingIntent.getBroadcast(Intent(ACTION).setPackage(pkg), FLAG_MUTABLE on S+)`, receiver via `ContextCompat.registerReceiver(..., RECEIVER_NOT_EXPORTED)` (permission + ATTACHED + DETACHED). Several concurrent open() calls for one device wait for a single dialog. `UsbDeviceConnection`s are kept in a map until close()/detach. `USB_DEVICE_ATTACHED` at launch and via `onNewIntent` → `initialDevice` + an attached event. Serial read inside try/catch SecurityException. |
| `MainActivity.kt` | registers `UsbSdrPlugin` in `configureFlutterEngine`. |
| `AndroidManifest.xml` | `uses-feature usb.host required=false`, intent-filter `USB_DEVICE_ATTACHED` + meta-data `@xml/device_filter`. |
| `res/xml/device_filter.xml` | 42 RTL entries from `known_devices[]` (generated from librtlsdr.c) + HackRF One/Jawbreaker/rad1o + Airspy R2/Mini + Airspy HF+ = 47, decimal IDs. |
| `tool/usbfs_abi_oracle.c` | C oracle for ioctl numbers/offsets (the test builds it with gcc). |

## Tests
`source ~/prj/env.sh && flutter test test/usb` → **All tests passed** (45 tests):
- `usbfs_abi_test.dart` — ioctl numbers, field sizes/offsets (probing native memory), cross-check against the gcc oracle for `<linux/usbdevice_fs.h>`.
- `usbfs_sys_test.dart` — **real libc**: VarArgs ioctl on /dev/null → -ENOTTY, bad fd → -EBADF, reading root hub descriptors from `/dev/bus/usb/001/001` (vid 1d6b).
- `usbfs_transport_test.dart` — against `FakeUsbfsKernel` (decodes real ioctls/structs): wrap/caps/descriptor/EP0 fallback, control IN/OUT, errno mapping, bulk split at 16 KiB, cfg/claim/release/halt, reset with re-claim, string descriptors.
- `usbfs_bulk_stream_test.dart` — real reader isolate + URBs in native memory: block order, data continuity, drops = gaps, no drops when the consumer keeps up, ENODEV (reap) → noDevice, -ESHUTDOWN → noDevice, -EPIPE on all → pipe, short URBs, cancel is idempotent and reaps all URBs, close() cancels streams. Run 3 times in a row — stable.
- `mock_transport_test.dart`, `android_usb_test.dart` (channel mocks + device_filter ⊇ known_devices[] from librtlsdr.c).

`flutter analyze lib/usb test/usb` → 0 errors/warnings (1 info in the contract file `usb_transport.dart:74` — `Pointer<Uint8>` in a doc comment; not my file).

Kotlin: `cd android && ./gradlew --offline --no-daemon :app:compileDebugKotlin` → **BUILD SUCCESSFUL** (0 errors/warnings in UsbSdrPlugin.kt). `gradlew` + `gradle-wrapper.jar` are absent from the worktree (gitignore) — copied locally from `~/prj/sdr_flutter/android`, not committed.

## Not done / limitations
- Not verified on a real phone/dongle (no hardware). Integration with dummy_hcd was not done (not required).
- armv7 (32-bit) is not supported: `wrap()` throws `notSupported`. The structs are declared via dart:ffi, so the 32-bit layout would be recomputed automatically, but it is untested.
- Kernels without `USBFS_CAP_NO_PACKET_SIZE_LIM` (< 3.3): sync bulk is split into 16 KiB chunks; streaming with a buffer > 16 KiB → `notSupported` (libusb would split it into several URBs with BULK_CONTINUATION).
- No timeout on streaming URBs (as in usbfs: URBs have no timeout; librtlsdr BULK_TIMEOUT=0 too).
- errno is read right after the FFI call (non-leaf); in theory the VM could clobber errno on a safepoint transition — not observed in practice (the ENOTTY/EBADF test passes).
- The foreground service (`mediaPlayback`) from docs/04 §8 was not added — out of scope.

## Contract questions (`usb_transport.dart` unchanged)
1. There is no way to set the number of spare pool slots in `openBulkIn` — done as the `spareBulkSlots` parameter of `UsbfsDeviceHandle.wrap` / `MockUsbDeviceHandle`. Maybe add `{int spareBuffers}` to the contract.
2. `UsbBlock.address` is valid only until `cancel()`; after `cancel()` `release()` is ignored — worth documenting in the doc comment.
3. The doc comment at `usb_transport.dart:74` triggers a lint info (angle brackets) — fix with backticks.

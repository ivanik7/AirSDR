# N1 Android USB fd ownership and native lifecycle

Scope: `android/app/src/main/kotlin/net/ivanik/sdr_flutter/` (`UsbSdrPlugin`,
`UsbDeviceLifecycle`, `UsbSessionOwnership`, `NativeUsbSession*`,
`JniSdrNativeBridge`, `ReceptionService`) and `native/src/sdr_jni.cpp`. The C
contract is `native/include/sdrcore.h` (ABI 2) and `docs/native-n1-adr.md`;
this document only describes how Android satisfies it. The Dart receiver stays
the default; the native engine is reachable only through the opt-in
`native*` MethodChannel calls below and has no DSP or audio.

## Owners

| Resource | Single owner | Released |
|---|---|---|
| `UsbDeviceConnection` (one per `deviceName`) | `UsbDeviceLifecycle.connections` | Exactly once, by whichever path removes it from the map: Dart `close`, `nativeClose`, USB detach, failed/denied open, or engine teardown. |
| Original usbfs fd | The `UsbDeviceConnection` | Only via `UsbDeviceConnection.close()`. Kotlin and Dart never `dup()` or `close()` it. |
| Native duplicate fd | sdrcore USB adapter | `sdr_v2_open_usb()` `dup()`s the borrowed fd before `libusb_wrap_sys_device`; native `close`/`destroy` closes only that duplicate after the reader threads have joined. |
| `SdrHandle` | `NativeUsbSession` (one per device, in `NativeUsbSessionRegistry`) | `NativeUsbSession.close()`: stop (if running) → `sdr_v2_close` → `sdr_destroy`, idempotent. |
| Stream right (Dart xor native) | `UsbSessionOwnership` inside `UsbDeviceLifecycle` | Dart: on Dart `close`/detach. Native: after native close and Java close both finished. |

Native keeps its own duplicate, but the header still requires the caller to
keep the Java connection (and its fd) alive until native close/destroy has
returned; the plugin does exactly that and never relies on the duplicate alone.

## Threads

All `MethodChannel`, broadcast and lifecycle callbacks run on the Android main
thread. Every sdrcore call (`open_usb`, `configure`, `start`, `stop`, `stats`,
`close`, `destroy`) runs on one serial `sdrcore-control` executor thread owned
by the plugin, which serializes commands per handle as the ABI requires and
keeps blocking joins off the main thread. Replies are posted back to the main
thread. When the native side holds a device, Java `close()` is always queued
after the native close on that executor.

## Lifecycle events

| Event | Behaviour |
|---|---|
| `nativeOpen(deviceName, source)` | Claims NATIVE (BUSY if Dart holds it or a teardown is in flight), requests permission if needed, opens/adopts the connection and calls `sdr_v2_open_usb(fd, source)` on the control thread. A second call with the same source is an idempotent `OK`; another source returns `INVALID_STATE`. On failure the claim is dropped and a connection opened for it is closed. |
| `nativeConfigure/Start/Stop/Stats` | Forwarded to the session on the control thread. `NOT_FOUND` / `null` stats when no session exists. Retune/gain follow ABI 2: stop → configure → start. |
| `nativeClose(deviceName)` | stop → close → destroy on the control thread, then Java connection close and NATIVE release on the main thread. Dart cannot claim the device until all of that has finished. Repeated calls never close twice. |
| Dart `open`/`close` | Unchanged contract. Dart `open` gets BUSY while native holds the device; Dart `close` gets BUSY instead of pulling the connection away from native. |
| USB detach (`ACTION_USB_DEVICE_DETACHED`) | Dart-held: connection closed immediately (as before; Dart sees ENODEV). Native-held: connection taken out of the map at once, the device is marked *retiring*, the session is stopped/closed/destroyed on the control thread (a reader that already failed reports `SDR_DEVICE_GONE`/`SDR_IO_ERROR` in stats until then), then the Java connection is closed once and the device released. Pending permission requests fail with `NOT_FOUND`. |
| Reconnect | A re-plugged device needs a new permission/open and gets a fresh connection and session. Claims for a name that is still retiring return BUSY, so a reconnect can never receive the old connection or have its claim released by the old teardown. |
| Activity detach / recreation | No USB effect. The `FlutterEngine` is application-owned (`SdrApplication`), so the plugin and its sessions survive configuration changes and swipe-away. |
| Foreground service | `ReceptionService` Stop (notification) and `onDestroy` call `UsbSdrPlugin.stopNativeStreams`, which stops every running native stream on the control thread; sessions and connections stay open so the controlling code can restart or close them. A native stream therefore never runs without the foreground service. Starting the service for a native stream is the caller's job (`sdr/background` `start`), as for the Dart path. |
| Engine detach (`onDetachedFromEngine`) | Pending opens fail with `DETACHED`; Dart-held connections close immediately; native sessions are closed and then their connections closed, all on the control thread (the main thread may not service callbacks any more). The executor is shut down after the queued teardown. |

## Verification

* JVM tests (`./gradlew :app:testDebugUnitTest`): `UsbDeviceLifecycleTest`
  uses manual executors and a recording fake bridge to assert the ordering
  `native.stop → native.close → native.destroy → java.close`, close-exactly-once
  under racing close/detach, BUSY during teardown, reconnect with a fresh fd,
  failed-open cleanup, foreground Stop, shutdown, and unchanged Dart open/close.
  Existing `NativeUsbSession*`, `UsbSessionOwnership` and stats tests remain.
* Not verified here: real `UsbManager` permission flow, real detach timing,
  and native stream behaviour on Android hardware remain unverified
  (`docs/native-n1-adr.md`, "Verification and acceptance boundary").

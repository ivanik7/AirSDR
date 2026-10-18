# rtl_tcp connection UI

Settings → SDR CONNECTION offers Local USB SDR and Network (rtl_tcp). Selecting
Network reveals a host/IP field and TCP port (default 1234). Apply endpoint
saves the choice and endpoint without opening a connection; Start validates both
fields, applies pending edits and starts the same native receiver used by USB.
Stop is explicit and no network reconnection is attempted automatically. Source
selection and endpoint fields are locked while running; Stop before editing.
USB enumeration cannot replace a saved Network selection. Switching back to
USB preserves the last network endpoint for the next switch. Presets and
favorites continue to change tuning/mode only, not the source.

The endpoint and source are additive keys in `native_radio.json`; legacy files
remain untouched. Invalid persisted endpoint data falls back to local USB and
127.0.0.1:1234. IPv4, hostname and IPv6 literals are accepted (the POSIX
transport uses `getaddrinfo`); no brackets are required for IPv6 in the host
field. Ports must be decimal integers from 1 through 65535. The host must be
nonempty, contain no whitespace/NUL and fit the native 255-byte UTF-8 limit.
Connection status distinguishes connecting, connected, disconnected, manual
Stop, and failure. The native error row specifies refused, timeout, malformed
server header or disconnect, with Retry after failure. Sample rates use the
native rtl_tcp rate list; 250 kS/s clamps WFM bandwidth to the ABI's Nyquist
limit. Only implemented manual RF gain is offered; unsupported AGC, PPM,
Bias-T, direct sampling and offset tuning are not presented as working
network controls. IQ and audio remain entirely in the native receive path.

Android already declares `android.permission.INTERNET`. The native client uses
POSIX TCP sockets, not Android HTTP APIs; no cleartext HTTP/network-security
manifest exception is needed.

## Verification

- `flutter analyze`: no issues. `flutter test --concurrency=1 --reporter
  compact` with `SDRCORE_V3_PROBE_LIBRARY` pointing to the worktree's native
  host build: 568 passed, 14 skipped. New widget tests at 344×690 dp exercise
  validation, USB↔network selection, hotplug, connecting/connected/refused,
  Stop/Retry and no automatic reconnect. New persistence tests cover offline
  restart and invalid saved values (RED before GREEN).
- `cmake -S native -B build/native-host-tests -DCMAKE_BUILD_TYPE=Debug`, build,
  then `ctest --test-dir build/native-host-tests --output-on-failure -E
  'sdrcore_host_usb|sdrcore_host_rtl_gain'`: 48/48 passed. Excluded two tests
  that could access physical USB hardware. The new real-FFI Dart loopback test
  sends generated 60 kHz tone IQ to a local rtl_tcp v1 server, asserts native
  samples and FFT, retunes, stops and restarts: passed. No live RF used.
- `flutter build linux --debug` and the serialized `locked-build apk --debug`:
  passed. The debug APK declares `android.permission.INTERNET` (aapt dump).
- `SDR_UI_SCREENSHOT=... xvfb-run -a flutter test
  test/ui/legacy_settings_connection_test.dart`: passed; captured 344×690 dp
  widget screenshot under `build/rtl-tcp-settings-344.png` (Flutter test font
  is Ahem, so the screenshot is for geometry only). Android emulator
  `emulator-5554` installed/ran the native APK, selected Network and attempted
  offline `127.0.0.1:1234`; it displayed connection refused and Retry. No
  Android permission prompt is expected for INTERNET. Emulator screen captures
  under `build/emulator-network*.png` show layout and error flow. The source
  selector was changed to a full-width stacked card after visual QA found
  overlap in the initial APK; final widget tests cover it.

A network SDR with physical RTL-SDR hardware, real RF, audible output, and
Android emulator-to-host successful streaming were not tested. No physical
phone was used. Linux host UI verification used xVFB widget rendering and
local FFI loopback rather than opening the production desktop app, to avoid
USB auto-start on any attached dongle.

# rtl_tcp native source (ABI v3)

`native/third_party/sdrpp_rtl_tcp/` contains the SDR++ rtl_tcp client source,
its reference oracle and port notes. `native/src/rtl_tcp_adapter.cpp` owns the
POSIX socket/handshake; the existing single native producer and DSP/audio
workers handle the source exactly like CU8 RTL USB ingress. No IQ crosses FFI.

## Contract

- `sdr_v3_open_rtl_tcp(handle, host, byte_count, port)` copies host and opens
  without network I/O; valid on IDLE, with UTF-8 host 1..255 bytes, port
  1..65535. `sdr_v3_set_controls` accepts RTL rates (225001..300000 or
  900001..3200000), 32-bit LO Hz and manual gain in tenths of dB.
- `sdr_v3_start` returns after native workers start. `sdr_v3_rtl_tcp_link`
  returns 0 while connecting and 1 after the 12-byte `RTL0` greeting and
  startup commands. `snapshot.state=SDR_ERROR`, sticky `last_error` and
  `error_sequence` report refused/DNS failure (-9), deadline (-8), malformed
  greeting (-10), EOF (-5) or generic I/O (-4); UI polls and calls stop to
  synchronously join/release DSP/audio and foreground-service ownership.
- Startup sends center frequency (1), sample rate (2), manual gain mode (3),
  then manual gain (4) as five-byte big-endian commands. Retune and gain use
  the same native tuner worker; rate changes stop and reopen one connection.
  Stop cancels a pending resolver wait, socket connect, greeting and IQ read.
  No automatic retry; explicit retry reopens and reapplies controls. USB
  enumeration does not change an explicitly chosen network source.
- `NativeRadioController.selectNetworkSource(host, port)` and
  `selectUsbSource()` are the controller-facing integration hooks; source
  selection, saved endpoint, input form and mobile layout belong to the
  dependent UI card. Until then the app has no network source picker.

## Compatibility and limits

Only classic rtl_tcp v1 is accepted: 12-byte `RTL0` greeting and unsigned
8-bit interleaved IQ. The header has no feature negotiation or command ACK.
Manual gain in 0.1 dB is sent via opcode 4; do not confuse it with SDR++'s
server-specific gain-index opcode 13. PPM, tuner/RTL AGC, direct sampling,
offset tuning and bias-T are deliberately not exposed until the relevant
server/hardware capabilities can be represented honestly. IPv4, DNS and
literal IPv6 use `getaddrinfo` on POSIX. Windows returns unsupported on start
(no Winsock adapter). Android declares `INTERNET`; native TCP sockets do not
use Android HTTP cleartext policy. The existing foreground service owns the
receiver lifecycle. Linux Android emulator network flow remains unverified.

## Verification

- `cmake -S native -B build/native-host-tests -DCMAKE_BUILD_TYPE=Debug &&
  cmake --build build/native-host-tests -j4`: passed. `ctest --test-dir
  build/native-host-tests --output-on-failure -E
  'sdrcore_host_usb|sdrcore_host_rtl_gain'`: 48/48 passed, excluding tests
  that may open physical USB hardware.
- `sdrcore_rtl_tcp` in-process loopback: refused, fragmented greeting, malformed
  greeting, EOF, 3s timeout, explicit retry, Stop during greeting/idle IQ,
  restart after EOF, odd-byte IQ counts, FFT from generated IQ, live tune/gain,
  rate-reconnect and exact command ordering. `sdrcore_rtltcp_oracle` builds the
  original SDR++ client with minimal mocks and compares all command opcodes
  and complex-float conversion against the port on identical IQ: passed.
- `flutter analyze`: no issues. `SDRCORE_HOST_LIBRARY=... flutter test
  --concurrency=1 --reporter compact`: 567 passed, 9 skipped. An unrelated
  decoder descriptor assertion was updated for the already-present MeshCore
  and DMR engines so the native-host suite is current.
- `~/prj/bin/locked-build apk --debug`: passed. `aapt dump permissions` on
  the produced APK includes `android.permission.INTERNET`.
- No Android emulator is connected (`adb devices -l` empty), so runtime
  Android network/socket/background behavior was not verified. No physical
  phone or live RF was used; audible sound was not tested. App-side network
  selection/endpoint persistence and Linux xVFB UI QA await the UI card.
- Subagent implementation delegation was attempted but unavailable because
  the delegation provider reported a rate limit; this implementation was
  performed in the task worktree instead.

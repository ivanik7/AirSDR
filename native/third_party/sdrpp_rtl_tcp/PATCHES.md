# SDR++ rtl_tcp source provenance and local port

- Upstream: https://github.com/AlexandreRouma/SDRPlusPlus, commit
  `8c9f5ee8fe405775bfcd62c8c8f8c0fc928a64af` (local `~/prj/sdrpp`).
- Source: `source_modules/rtl_tcp_source/src/rtl_tcp_client.{h,cpp}`;
  `upstream/` is an uncompiled copy (formatting condensed in the `.cpp`),
  `rtl_tcp_source/src/` is the compiled port. License: GPL-3.0 (SDR++).
- Dependency substitutions: SDR++ `net::Socket` and `dsp::stream` are replaced
  with send/receive/sample callbacks; the app's existing producer, bounded IQ
  ring, DSP, decoder and audio workers remain the only receiver. The adapter
  owns cancellable `getaddrinfo`/nonblocking POSIX sockets, the three-second
  connect+12-byte `RTL0` handshake deadline, and releases the socket on Stop.
  SDR++'s client and `main.cpp` never validated the `RTL0` header themselves;
  that safety check is in the adapter, before any tuning commands or IQ.
- Preserved from SDR++: ten command opcodes and their big-endian five-byte
  packets; u8 IQ to complex float `(byte-128)/128`; buffer size `rate/200`;
  startup ordering from `main.cpp` where applicable. The adapter converts the
  resulting exact multiples-of-1/128 float back to CU8 because the shared
  native ingress takes CU8 and normalizes with the existing receiver DSP.
  The independent `sdrcore_rtltcp_oracle` builds the original with minimal
  net/stream shims, compares its command trace and converted samples to this
  port for the same fixed IQ and every opcode used by SDR++.
- Narrowed capabilities: ABI v3 has frequency/rate/manual gain only. The
  common v1 startup subset sends frequency, rate, gain mode=manual, gain in
  tenths of dB (opcode 4), avoiding zero-valued PPM/AGC/direct sampling/
  bias-T/offset-tuning commands whose support differs among rtl_tcp forks.
  The upstream gain-index opcode 13 needs a server-specific tuner table;
  do not treat a gain dB value as an index. No remote hardware AGC or extended
  controls are advertised. Header magic does not identify the server version
  or guarantee particular tuner capabilities; no server ACK exists for writes.
- POSIX socket adapter runs on Linux, Android and macOS; Windows currently
  reports `SDR_UNSUPPORTED` for network start (the existing SDR++ `net` shim
  was removed, and a Winsock transport has not been ported). IPv4, DNS and
  literal IPv6 work via `getaddrinfo(AF_UNSPEC)` on POSIX.
- The test server uses only generated IQ on loopback. No live over-the-air
  reception or physical USB receiver is used for acceptance.

# Decoder JSONL recording (issue #1)

The production recorder now accepts `SDR_RECORD_DECODER_LOG` alone or with IQ
and/or continuous/squelch audio. `sdr_record_start` validates comma-separated,
unique selected IDs against the installed native decoder registry plus `rds`.
Only events actually enqueued by a native decoder or RDS enter the log writer;
the UI decoder FIFO remains intact. A session with no selected events creates
no log file and retains an honest zero-byte status.

Each selected decoder opens its own exclusive `.jsonl` file on the first valid
event. Subsequent events append to that file through the same bounded native
writer thread; collisions use the recorder's `_2` through `_99` suffix. One
line carries UTC timestamp, decoder ID, result kind, stream generation,
applied tuned frequency and sanitized event JSON. The line is at most 16 KiB;
invalid JSON and oversized rows increment `log_dropped_events` rather than
emitting invalid JSON. The separate 1 MiB queued-log budget fails the session
on overflow, with a stream-specific error; I/O/provider failure also ends the
recording while reception continues. Stop joins the writer and closes all log
files. Neither samples nor log payloads are serialized through Dart.

Privacy is a positive allowlist by decoder. Meshtastic/MeshCore persist only
non-identifying PHY/protocol metadata (not packet bodies, IDs, messages,
channel names or configured keys); DMR excludes addresses, alias, location
and privacy data. RDS persists public station state, SSTV image line bytes and
frame metadata, ADS-B broadcast aircraft fields, and rtl_433 weather/device
metrics from their respective real emitted events. Unknown future event keys
are dropped until explicitly audited.

## Verification

- RED before GREEN: `sdrcore_record_writer_test` initially failed linking
  `Recorder::offer_log`; after implementation it passes fixture filtering,
  no-event start, escaped JSON, privacy, per-ID files, append/retune generation,
  IQ+logs combination, missing-folder failure, readback and byte counters.
- `sdrcore_record_abi_test` exercises a real synthetic receiver: RDS RBDS
  reset generates one log line while the same event remains available through
  `sdr_decoder_poll`. Duplicate IDs are rejected; session status and file
  readback agree.
- `cmake --build build/native-host-tests -j4 -- -s && ctest --test-dir
  build/native-host-tests --output-on-failure`: 55/55 passed on Linux.
- `flutter analyze --no-pub`: no issues after `flutter pub get`.
- `SDRCORE_HOST_LIBRARY=$PWD/build/native-host-tests/libsdrcore.so flutter
  test --no-pub --concurrency=1 --reporter compact`: 585 passed, 10 skipped.
- `flutter build apk --debug --no-pub`: passed.

Real encrypted packet log privacy is enforced by schema allowlists rather than
by capturing any live transmission. Android SAF actual log-file readback,
macOS/Windows runtime, real-device output and audible reception are not
verified here; the final issue #1 integration/QA card owns those checks. No
physical phone or live RF was used.

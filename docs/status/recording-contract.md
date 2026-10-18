# Recording contract (issue #1; architecture only)

This handoff fixes the shared, additive v1 ABI in
`native/include/sdrcore_record_v1.h` and its Dart binding in
`lib/native/native_record_api.dart`. **No recorder is shipped by this card.**
The current native library exports no `sdr_record_*` symbols: the optional
Dart probe returns null, and the UI must not claim recording is available.
The subsequent native/platform/codec/log/UI cards implement and verify it.
Keep the existing `sdrcore_v3.h` and `RadioController` contract unchanged.

## Ownership and dataflow

There is one `SdrHandle`, one radio and one recording session per handle.
Start/stop are serialized with v3/decoder control calls. The input producer
already fills the CU8 ring for USB, rtl_tcp, file and synthetic sources;
record a copy of the **accepted, post-retune** source bytes at ingress, before
VFO shift, resampling or demodulation. Do not record stale pre-retune IQ under
a new center frequency. This is source IQ, not channel-shifted IQ. Timestamp
its sample index and applied source rate/LO; no samples traverse Dart.

The DSP consumer obtains a separate pre-playback PCM buffer from
`Receiver::process`: after resampling to **48,000 frames/s**, deemphasis,
DC block and analog AGC, but before squelch attenuation, UI volume and mute.
The existing `ProcessResult.audio` is stereo-interleaved playback PCM **after**
those controls, even when the WFM stereo preference is off (mono duplicated
into two channels); tapping `result.audio` directly would record silence on
mute. Export one recording channel in mono modes and two when WFM stereo is
selected (including while its pilot blend is zero). DMR's synthesized audio
must feed the same 48 kHz recording tap before the playback gain/mute stage;
baseband decoder selection must not invent analog audio. Explicitly test
squelch-disabled and DMR transitions. The output rate is determined by the
DSP, **not** the input IQ rate or the 24 kHz SSTV decoder tap. Audio format
changes are latched at start, not applied mid-session.

The current squelch boolean is the **last detector state in a whole processed
IQ block**, not a per-frame edge. To avoid losing a short opening inside a
block, extend the DSP result with a time-ordered list of frame offsets and
open/close transitions aligned to the pre-playback 48 kHz PCM. At session
start with squelch OFF, treat it as already open and create one segment on
the first PCM frame; when OFF is selected mid-session open at that boundary,
and when leaving OFF apply the detector state. With manual/auto squelch,
open on the first frame at which the settled detector changes closed→open;
close on the first frame at which it changes open→closed. Do not include
closed-frame PCM in segment files. A stop/retune/mode/rate change closes an
open segment at the boundary; if the detector opens again start a new file.
`ProcessResult.squelch_open` and `squelch_ready` keep their v3 snapshot
semantics. Decoder messages must branch at the **native enqueue point** (RDS
and selected data decoder), not by draining the Dart UI FIFO; a log selection
may contain any available decoder ID and `rds`. Preserve decoder events for
normal UI consumers. Bounded low-rate log records carry event kind, source,
stream generation, wall-clock timestamp, applied tuned frequency and bounded
JSON payload. Never write channel keys, settings JSON or other secrets;
Meshtastic/MeshCore payload privacy requires deliberate filtering before
persisting. Only already-produced real events are eligible.

The DSP/producer never wait on disk/encoder/provider calls: copy into
**separate bounded** IQ, audio and log queues; the writer thread alone opens,
encodes, writes and finalizes files. Initial design budgets: IQ 8 MiB, audio
2 MiB, logs 1 MiB, measured in queued payload bytes; reject a block larger
than a queue and count its actual lost samples/events. Preserve temporal
order and edge/control markers; an overflow invalidates the affected output
rather than silently producing a playable-looking discontinuous file: end
the session FAILED with stream-specific error, finalize every file possible,
keep reception and other DSP paths running. Do not wait for a slow SAF
provider on the DSP worker. A single consumer/writer per session drains all
streams fairly; callbacks run without handle/provider locks. Stop/join is
synchronous and drains the bounded queues. On failed write, report first
error and attempt header finalization/close; an I/O failure may leave a
partial file, which must be reported honestly. Distinguish ENOSPC, missing or
revoked folder, nonseekable fd and unexpected I/O.

`SdrRecordStatus` is an atomic copy and is the UI polling source. Elapsed
session time is CLOCK_MONOTONIC start→now, frozen on stop/failure, not audio
duration; bytes count final file lengths including headers/metadata/log lines
exactly once even after a seek-based header rewrite. Status retains last
session counters/error after stop, reset by a subsequent successful start.
The optional low-rate `SdrRecordNotify` signals the final transition once;
Dart polls by default, Android native JNI may register it. Never invoke a
synchronous Dart FFI callback from a native writer thread. User stop produces
IDLE/USER, receiver stop/close/destroy produces IDLE/RECEIVER; async radio
error ends the session with RECEIVER. Folder/write/queue failure produces
FAILED/ERROR with the first error and stream, then `stop` acknowledges it.
Successful retunes, VFO, mode, WFM stereo, squelch, mute and volume changes
continue the session and start new audio/IQ files when a format/rate/LO
boundary changes (never mislabel a file). Keep running in background as long
as the Android foreground receiver service remains running; if it stops,
recording stops as part of receiver shutdown.

## Platform folder contract

The persisted **locator** is `file:<absolute native folder>` on desktop or
`content:<persisted SAF tree URI>` on Android; it is not a file path for
`content:`. The platform picker owns display name and permission state.
`SdrRecordCreateFile` runs only on the writer thread and returns a unique,
seekable read/write fd for a UTF-8 display name and MIME type, or a mapped
error. Desktop opens with O_CREAT|O_EXCL (Windows `_wopen` equivalent) inside
the chosen directory. Android uses ACTION_OPEN_DOCUMENT_TREE,
`takePersistableUriPermission` for this tree only, then a JNI provider that
attaches the writer thread and creates the child document with
DocumentsContract/ContentResolver, verifies seekability, and detaches or
closes the returned fd correctly. The folder is never silently replaced on
revocation. A provider must not retain borrowed string pointers. Registration
replaces/unregisters safely after all in-flight calls; the Android app
registers it before Record is enabled. No broad storage permission is needed.
A SAF provider's name collision semantics must be checked: providers that
auto-rename must query the name first and verify the created name; never
truncate a sibling document. Suffix `_2`…`_99` on collision, otherwise fail
NAME_EXHAUSTED. Seekability is mandatory for header correction; loss of access
at any time ends the session with an error. The writer owns/always closes fd.

## On-disk formats and names

Raw IQ is SigMF 1.0.0: `.sigmf-data` = interleaved unsigned 8-bit complex
`cu8` byte pairs exactly as source supplies; `.sigmf-meta` UTF-8 JSON with
`global.core:datatype="cu8"`, `core:sample_rate` (Hz),
`core:recorder="AirSDR"`, and `captures[]` with `core:sample_start`,
`core:frequency` (applied LO Hz), `core:datetime` (UTC RFC3339 with ms).
Split data/metadata pairs on sample-rate/LO discontinuities; record each
pair's actual capture point and do not claim seamless IQ across a retune.
Create empty meta for a zero-sample segment only if a data file exists.
WAV = RIFF PCM signed 16-bit little endian at 48 kHz, 1/2 channels per
actual DSP layout. WAV's 32-bit RIFF/data size limit requires rotation before
4 GiB rather than header wrap. FLAC uses native libFLAC, MP3 native LAME,
and Ogg Opus native libopus+libogg, bundled from source under compatible
licenses/provenance; capability bits are set **only** for linked and tested
encoders. Opus resamples 48 kHz PCM as necessary and records the true codec
sample rate. No system codec fallback and no unsupported format stub.

Stem `AirSDR_YYYY-MM-DD_HH-MM-SS_<frequency MHz>_<MODE>` uses the local
clock at file creation (config's UTC offset), a sanitized bounded mode and
frequency from applied controls, and a unique collision suffix. Per-squelch
files add `_sq<N>`. IQ metadata uses the same stem. Decoder JSONL files use
`_<decoder-id>.jsonl`; each line includes an ISO UTC timestamp and one real,
escaped event, with a fixed maximum record size. Invalid JSON or excessive
payloads count as dropped, never truncated into malformed JSON. Folder
creation is asynchronous after `start`; UI treats ACTIVE as pending until the
first file is written and watches `last_error`/FAILED. An empty logs-only
session with no decoder events is valid and reports zero event bytes.

## Implementation handoffs

- Native IQ/audio card: implement ABI, writer and taps in
  `native/src/sdrcore.cpp`, `native/src/dsp/receiver.*` and new native recorder
  sources. Add tested error/lifecycle notification and real capabilities.
  Existing source/playback/decoder behavior must be preserved. Regression
  fixtures must be generated/recorded IQ, never live RF.
- Folder card: implement desktop chooser + Android SAF JNI provider adhering
  to the fd contract, register it before recording starts, and prove a real
  emulator document write/readback and revoked permission error.
- Codec card: vendored GPL-compatible source and actual ffprobe-verified
  WAV/FLAC/MP3/Ogg Opus outputs; no capability until linked.
- Decoder logs card: branch real bounded event types at native enqueue,
  apply an explicit ID filter and privacy policy, and verify real fixture
  events/empty sessions.
- UI/integration card: use `FfiNativeRecordApi.tryOpen` and capabilities
  rather than assuming availability; persist only locator, stream choices,
  format and bitrate; show status/errors and route missing settings honestly.

Tests in this architecture card exercise C/Dart struct layouts and FFI
marshalling with a test-only C fixture. That fixture is **not** the recorder
and does not establish any file/codec or reception behavior. Production
native lifecycle/notification, host IQ/WAV, emulator SAF and multiplatform
codecs remain unverified until their respective cards.

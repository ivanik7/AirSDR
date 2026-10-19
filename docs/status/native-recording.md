# Native IQ and WAV recording (issue #1)

This implementation exports `sdrcore_record_v1.h` from the production native
library. It supports any combination of source-IQ SigMF, continuous PCM WAV,
and one PCM WAV per squelch opening. Decoder logs and FLAC/MP3/Ogg Opus are
not advertised by this build; separate issue #1 cards add those outputs.
The UI and platform picker are likewise separate integration work. No IQ or
PCM is passed through Dart.

## Data and lifecycle

The v3 receiver copies post-retune CU8 source pairs accepted by the DSP
consumer. This includes synthetic, file, USB and rtl_tcp ingress. Each SigMF
pair contains exact interleaved unsigned I/Q bytes in `.sigmf-data`, and
`.sigmf-meta` declares `cu8`, source sample rate and applied center-frequency
capture point. A new pair is opened on source rate, center frequency or mode
change. Blocks invalidated by a retune are deliberately not recorded.

The DSP also yields 48 kHz float PCM before squelch attenuation, UI mute and
volume. WAV conversion is signed little-endian 16-bit PCM: mono normally, or
two channels when WFM stereo is selected. DMR synthesized audio replaces the
analog tap before playback gain. Baseband data-only decoders produce no audio
recording tap. The DSP emits frame-indexed detector transitions within each
processed IQ block; per-squelch files contain only open-state frames. With
squelch OFF a session opens at the first PCM frame and stays in one segment
until stop or a rate/layout/LO/mode boundary. A new segment is opened after
such a boundary when the detector remains open. Continuous and per-squelch
WAV can run together; a continuous WAV also rotates on such boundaries and
before the RIFF size limit.

One writer thread creates and finalizes files. Producers only copy into a
bounded 8 MiB IQ queue and 2 MiB PCM queue; overflow fails the entire
session, counts dropped samples/frames, and does not stop reception. The first
file creation is asynchronous. Disk full, inaccessible folder, nonseekable fd
and exhausted collision suffixes appear in status, with stream-specific error
and a FAILED terminal state; `stop` acknowledges FAILED. An I/O failure may
leave a partial file. Other completed WAV headers are finalized on Stop or
receiver shutdown. Status reports monotonic elapsed time and actual cumulative
file lengths (including headers and metadata). No-sample sessions have zero
files. Filenames use the local time offset, applied MHz/mode, `_sq<N>` on
squelch segments, and exclusive `_2`…`_99` collision suffixes.

`file:` folders are built in; platform providers register other schemes via
`sdr_record_set_provider` and must return unique seekable fds. This native
card does not implement Android SAF registration or desktop folder UI.
Provider replacement waits for outstanding calls; callbacks cannot reenter
commands on the same handle. Stop drains the bounded queue and joins the
writer; do not invoke it from a provider or notification callback.

## Verification and limitations

`native/tests/run_host_tests.sh` exercises synthetic-source recording through
the exported ABI plus direct recorder/edge fixtures. The WAV headers and SigMF
sample bytes are checked in native tests; generated stereo WAV was inspected
with ffprobe (`pcm_s16le`, 48000 Hz, 2 channels). The Dart FFI suite checks
ABI marshalling. `flutter analyze`, `flutter test` and Android debug build are
quality gates for the integration branch. No live-air or real-phone tests are
permitted. Audible output, Android SAF, desktop picker, hardware USB/rtl_tcp
recorded bytes, and other OS native builds remain unverified here.

The queue budgets count queued payload bytes, not in-progress worker buffers.
One source IQ block and one PCM block may be in flight in addition to those
budgets. A slow provider can make synchronous Stop wait on one in-flight file
operation; ordinary DSP/playback producers never wait for disk I/O.

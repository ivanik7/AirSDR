# Recording integration QA (issue #1)

This report covers the combined recording branch on a Linux host and Android API
35 x86_64 emulator. No physical phone or live RF was used. A generated CU8 IQ
source exercised the actual native receiver; audio and IQ never crossed Dart.
The feature is **not fully accepted** until the gaps below are addressed.

## Verified

- `cmake --build build/native-host-tests -j4` and
  `ctest --test-dir build/native-host-tests --output-on-failure -j4`:
  55/55 passed. The recording codec matrix uses ffprobe/ffmpeg on 48 files from
  24 channel/stream/format cases and eight short clips. Existing native ABI
  fixtures cover generated source bytes, retune/mode/rate boundaries, receiver
  shutdown, squelch slicing, missing folder, write errors and bounded queues.
- `flutter analyze --no-pub`: no issues.
  `SDRCORE_HOST_LIBRARY=$PWD/build/native-host-tests/libsdrcore.so flutter test
  --no-pub --concurrency=1 --reporter compact`: 591 passed, 10 skipped.
  UI tests exercise persisted stream, format and bitrate choices, and format
  changes applying to the next session; these are mocked-controller checks.
- `flutter build apk --debug --no-pub`: succeeded. `flutter build linux
  --debug --no-pub`: succeeded, including the source-built native codecs.
- `LLVM_MINGW_ROOT=... cmake -S native -B build/native-windows -G Ninja
  -DCMAKE_TOOLCHAIN_FILE=$PWD/native/cmake/llvm-mingw-x86_64.cmake
  -DCMAKE_BUILD_TYPE=Release` followed by `cmake --build build/native-windows
  --target sdrcore -j4`: Windows x86_64 `sdrcore.dll` cross-build succeeded
  with llvm-mingw 20261006. This proves linking, not Windows runtime output.
- `flutter test integration_test/recording_emulator_test.dart -d emulator-5554
  --no-pub --reporter expanded`: actual native synthetic receiver, JNI writer
  and SAF Documents tree; 4 combined-stream sessions produced 20 files in
  WAV, FLAC, MP3 and Ogg Opus (continuous and per-squelch), CU8 SigMF data and
  metadata, and selected real native RDS reset-event JSONL. Native status
  reported ACTIVE, then IDLE/USER, with nonzero IQ/audio/log/byte counters;
  receiver remained RUNNING across starts/stops. Mute was enabled and volume
  zero; nonzero recorded audio proves the pre-mute PCM tap. A second run also
  passed, but Flutter's integration harness reinstalled the app and reset its
  saved folder, so it **does not** establish cold-process SAF grant persistence.
  The final emulator regression revoked the selected tree, confirmed the
  saved locator remained but became inaccessible, and observed native
  FAILED/FOLDER_UNAVAILABLE on the next IQ write while reception stayed
  RUNNING; Stop acknowledged the failed session.
- `adb -s emulator-5554 pull /sdcard/Documents/AirSDR-Recording-QA
  build/recording-qa` and `python3 tool/verify_recording_emulator.py
  build/recording-qa/AirSDR-Recording-QA AirSDR_2026-10-20_17-18-2`:
  20 actual SAF files verified. ffprobe found all four codecs at 48 kHz
  stereo with durations 0.259–0.288 s; ffmpeg decoded nonzero PCM. Four SigMF
  pairs had exact `.sigmf-data`/`.sigmf-meta` siblings, `cu8`, 300000 samples/s,
  100000000 Hz, and the deterministic incrementing-byte source oracle.
  Four JSONL files parsed and contained RDS reset events. The `.sigmf-meta`
  MIME type is deliberately octet-stream: Android DocumentsProvider appended
  `.json` to `application/json`, breaking the SigMF sibling name. A native
  provider regression test checks this MIME contract.
- `flutter test integration_test/recording_persisted_saf_emulator_test.dart
  -d emulator-5554 --no-pub --no-uninstall --reporter expanded` on the API
  35 emulator: first run selected the Documents/AirSDR-Recording-QA SAF tree,
  wrote an IQ SigMF pair (147456 CU8 bytes), and passed. After
  `adb -s emulator-5554 shell am force-stop net.ivanik.sdr_flutter`, the same
  test ran again without any picker: `previous=true`, grant validation passed,
  and JNI/native recording created another pair while reception stayed
  RUNNING. The second `flutter test` did reinstall the debug APK in place
  (`--no-uninstall` retained its data), so this establishes cold-process grant
  persistence **across an in-place APK reinstall**, not an untouched-package
  launch. `adb pull` and `python3 tool/verify_recording_cold_saf.py
  build/recording-cold-qa AirSDR_2026-10-23_00-07-43
  AirSDR_2026-10-23_00-08-12` verified both distinct pairs' CU8 byte oracle,
  sample rate (300000/s), frequency (100000000 Hz), and metadata names.
- PR #6 exact-head Actions run 39427862136 at `4c86888`: Analyze and test,
  Android APKs, Linux packages/install, macOS app and Windows DLL/app all
  succeeded. These are build/adapter results, not runtime picker checks.

## Still unverified

- A pure cold-process restart without the in-place APK reinstall performed
  by the Flutter test harness; revoke **during** an already-writing session,
  and disk-full recovery on the emulator. A revoke before the next session
  was exercised. Native host and adapter tests cover related error cases but
  cannot prove the remaining Android behavior.
- Linux GTK folder picker interaction and desktop end-to-end UI file creation.
  The Linux build and temporary-directory adapter tests pass, but no native
  chooser interaction was exercised here.
- macOS native build, Windows application packaging, native pickers/bookmarks,
  and actual codec output at runtime on both systems. The Windows DLL built
  locally by cross-compilation, but was not run on Windows. PR CI can establish
  build and adapter-test results, not interactive picker/recording behavior.
- Audible playback or device-specific background lifecycle: only a listener
  can confirm sound; no real device or over-the-air test is permitted.

Do not mark issue #1 acceptance complete solely from these checks.

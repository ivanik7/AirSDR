# Recording UI handoff

The Receive frequency row has a Record/Stop control beside mute. Native status is polled at 250 ms intervals for elapsed time, cumulative bytes, and errors; reception and mute remain independent. The Settings → Recording section owns the folder chooser, output checkboxes for IQ, continuous audio, per-squelch audio and available decoder logs, audio format and MP3/Ogg Opus bitrate. Choices persist in shared preferences; format/bitrate edits while recording apply on the next start. Format entries are gated by the native recording capability mask.

A missing/revoked folder routes Record to the Folder control; an empty output selection routes to the What to record dialog. Failed writers surface an error and can be acknowledged before a subsequent start. Files and sample streams remain in native code.

## Checks on the feature branch

- `native/tests/run_host_tests.sh build/native-host-tests`: 55/55 CTests plus standalone checks passed; one overflow probe warned that no overflow occurred in its optional ten-trial stress check.
- `flutter analyze --no-pub`: no issues.
- `SDRCORE_HOST_LIBRARY=$PWD/build/native-host-tests/libsdrcore.so flutter test --no-pub --concurrency=1 --reporter compact`: 591 passed, 10 skipped.
- `flutter build apk --debug --no-pub`: passed, produced `build/app/outputs/flutter-apk/app-debug.apk`.
- `xvfb-run -a flutter test --no-pub test/ui/recording_controls_test.dart --plain-name 'Record navigates to folder, then What to record; controls and status fit 344x690'`: passed; captured the 344 × 690 dp active-recording widget screenshot. The test renderer did not load the production fonts, so this is a geometry check rather than a typography acceptance image.
- Android API 35 emulator: installed the debug APK, inspected Receive and Settings at 720 × 1560 pixels, tapped Record with no folder and confirmed the visible prerequisite plus Choose button, opened the output dialog and saw the real decoder log checkboxes. Selected IQ, applied, cold-relaunched and read back `IQ · No logs` in Settings. No physical phone or live RF was used.

Not verified in this UI card: actual recording through Android SAF (including native codec/log file readback), running receiver status updates on Android, and real hardware/over-the-air playback. Those belong to the end-to-end recording QA card using generated or prerecorded IQ only; audible sound remains user-confirmed only.

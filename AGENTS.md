# AGENTS.md — sdr_flutter

Flutter Android and Linux app. The production SDR USB driver, DSP, demodulation,
and audio path run in C/C++; Dart/Flutter handles the UI and control. The Dart SDR
receiver was removed after native acceptance on the Linux host. Preserve native
receiver behavior and user data. Decoder backends are future work.
Receiver/DSP/UI acceptance uses the USB-attached RTL-SDR Blog V4 on the Linux host.
Android behaviour is checked on the Android emulator. Never use a real phone.
License: GPL-3.0. Keep chat replies to the user concise and in Russian.

## Language policy
- The project is English-only: documentation, code comments, test names, user-facing UI strings, and agent/subagent prompts.
- Exceptions: upstream sources under `native/third_party/`, intentional non-ASCII test vectors, and legacy data that must match old saves byte for byte (e.g. the v1 favorites migration pool).
- This policy covers project files only; chat replies to the user stay in Russian.

## Read before working
- `README.md` — current layers and directories.
- `docs/` — native ABI, ADRs, decoder architecture, desktop/emulator/CI notes.
- `docs/status/*.md` — layer APIs and known gaps.

## Environment
- Use the Flutter SDK version required by `pubspec.yaml`, JDK 21, and the Android SDK/NDK.
- Run no more than one Gradle build at a time. After a build and before the full `flutter test` suite, stop Gradle/Kotlin daemons if timer-based tests become slow (`(cd android && ./gradlew --stop); pkill -f kotlin-daemon`).
- `android/gradlew` and `gradle-wrapper.jar` are gitignored and missing from new worktrees; copy them from the main checkout if needed.

## Contracts (do not change without a task-level reason)
`native/include/sdrcore_v3.h`, `lib/native/native_radio_controller.dart`, and
`lib/ui/radio_controller.dart`. Preserve the `RadioController` UI contract and
commit any C ABI changes before parallel implementation.
Build native libraries from source with license checks; never route high-rate IQ or audio samples through Dart.
Do not restore deleted Dart receive/DSP code as a shortcut for future UI tasks.

## Delegating large tasks
When a task spans independently implementable programming subsystems (for example USB drivers,
C ABI/FFI, DSP, Android lifecycle, and tests), the lead agent first fixes their shared contract,
then **delegates implementation**, not merely research, to subagents.
Give each child disjoint file ownership or a separate worktree/branch, the shared contract, and testable acceptance criteria.
The lead integrates the results, runs native and Flutter tests itself, performs the single Gradle build,
and owns Linux-host and emulator QA. Do not manufacture delegation for a single indivisible fix. If delegation is unavailable,
state why in the task report; do not describe lead-authored code as subagent work.

## UI invariants
- One real receive channel: one VFO, one audio stream. Saved-channel scanning is sequential on that one receiver; do not add fake multi-channel indicators.
- At rest, `centerFrequency == tunedFrequency`, `vfoOffset == 0`, with the marker centered on the spectrum. During a frequency drag, an offset within the band is allowed; End/Cancel retunes once and recenters.
- Preserve the legacy UI and favorites (Receive / Presets / Settings tabs, `kChannelPool`).
- Show unimplemented controls honestly as unavailable/later, not as fake working switches.

## Quality gates
1. `flutter analyze` — no issues.
2. `flutter test` — green; each fix gets a regression test (RED before GREEN).
3. `flutter build apk --debug` succeeds (release: `--release --target-platform android-arm64`).
4. Check device-visible receiver/UI changes on the Linux host with the attached RTL-SDR (`xvfb-run`, screenshots, WAV); check Android-only behaviour on the Android emulator (`docs/android-emulator.md`). Say explicitly what stayed unverified.
Never present a stub as finished. Label anything not tested as unverified.

## Verification
- Verify with unit, widget, and e2e tests, by running the app on the computer (Linux host, `xvfb-run`), or on the Android emulator.
- Never use a real phone: no `adb` to physical devices, no installs, screenshots, or USB permission dialogs on a phone.
- Only the user can confirm audible sound; an audio sink reporting "started" is not proof.

## Git
- Each task uses its own worktree `.worktrees/<task>` on branch `wt/<task>`. Commit regularly.
- When done: run gates in the worktree, merge `wt/<task>` into `master` only when the main checkout is clean, then rerun `flutter analyze && flutter test` on master and build the APK as applicable.
- After every merge into `master` that passes those gates, run `git push origin master` (GitHub `ivanik7/AirSDR`). Fast-forward only: never force-push, never push `wt/*` branches. If the push is rejected, `git pull --ff-only` is not possible, or auth fails, report it in the task result instead of rewriting history.
- In the final report, list changes, exact commands/results, master commit, verified behavior, and remaining gaps. If the user must decide or act, ask a precise question.
- Put long reports in `docs/status/*.md`, not in chat. New report files must be in English.

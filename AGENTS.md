# AGENTS.md — sdr_flutter

Flutter Android and Linux app. The production SDR USB driver, DSP, demodulation,
and audio path run in C/C++; Dart/Flutter handles the UI and control. The Dart SDR
receiver was removed after native acceptance on the Linux host. Preserve native
receiver behavior and user data. Decoder backends are future work.
Receiver/DSP/UI acceptance runs on the Linux host from recorded or generated IQ files.
Never listen to live over-the-air signals for testing (see Verification).
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
3. `flutter build apk --debug` succeeds (release: `--release --split-per-abi --target-platform android-arm,android-arm64,android-x64`).
4. Check device-visible receiver/UI changes on the Linux host (`xvfb-run`, screenshots, WAV) fed from recorded or generated IQ; check Android-only behaviour on the Android emulator (`docs/android-emulator.md`). Say explicitly what stayed unverified.
Never present a stub as finished. Label anything not tested as unverified.

## Verification
- Verify with unit, widget, and e2e tests, by running the app on the computer (Linux host, `xvfb-run`), or on the Android emulator.
- Never use a real phone: no `adb` to physical devices, no installs, screenshots, or USB permission dialogs on a phone.
- Only the user can confirm audible sound; an audio sink reporting "started" is not proof.
- **No live over-the-air reception for tests.** Do not tune the RTL-SDR (or any receiver) to real signals to test, verify, accept, or debug anything: no live captures, recordings from the antenna, band scans, or waiting for transmissions, and do not ask the user to transmit (remotes, radios, beacons). Use committed/recorded IQ files, generated IQ, and oracle comparisons instead. Anything that could only be shown on live air is reported as unverified; never block a task on it.

## Git
- Each task uses its own worktree `.worktrees/<name>` on branch `feat/<name>`. Commit regularly.
- Never commit directly on `master` (no `git commit`, `git commit --amend`, `git cherry-pick`, or `git revert` while `master` is checked out). All work is committed on a task branch. Changes reach GitHub `master` only through a pull request; never merge locally and push `master` around a PR.
- Feature branch names:
  - Format: `feat/<name>`, where `<name>` is lowercase ASCII kebab-case (`a-z`, `0-9`, `-`), 2–5 words, at most 40 characters.
  - Describe the change, not the agent or the date: `feat/rds-ps-decoder`, `feat/usb-reattach-fix`, `feat/docs-cleanup`. Avoid vague names such as `feat/fix`, `feat/tmp`, `feat/test`, `feat/claude-1`.
  - The worktree directory matches the branch suffix: branch `feat/<name>` lives in `.worktrees/<name>`.
  - One branch per task; do not reuse the name of an existing or already merged branch (add a distinguishing word instead).
- For every change destined for `master`, push the task branch and open a pull request against GitHub `ivanik7/AirSDR` before merging. Never bypass the PR by merging into local `master` and pushing it, even for smaller fixes. Do not force-push `master`.
- For a large feature, the PR must deliver the **entire feature**, not a series of partial feature PRs. For example, a decoder PR includes its user interface, native implementation and integration, tests, and relevant documentation. Subagents may work on separate branches/worktrees, but integrate their work into the feature branch and open one complete PR.
- If the task comes from a GitHub issue, use exactly one PR for that issue. Link the issue in the PR. If the issue is too large or poorly scoped for one complete PR, tell the user before implementation and propose splitting the issue; do not silently create multiple PRs for it.
- Run the applicable quality gates on the feature branch, review the complete diff, and open the PR. Merge only after the feature is complete and checks pass. After merging through GitHub, verify the PR's merged state and update the local `master` with a fast-forward pull only if the main checkout is clean; do not overwrite unrelated local changes.
- In the final report, list changes, exact commands/results, the PR URL and status, verified behavior, and remaining gaps. If the user must decide or act, ask a precise question.
- Versions and releases: `version:` in `pubspec.yaml` is the only hand-written version; cut releases with `tool/release.sh X.Y.Z` (`docs/releasing.md`).
- Put long reports in `docs/status/*.md`, not in chat. New report files must be in English.

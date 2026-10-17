# AGENTS.md — sdr_flutter

Flutter Android and Linux app. The production SDR USB driver, DSP, demodulation,
and audio path run in C/C++; Dart/Flutter handles the UI and control. The Dart SDR
receiver was removed after native acceptance on the Linux host. Preserve native
receiver behavior and user data. Decoder backends are future work.
Receiver/DSP/UI acceptance uses the USB-attached RTL-SDR Blog V4 on `debian-ai`;
Android-only checks belong to the separate non-blocking P1 phone card. Do not
block other cards waiting for the phone.
License: GPL-3.0. Ivan owns the project; keep chat replies to him concise and in Russian.

## Language policy
- The project is English-only: documentation, code comments, test names, user-facing UI strings, agent/subagent prompts, and kanban task bodies.
- Exceptions: upstream sources under `native/third_party/`, intentional non-ASCII test vectors, and legacy data that must match old saves byte for byte (e.g. the v1 favorites migration pool).
- This policy covers project files only; chat replies to Ivan stay in Russian.

## Read before working
- `README.md` — current layers and directories.
- `~/prj/docs/40-native-core-plan.md` and `~/prj/docs/10-architecture.md` — native architecture;
  `~/prj/docs/30-openwebrx-decoders-plan.md` — future decoder sources. Historical Dart-port
  reports and `~/prj/docs/WORKER_RULES.md` are reference material, not architecture policy.
- Topic reports `~/prj/docs/01..04-*.md` (sources, DSP, waterfall/UI, alternatives) when relevant.
- `STATUS-*.md` in the repo root — layer APIs and known gaps; `~/prj/docs/device-qa.md` — prior phone QA.
- The `flutter-android-development` skill (including `references/sdr-port-notes.md`), and `c-driver-oracle-trace-diff` for driver verification.

## Environment
- `source ~/prj/env.sh` before flutter/dart/adb (Flutter 3.47.5, JDK 21, Android SDK/NDK under `~/sdk`; no sudo assumed).
- References: `~/prj/sdrpp` (SDR++), `~/prj/ref/{rtl-sdr,hackrf,hackrf_android,RFAnalyzer,rtl_tcp_andro-,legacy-sdr-ui,android-sdr-kit,openwebrx}`.
- VM: 11 GB RAM, 8 cores. Run no more than one Gradle build at a time. After a build and before the full `flutter test` suite, stop Gradle/Kotlin daemons if timer-based tests become slow (`(cd android && ./gradlew --stop); pkill -f kotlin-daemon`).
- `android/gradlew` and `gradle-wrapper.jar` are gitignored and missing from new worktrees; copy them from the main checkout if needed.
- Keep git identity repository-local. New commits: author `Ivanik <ivan170102@gmail.com>` and trailer `Co-authored-by: Hermes Agent <hermes@hermes-agent.nousresearch.com>`.

## Contracts (do not change without a task-level reason)
`native/include/sdrcore_v3.h`, `lib/native/native_radio_controller.dart`, and
`lib/ui/radio_controller.dart`. Preserve the `RadioController` UI contract and
commit any C ABI changes before parallel implementation.
Build native libraries from source with license checks; never route high-rate IQ or audio samples through Dart.
Do not restore deleted Dart receive/DSP code as a shortcut for future UI tasks.

## Delegating large tasks
When a card spans independently implementable programming subsystems (for example USB drivers,
C ABI/FFI, DSP, Android lifecycle, and tests), lead `sdr-dev` first fixes their shared contract,
then **delegates implementation**, not merely research, to subagents with `delegate_task`.
Give each child disjoint file ownership or a separate worktree/branch, the shared contract, and testable acceptance criteria.
The lead integrates the results, runs native and Flutter tests itself, performs the single Gradle build,
and owns Linux-host QA; Android-only phone QA is tracked separately. Do not manufacture delegation for a single indivisible fix. If delegation is unavailable,
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
4. Check device-visible receiver/UI changes on the Linux host with the attached RTL-SDR (`xvfb-run`, screenshots, WAV) once L1 lands; Android-only behaviour goes to the non-blocking phone-check card. Say explicitly what stayed unverified.
Never present a stub as finished. Label anything not tested as unverified.

## Phone QA
- Samsung SM-F936B (Android 16), ADB over Wi-Fi: `adb devices -l`; address/port change. Always use `adb -s <serial>`. RTL-SDR Blog V4 (`0bda:2838`) over OTG.
- Package `net.ivanik.sdr_flutter`, user 0 (managed profile user 10 exists; do not touch it).
- `adb install -r` without clearing app data. Do not change phone settings or send ESC/double Back.
- Approve only the USB permission dialog for this app and Blog V4; do not tick "Always open" unless requested.
- Cover-screen screenshots: `screencap -p -d <display id>`; store under `~/prj/docs/screens/`.
- `dumpsys audio` showing AAudio `state:started` does not prove audible sound; only Ivan can confirm what he hears.
- See the `flutter-android-development` skill's Real phone SDR QA section for further constraints.

## Git / kanban
- Tasks come from board `sdr`; each task uses `.worktrees/<task-id>` on `wt/<task-id>`. Commit regularly.
- When done: run gates in the worktree, merge `wt/<task-id>` into `~/prj/sdr_flutter` only when the main checkout is clean, then rerun `flutter analyze && flutter test` on master and build/install the APK as applicable.
- After every merge into `master` that passes those gates, run `git push origin master` (GitHub `ivanik7/AirSDR`). Fast-forward only: never force-push, never push `wt/*` branches. If the push is rejected, `git pull --ff-only` is not possible, or auth fails, report it in the task result instead of rewriting history.
- In `kanban_complete`, report changes, exact commands/results, master commit, verified phone behavior, and remaining gaps. If Ivan must decide or act, use `kanban_block` with the precise question.
- Put long reports in `STATUS-*.md` or `~/prj/docs/`, not in chat. New report files must be in English.

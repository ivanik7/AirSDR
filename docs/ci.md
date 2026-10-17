# Continuous integration

Workflow: `.github/workflows/ci.yml` (workflow name `ci`).

## Triggers

- every push to `master` (every merged task pushes master, see AGENTS.md);
- pull requests;
- tags `v*` (also publish a GitHub release, see below);
- manual `workflow_dispatch` from the Actions tab.

Runs are grouped per ref with `cancel-in-progress` (except tag runs), so a
newer push cancels a still-running older build of the same ref.

## Toolchain

All jobs run on `ubuntu-24.04`.

| Component | Version | Source of truth |
|---|---|---|
| Flutter | 3.47.5 stable | `FLUTTER_VERSION` in the workflow |
| JDK | 21 (Temurin) | `java -version` |
| Android platform / build-tools | android-36 / 36.0.0 | `flutter.compileSdkVersion` |
| NDK | 28.2.13676358 | `flutter.ndkVersion` (Flutter 3.47.5), `android/build.gradle.kts` |
| CMake (Android) | 3.22.1 | `android/app/build.gradle.kts` |
| Gradle | 9.3.1 | `android/gradle/wrapper/gradle-wrapper.properties` |
| nFPM | 2.48.0 | `NFPM_VERSION` in the workflow |

## Jobs

`test`, `android`, `linux`, `macos` and `windows-native` run in parallel;
`windows` waits for `windows-native`.

### `test`

1. `flutter pub get`, `flutter analyze`.
2. `native/tests/run_host_tests.sh build/native-host-tests`: builds host
   `libsdrcore.so` and all vendored native libraries from source, runs the
   CMake-wired CTest suite, the standalone native regressions and the Blog V4
   C-oracle trace comparison. Tests that need a real RTL-SDR print a skip line
   when no device is attached.
3. `flutter test` with `SDRCORE_HOST_LIBRARY` pointing at that library, so the
   FFI tests run against real native code. Hardware tests stay skipped because
   `SDR_HW_TEST` is not set; tests gated on `SDRCORE_V3_PROBE_LIBRARY` stay
   skipped as well.

### `android`

`flutter build apk --release --target-platform android-arm64` and
`flutter build apk --debug`. libsdrcore for Android is built from source by
AGP/CMake (`native/CMakeLists.txt`); no prebuilt SDR libraries are downloaded.

### `linux` and `linux-install`

`flutter build linux --release`, an `ldd` check of the bundle, then
`packaging/linux/build-packages.sh` builds `.deb`, `.rpm`, Arch
`.pkg.tar.zst` and a portable `.tar.gz` with nFPM. See
[linux-packages.md](linux-packages.md).

`linux-install` then installs the packages with the native package manager on
clean `debian:13`, `ubuntu:24.04`, `fedora:latest`, `opensuse/tumbleweed` and
`archlinux:latest` containers and checks that every bundled library resolves.

### `macos` (macos-latest)

Builds a universal `libsdrcore.dylib` (arm64 + x86_64, macOS 12+) with CMake,
runs `flutter build macos --release`, copies the dylib into
`AirSDR.app/Contents/Frameworks`, signs ad hoc and packages
`AirSDR-<version>-macos.dmg`. The app is not signed with a Developer ID and
not notarized, so Gatekeeper asks for confirmation on first launch. The
sandbox has the `com.apple.security.device.usb` entitlement.

### `windows-native` and `windows`

MSVC cannot build the native core (liquid-dsp needs C99 `_Complex`), so
`windows-native` cross-builds `sdrcore.dll` on Ubuntu with llvm-mingw
(`LLVM_MINGW_VERSION`, `native/cmake/llvm-mingw-x86_64.cmake`). `windows`
(windows-latest) runs `flutter build windows --release` with `SDRCORE_DLL`
set; `windows/CMakeLists.txt` installs the DLL beside `sdr_flutter.exe`. The
result is `AirSDR-<version>-windows-x86_64.zip`, unsigned. RTL-SDR and
HackRF need the WinUSB driver (Zadig).

### `release` (tags `v*` only)

After all jobs pass, checks the tag against `version:` in `pubspec.yaml` and
creates a GitHub release with the APKs and Linux packages attached. Tags are
made by `tool/release.sh`, see [releasing.md](releasing.md).

## Versions

Every build job runs `tool/version.sh` (full history, `fetch-depth: 0`):
releases are `X.Y.Z`, other commits `X.Y.Z+git<N>.g<sha>`, and the Android
versionCode is the commit count. See [releasing.md](releasing.md).

Caches: Flutter SDK and pub cache (`subosito/flutter-action`), Gradle
caches/wrapper, and the NDK + CMake SDK packages.

## Artifacts

Each run uploads, where `<version>` is `FULL_VERSION` from `tool/version.sh`:

- `AirSDR-<version>-arm64-release.apk` and `AirSDR-<version>-debug.apk`
  (uploaded unzipped);
- `AirSDR-<version>-linux-x86_64` (a zip with the `.deb`, `.rpm`,
  `.pkg.tar.zst` and `.tar.gz`);
- `AirSDR-<version>-macos.dmg` and `AirSDR-<version>-windows-x86_64.zip`
  (uploaded as is).

Retention is 30 days. Download them from the run page in the Actions tab
(requires a GitHub login).

## Signing: CI APKs do not upgrade local builds

The release build type still uses the debug signing config
(`android/app/build.gradle.kts`). On CI that is the runner's freshly generated
`~/.android/debug.keystore`, which differs from the debug key of a local build host and
can differ between runs. Consequences:

- `adb install -r` of a CI APK over an app installed from a local build fails
  with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (signature mismatch), and vice
  versa.
- Switching between CI and local builds requires uninstalling the app first,
  which deletes app data (saved channels, presets, settings).

A stable release key would need a keystore stored as GitHub Actions secrets
(base64 keystore, store/key passwords, alias) and a `signingConfigs.release`
block reading them; that is not set up. No keystore is committed.

## Repository hygiene for a clean clone

- The Gradle wrapper (`android/gradlew`, `android/gradlew.bat`,
  `android/gradle/wrapper/gradle-wrapper.jar`) is committed. The files are the
  ones shipped by Flutter 3.47.5 (`bin/cache/artifacts/gradle_wrapper`,
  byte-identical); the Gradle version itself comes from
  `gradle-wrapper.properties` (9.3.1).
- `android/local.properties` is not committed: `flutter build` generates it
  with `flutter.sdk` and the Android SDK path.
- `android/key.properties` and keystores are gitignored and not used.
- All native sources (`native/third_party/*`, patches,
  `liquid-config.h.in`) are tracked in git; the liquid-dsp config header is
  generated by CMake at configure time.

## Checking results without the gh CLI

```
curl -s 'https://api.github.com/repos/ivanik7/AirSDR/actions/runs?branch=master&per_page=5'
```

This works unauthenticated only while the repository is public. For a private
repository, use the Actions tab or pass a token
(`-H "Authorization: Bearer <token>"`).

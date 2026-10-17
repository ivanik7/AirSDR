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

`flutter build apk --release --split-per-abi` for armeabi-v7a, arm64-v8a and
x86_64 (Flutter has no 32-bit x86 release engine), with
`force-version-code-ignoring-abi` so every APK's versionCode is the commit
count. Each APK is checked for its `libsdrcore.so` and its signing
certificate is printed. No debug APK is built in CI. libsdrcore for Android is built from source by
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

### `release` (tags `v*` only) and `nightly` (pushes to master)

Tagged releases need `test`, `android` and `linux-install` to pass;
`macos` and `windows` are optional while experimental.
Nightly needs `test` and at least one successful platform build. A failed
Android, Linux, macOS, Windows or Linux install-check job does not block
publishing the available packages. Cancelled runs and runs with no successful
platform builds leave the previous nightly in place.

- `release` checks the tag against `version:` in `pubspec.yaml` and creates
  the GitHub release `AirSDR vX.Y.Z` (marked latest) with notes generated
  from the commits. Tags are made by `tool/release.sh`, see
  [releasing.md](releasing.md).
- `nightly` deletes the pre-release `nightly` and its tag and recreates both
  at the pushed commit, so it always holds the newest master build. It is
  never marked latest. Because the tag moves, `git fetch --tags` may report
  a rejected `nightly` tag locally; `git fetch --tags --force` updates it.

Release shell steps stage packages in a fresh directory under `RUNNER_TEMP`,
so repository assets (such as `assets/fonts`) cannot become release uploads.
`python3 test/ci/release_workflow_test.py` exercises partial-build conditions
and both real shell steps with fake artifacts and a recording `gh` command.

Both publish the files under version-free names from
`tool/stable-asset-names.sh`, which the README links to:

| File | Content |
|---|---|
| `AirSDR-android-arm64-v8a.apk`, `AirSDR-android-armeabi-v7a.apk`, `AirSDR-android-x86_64.apk` | Android APKs |
| `AirSDR-linux-amd64.deb`, `AirSDR-linux-x86_64.rpm`, `AirSDR-linux-x86_64.pkg.tar.zst`, `AirSDR-linux-x86_64.tar.gz` | Linux packages |
| `AirSDR-macos.dmg` | macOS app |
| `AirSDR-windows-x86_64.zip` | Windows app |

Stable URLs: `https://github.com/ivanik7/AirSDR/releases/latest/download/<file>`
and `https://github.com/ivanik7/AirSDR/releases/download/nightly/<file>`.
The version is in the release title and inside the packages; CI run
artifacts keep the versioned file names.

## Versions

Every build job runs `tool/version.sh` (full history, `fetch-depth: 0`):
releases are `X.Y.Z`, other commits `X.Y.Z+git<N>.g<sha>`, and the Android
versionCode is the commit count. See [releasing.md](releasing.md).

Caches: Flutter SDK and pub cache (`subosito/flutter-action`), Gradle
caches/wrapper, and the NDK + CMake SDK packages.

## Artifacts

Each run uploads, where `<version>` is `FULL_VERSION` from `tool/version.sh`:

- `AirSDR-<version>-android-arm64-v8a.apk`, `...-android-armeabi-v7a.apk`
  and `...-android-x86_64.apk` (uploaded unzipped; most phones need
  arm64-v8a);
- four separate Linux artifacts: `AirSDR-<version>-linux-x86_64-deb`
  (Debian / Ubuntu), `...-rpm` (Fedora / openSUSE), `...-arch` (Arch)
  and `...-tar` (portable archive). Each artifact is a zip containing one
  package (`.deb`, `.rpm`, `.pkg.tar.zst` or `.tar.gz`, respectively);
- `AirSDR-<version>-macos.dmg` and `AirSDR-<version>-windows-x86_64.zip`
  (uploaded as is).

Retention is 30 days. Download them from the run page in the Actions tab
(requires a GitHub login).

## Signing

Release APKs are signed with the AirSDR release key (PKCS12, alias
`airsdr`, certificate `CN=ivanik, O=AirSDR`, SHA-256
`86:C7:2D:F6:87:6D:B6:96:9E:4B:DE:D5:46:6A:78:A5:3C:30:4D:0E:9E:6F:1B:88:B3:81:9C:FB:32:8F:77:EF`).
The keystore is never committed. `android/app/build.gradle.kts` reads it from:

- CI: repository secrets `ANDROID_KEYSTORE_BASE64` (the base64 keystore,
  decoded to `$RUNNER_TEMP`), `ANDROID_KEYSTORE_PASSWORD`,
  `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, passed as the
  `ANDROID_KEYSTORE_FILE` / `..._PASSWORD` / `ANDROID_KEY_ALIAS` environment
  variables;
- local builds: `android/key.properties` (gitignored) with `storeFile`,
  `storePassword`, `keyAlias`, `keyPassword`.

Without either (pull requests from forks, machines without the key) the
release build falls back to the debug key, and CI prints a warning. The
`android` job prints the certificate of the release APK with `apksigner`.

An APK signed with one key cannot be installed over an app signed with
another: `adb install -r` fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.
Switching keys means uninstalling first, which deletes app data (saved
channels, presets, settings). Debug APKs always use the debug key of the
machine that built them.

Losing the release keystore or its password means no future release can be
installed over existing installs. Keep a backup outside the repository.

## Repository hygiene for a clean clone

- The Gradle wrapper (`android/gradlew`, `android/gradlew.bat`,
  `android/gradle/wrapper/gradle-wrapper.jar`) is committed. The files are the
  ones shipped by Flutter 3.47.5 (`bin/cache/artifacts/gradle_wrapper`,
  byte-identical); the Gradle version itself comes from
  `gradle-wrapper.properties` (9.3.1).
- `android/local.properties` is not committed: `flutter build` generates it
  with `flutter.sdk` and the Android SDK path.
- `android/key.properties` and keystores (`*.jks`, `*.keystore`, `*.p12`)
  are gitignored.
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

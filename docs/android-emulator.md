# Android emulator for UI smoke

The Android emulator is the only Android target used for agent verification; real phones are
never used. It checks app startup on Android, the interface, and Android integration
(permissions, notification, lifecycle). `libsdrcore` is built for armeabi-v7a, arm64-v8a
and x86_64 (`android/app/build.gradle.kts`), so the emulator loads the real native core;
with no USB SDR attached it shows the no-device state. The emulator does not cover USB OTG,
real RF, tuner gain/PPM, audio quality, release performance on phones, or vendor-specific
background behaviour; report those as unverified.

| Checked on the emulator | Not covered (unverified) |
|---|---|
| debug APK install/launch, cold start | native receiver, DSP, audio (no x86_64 `libsdrcore`) |
| Receive / Decoder / Presets / Settings tabs, 360×780 dp layout | real RF, sensitivity, tuner gain, PPM |
| visible native-unavailable error state | USB OTG, USB permission, RTL-SDR/HackRF drivers |
| presets, bands, settings screens and their persistence | audibility and sound quality, performance on phones |
| notification permission prompt | foreground service, screen-off/background on real devices |

Receiver and DSP behaviour with a real SDR are verified on the Linux host with the attached
RTL-SDR Blog V4 (see `README.md`).

## Setup

- Emulator 37.x, image `system-images;android-35;default;x86_64` (Android 15, no Play),
  AVD `sdr_api35`: Pixel 4a, 720×1560 @320 dpi (360×780 dp), 2 GiB RAM, 4 cores, 6 GiB data.
  The SDK/AVD live outside git; the repository holds only `tool/emulator.sh` and this guide.
- KVM is required (`/dev/kvm`, user in the `kvm` group). A login session started before the
  group was added does not have it yet; `tool/emulator.sh start` then launches the emulator
  via `sg kvm -c`. Check: `sg kvm -c "$ANDROID_HOME/emulator/emulator -accel-check"`.
  Software emulation without KVM is not used.
- Cold boot takes 18–30 s to `sys.boot_completed=1`; the emulator uses about 2–3 GiB RAM.
  Do not leave it running between sessions or run it alongside a Gradle build when memory is
  tight.

Installation from scratch:

```sh
sdkmanager 'emulator' 'system-images;android-35;default;x86_64'
avdmanager create avd --name sdr_api35 --package 'system-images;android-35;default;x86_64' --device pixel_4a
# in ~/.android/avd/sdr_api35.avd/config.ini: hw.lcd.width=720 hw.lcd.height=1560 hw.lcd.density=320 hw.ramSize=2G
```

## Developer loop

From the repository root (or a worktree). `tool/emulator.sh` needs `ANDROID_HOME`; set
`SDR_ENV=<path>` to have it source a local toolchain setup script first.

```sh
tool/emulator.sh start        # headless: -no-window -no-audio -no-snapshot -gpu swiftshader_indirect -accel on
tool/emulator.sh wait         # waits for sys.boot_completed=1
adb devices -l                # emulator-5554 ... model:Android_SDK_built_for_x86_64
flutter build apk --debug
tool/emulator.sh install      # adb install -r (app data is kept) + launch and check
tool/emulator.sh shot recv    # recv.png (+ recv.xml, UI dump via uiautomator)
tool/emulator.sh logs         # emulator-logcat.txt: flutter, AndroidRuntime, libc/DEBUG
tool/emulator.sh stop         # adb emu kill
```

Instead of `build` + `install` you can use `flutter run -d emulator-5554` (hot reload). The debug
APK contains every ABI; CI's x86_64 release APK also runs on the emulator, but it is signed
with the release key, so uninstall a debug build first.
Always pass the serial explicitly (`-s emulator-5554`, `-d emulator-5554`) so no other adb
device is touched. A different `EMU_PORT` changes the serial.

The emulator runs in the background (`nohup`). If the launching process is killed together
with its process group (agent terminals with a timeout do this), the emulator dies too; start
it from a separate persistent shell in that case.

Take element bounds from `tool/emulator.sh shot` (xml) or
`adb -s emulator-5554 exec-out uiautomator dump /dev/tty`; elements are reachable by
content-desc. The emulator runs with `-no-audio`, so it never checks sound.

## Known emulator issues

- **Cold-start crash (emulator only).** The app occasionally crashes at startup with SIGSEGV
  in the `1.raster` thread: `impeller/renderer/backend/gles/blit_command_gles.cc:209`, path
  `GPUSurfaceGLImpeller` → `AiksContext` → `ContentContext` → `BlitPass::EncodeCommands`.
  Impeller (OpenGLES) initialization fails on the emulator's software GLES before any app
  frame is drawn; it is unrelated to app code. `--ez enable-impeller false` does not help.
  `tool/emulator.sh launch` detects `Fatal signal` in logcat and retries once. Tombstones:
  `adb -s emulator-5554 root; adb -s emulator-5554 shell ls /data/tombstones`.
- `-gpu swangle` and `-gpu lavapipe`: qemu exits silently on the app's first frame.
  `-gpu swiftshader` behaves the same as `swiftshader_indirect` (the default).
- `uiautomator dump` does not work on constantly animated screens (`could not get idle state`).

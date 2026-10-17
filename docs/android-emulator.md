# Android emulator for UI/synthetic smoke (debian-ai)

The emulator does NOT replace the SM-F936B with the RTL-SDR Blog V4. It checks only app startup
on Android, the interface, retuning/modes, DSP on synthetic IQ, and spectrum/waterfall rendering.
This procedure does not need the phone, and it must not be touched.

| Checked on the emulator | Only on the physical phone with a USB SDR |
|---|---|
| debug APK install/launch, cold start | USB OTG, usbfs, USB permission, RTL-SDR/HackRF drivers |
| Receive / Presets / Settings tabs, 360×780 dp layout | real RF, sensitivity, tuner gain/AGC, PPM |
| selecting `Synthetic signal generator`, Start/Stop | audibility and sound quality (checked manually) |
| frequency (keyboard, step ◀ ▶), centering, WFM/NFM/AM/… modes | performance and heating on arm64, release build |
| live spectrum and waterfall on a synthetic signal, no crashes | background/screen off, Samsung specifics (One UI, Android 16) |

Before accepting hardware-dependent changes (drivers, USB, source, audio, background reception)
the phone check remains mandatory; passing on the emulator does not replace it.

## Host state (verified 2026-09-29)

- Emulator 37.1.11, image `system-images;android-35;default;x86_64` (Android 15, no Play),
  AVD `sdr_api35` in `~/.android/avd/`: Pixel 4a, 720×1560 @320 dpi (360×780 dp), 2 GiB RAM,
  4 cores, data 6 GiB. The SDK/AVD are outside git; the repository holds only the script and this guide.
- KVM: `/dev/kvm` `root:kvm 0660`, `$USER` was added to the `kvm` group (`getent group kvm`).
  A login session started before that (for example, in the Hermes gateway process) does not have the group yet;
  in that case `tool/emulator.sh start` launches the emulator itself via `sg kvm -c`.
  Check: `sg kvm -c '~/sdk/android/emulator/emulator -accel-check'` → `KVM ... is installed and usable`.
  We do not use software emulation without KVM.
- Cold boot takes 18–30 s to `sys.boot_completed=1`; the emulator uses about 2–3 GiB RAM.
  Do not leave it running between sessions (the VM has 11 GiB) and do not run it alongside a Gradle build
  if memory is tight.

Installation from scratch (already done on debian-ai):

```sh
source ~/prj/env.sh
sdkmanager 'emulator' 'system-images;android-35;default;x86_64'
avdmanager create avd --name sdr_api35 --package 'system-images;android-35;default;x86_64' --device pixel_4a
# in ~/.android/avd/sdr_api35.avd/config.ini: hw.lcd.width=720 hw.lcd.height=1560 hw.lcd.density=320 hw.ramSize=2G
```

## Developer loop

From the repository root (or a worktree); `tool/emulator.sh` runs `source ~/prj/env.sh` itself:

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

Instead of `build` + `install` you can use `flutter run -d emulator-5554` (hot reload; verified: first
build + install ≈ 1 min). The debug APK contains x86_64. Release is built only for arm64-v8a;
do not install it on the emulator.
Always specify the serial explicitly (`-s emulator-5554`, `-d emulator-5554`): the phone is also visible in
`adb devices`/`flutter devices` over Wi-Fi ADB. With a different `EMU_PORT` the serial changes.

The emulator is started in the background (`nohup`). If the launching process is killed together with its group
(this happens with agent terminals that have a timeout), the emulator dies too. In that case run
`tool/emulator.sh start` from a separate persistent shell/background session.

## Synthetic smoke (run 2026-09-29, branch commit based on 406ba64)

Coordinates are for 720×1560; take current bounds from `tool/emulator.sh shot` (xml) or
`adb -s emulator-5554 exec-out uiautomator dump /dev/tty`. Elements are reachable by content-desc.

1. First launch: system notification dialog → "Allow". Receive: "No device", status
   "waiting for USB SDR". Synthetic is not selected automatically, and that is correct.
2. Device dropdown (tap 320 200) → `Synthetic signal generator` → status "reception stopped".
3. "Start" (tap 80 200) → the button becomes "Stop", status `2.40 MS/s · audio drops 0`.
   The spectrum is live: carriers near 99.4 / 99.7 / 100.5 / 100.7 MHz, a wideband hump near
   100.1–100.3 MHz. The waterfall fills: two snapshots 3 s apart differ.
4. Step ▶ ×2 (tap 644 858) → 100.025 MHz. NFM mode (tap 250 485) → `NFM · BW 12.5k`.
   Scroll down, on the keyboard `1 0 0 . 7 OK` → 100.700 MHz. After scrolling back up the 100.7
   carrier sits under the center marker, axis 100–101.5M: centering works.
5. The "Presets" tab (9 saved · one receive channel; filters All/FM/AIR/VHF/MAR/UHF)
   and "Settings" (device Synthetic, sample rate 2.40 MHz, AGC, RF gain, volume)
   open. `uiautomator dump` on "Settings" answers `could not get idle state`, so
   only a screenshot is taken there.
6. "Receive" → "Stop": the button is "Start" again, status "reception stopped". Two snapshots 3 s apart are identical:
   the waterfall is stopped.
7. Repeated `stop/start/wait/install` cycle via the script: frequency/mode were kept
   (`install -r`), Synthetic → Start → AM (`AM · BW 10.0k`), spectrum/waterfall live, Stop.
   There are no exceptions in `emulator-logcat.txt`.

Screenshots: `~/prj/docs/screens/emulator-synthetic-{wfm-100M,nfm-100.7M,am-100.7M}.png`.
The emulator does not check sound: it runs with `-no-audio`, and sound is off in the app.

## Known emulator issues

- **Cold-start crash (emulator only).** It occasionally crashes at startup with SIGSEGV in the
  `1.raster` thread. Symbolized stack (`symbols.zip` of engine `af7e796e…` for android-x64,
  `llvm-symbolizer` from the NDK): `impeller/renderer/backend/gles/blit_command_gles.cc:209`, path
  `GPUSurfaceGLImpeller` → `AiksContext` → `ContentContext` → `BlitPass::EncodeCommands`. Impeller
  (OpenGLES) initialization fails on the emulator's software GLES, before any app frames
  are drawn; it is unrelated to the app code. The rate varies: in a series right after boot
  it was 7/8, later 1/6 and 0/26. A minimal `flutter create` app gives 0/10, so it was not possible
  to separate "app/engine" with confidence. `--ez enable-impeller false` on the intent does not help
  (Impeller stays enabled). `tool/emulator.sh launch` catches `Fatal signal` in logcat and makes
  one retry launch. Tombstones: `adb -s emulator-5554 root; adb -s emulator-5554 shell ls /data/tombstones`.
  This was not investigated separately on the phone (arm64, its own GPU driver); earlier QA sessions
  did not record such a crash. If it shows up there, it is a separate task.
- `-gpu swangle` and `-gpu lavapipe` on this VM: qemu exits silently on the app's first frame.
  `-gpu swiftshader` behaves the same as `swiftshader_indirect` (the default).
- `uiautomator dump` does not work on constantly animated screens (`could not get idle state`).

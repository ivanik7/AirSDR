#!/bin/sh
# Headless Android emulator loop for UI smoke (see docs/android-emulator.md).
# No USB OTG, no real RF, no audio quality.
#
#   tool/emulator.sh start     # boot AVD headless (KVM) in the background, returns immediately
#   tool/emulator.sh wait      # block until sys.boot_completed=1 (<= 5 min)
#   tool/emulator.sh install   # adb install -r debug APK (keeps app data), then `launch`
#   tool/emulator.sh launch    # cold-start the app; detect the known startup SIGSEGV, retry once
#   tool/emulator.sh shot NAME # screenshot NAME.png (+ NAME.xml UI dump if the UI is idle)
#   tool/emulator.sh logs      # flutter/AndroidRuntime/crash logcat -> emulator-logcat.txt
#   tool/emulator.sh stop      # adb emu kill
#   tool/emulator.sh status    # adb devices -l + boot flag
#
# Env: AVD (sdr_api35), EMU_PORT (5554), EMU_GPU (swiftshader_indirect), ANDROID_HOME. The serial
# is always emulator-$EMU_PORT so other adb devices are never touched.
set -eu

# Optional local toolchain setup; otherwise ANDROID_HOME must already be set.
if [ -n "${SDR_ENV:-}" ]; then . "$SDR_ENV"; fi
: "${ANDROID_HOME:?set ANDROID_HOME or SDR_ENV}"
AVD=${AVD:-sdr_api35}
EMU_PORT=${EMU_PORT:-5554}
# swangle and lavapipe made qemu exit as soon as the app rendered its first frame on a KVM VM.
EMU_GPU=${EMU_GPU:-swiftshader_indirect}
SERIAL="emulator-$EMU_PORT"
EMULATOR="$ANDROID_HOME/emulator/emulator"
ADB="$ANDROID_HOME/platform-tools/adb"
PKG=net.ivanik.sdr_flutter
APK=build/app/outputs/flutter-apk/app-debug.apk
LOG="${TMPDIR:-/tmp}/sdr-emulator-$EMU_PORT.log"

adb_s() { "$ADB" -s "$SERIAL" "$@"; }

launch_once() {
  adb_s shell am force-stop "$PKG"
  adb_s logcat -c
  adb_s shell am start -W -n "$PKG/.MainActivity" >/dev/null
  sleep 6
  if adb_s logcat -d | grep -q 'Fatal signal.*sdr_flutter'; then
    adb_s logcat -d | grep 'Fatal signal' >&2
    return 1
  fi
  pid=$(adb_s shell pidof "$PKG" | tr -d '\r')
  [ -n "$pid" ] || { echo "app is not running" >&2; return 1; }
  echo "$PKG running, pid $pid"
}

case "${1:-}" in
start)
  if "$ADB" devices | grep -q "^$SERIAL"; then echo "$SERIAL already running"; exit 0; fi
  # -no-snapshot: cold boot, no heavy quickboot snapshots left on disk.
  args="-avd $AVD -port $EMU_PORT -no-window -no-audio -no-snapshot -no-boot-anim -gpu $EMU_GPU -accel on"
  if id -nG | tr ' ' '\n' | grep -qx kvm; then
    nohup "$EMULATOR" $args >"$LOG" 2>&1 &
  else
    # The user is in group kvm, but a login session started before that lacks the group.
    nohup sg kvm -c "exec '$EMULATOR' $args" >"$LOG" 2>&1 &
  fi
  echo "emulator starting ($SERIAL), log: $LOG"
  ;;
wait)
  timeout 300 "$ADB" -s "$SERIAL" wait-for-device
  i=0
  while [ "$(adb_s shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != 1 ]; do
    i=$((i + 1)); [ $i -gt 60 ] && { echo "boot timeout, see $LOG"; exit 1; }
    sleep 5
  done
  echo "$SERIAL: sys.boot_completed=1"
  ;;
install)
  [ -f "$APK" ] || { echo "no $APK — run: flutter build apk --debug"; exit 1; }
  adb_s install -r "$APK"
  "$0" launch
  ;;
launch)
  # Known emulator-only issue: intermittent SIGSEGV on the raster thread while Impeller (GLES)
  # initialises (blit_command_gles.cc, before any app painting). One retry, then fail loudly.
  launch_once || { echo "startup crash, retrying once" >&2; launch_once; }
  ;;
shot)
  name=${2:-emulator-screen}
  adb_s exec-out screencap -p >"$name.png"
  # uiautomator fails with "could not get idle state" on continuously animating screens.
  adb_s exec-out uiautomator dump /dev/tty >"$name.xml" || true
  echo "$name.png"
  ;;
logs)
  adb_s logcat -d -v time -s flutter AndroidRuntime libc DEBUG >emulator-logcat.txt
  echo "emulator-logcat.txt ($(wc -l <emulator-logcat.txt) lines)"
  ;;
stop)
  adb_s emu kill
  ;;
status)
  "$ADB" devices -l
  adb_s shell getprop sys.boot_completed 2>/dev/null || echo "$SERIAL not running"
  ;;
*)
  sed -n '2,15p' "$0"; exit 2
  ;;
esac

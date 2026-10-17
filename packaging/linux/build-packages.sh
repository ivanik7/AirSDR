#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Packages a `flutter build linux --release` bundle as .deb, .rpm, Arch
# .pkg.tar.zst and a portable .tar.gz with nFPM (https://nfpm.goreleaser.com).
# See docs/linux-packages.md.
#
# Usage: packaging/linux/build-packages.sh <bundle_dir> <out_dir>
#
# Versions come from tool/version.sh (docs/releasing.md): X.Y.Z for a tagged
# release, X.Y.Z+git<N>.g<sha> (Arch: X.Y.Z.r<N>.g<sha>) otherwise.
# NFPM overrides the nfpm binary (default: nfpm from PATH).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

bundle="${1:?usage: $0 <bundle_dir> <out_dir>}"
out="${2:?usage: $0 <bundle_dir> <out_dir>}"
bundle="$(cd "$bundle" && pwd)"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
nfpm="${NFPM:-nfpm}"

binary=sdr_flutter
app_id=net.ivanik.sdr_flutter
test -x "$bundle/$binary" || { echo "no $binary in $bundle" >&2; exit 1; }
test -f "$bundle/lib/libsdrcore.so" || { echo "no lib/libsdrcore.so in $bundle" >&2; exit 1; }

eval "$("$root/tool/version.sh")"

case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- udev rules: one uaccess rule per USB id in the Android device filter, so
# the RTL-SDR/HackRF/Airspy list has a single source of truth.
rules="$work/60-airsdr.rules"
{
  echo "# Installed by the AirSDR package. Generated from"
  echo "# android/app/src/main/res/xml/device_filter.xml by packaging/linux/build-packages.sh."
  echo "# Gives the logged-in desktop user access to supported SDR dongles."
  sed -n 's/.*vendor-id="\([0-9]*\)" *product-id="\([0-9]*\)".*/\1 \2/p' \
      "$root/android/app/src/main/res/xml/device_filter.xml" |
    while read -r vid pid; do
      printf 'SUBSYSTEM=="usb", ATTRS{idVendor}=="%04x", ATTRS{idProduct}=="%04x", TAG+="uaccess"\n' \
        "$vid" "$pid"
    done
} > "$rules"
grep -q 'idVendor}=="0bda", ATTRS{idProduct}=="2838"' "$rules" ||
  { echo "udev rules lack the RTL2832U 0bda:2838 entry" >&2; exit 1; }

# --- Runtime dependencies: shared libraries the bundle needs from the system.
elfs=()
while IFS= read -r -d '' f; do
  if head -c 4 "$f" | grep -q 'ELF'; then elfs+=("$f"); fi
done < <(find "$bundle" -type f \( -name '*.so*' -o -name "$binary" \) -print0)
bundled="$(cd "$bundle/lib" && ls)"
system_sonames="$(for f in "${elfs[@]}"; do objdump -p "$f" | awk '/NEEDED/ {print $2}'; done |
  sort -u | grep -vxF "$bundled" || true)"
echo "System libraries needed by the bundle:"
echo "$system_sonames" | sed 's/^/  /'

# deb: explicit package names, so one .deb installs on Debian 13 and Ubuntu
# 24.04+ alike. Libraries renamed for the time64 ABI (t64) accept both names.
# GTK pulls in the cairo/pango/glib stack listed by the soname scan above.
# The Flutter engine dlopen()s libEGL.so.1 through libepoxy, so it is not in
# any NEEDED entry; without it the window stays black.
deb_depends="$(printf '%s\n' 'libc6' 'libstdc++6' 'libgtk-3-0t64 | libgtk-3-0' \
  'libasound2t64 | libasound2' 'libepoxy0' 'libegl1')"

# rpm (Fedora, openSUSE, RHEL clones): soname dependencies resolve on every
# rpm distribution regardless of package names.
rpm_depends="$(printf '%s\n' "$system_sonames" libEGL.so.1 | sed '/^$/d; s/$/()(64bit)/')"

yaml_list() { sed '/^$/d; s/^/      - "/; s/$/"/'; }

pkg_version="$FULL_VERSION"
cat > "$work/nfpm.yaml" <<EOF
name: airsdr
arch: $arch
platform: linux
version: "$pkg_version"
version_schema: none
section: hamradio
priority: optional
maintainer: "ivanik <ivan170102@gmail.com>"
vendor: AirSDR
homepage: https://github.com/ivanik7/AirSDR
license: GPL-3.0-or-later
description: |-
  Software-defined radio receiver for RTL-SDR and HackRF.
  AirSDR is a Flutter desktop app with a native C/C++ USB driver, DSP and
  audio core. It receives AM, FM and wideband FM with RDS and runs
  ADS-B, rtl_433, SSTV and DMR decoders.
contents:
  - src: "$bundle"
    dst: /opt/airsdr
    type: tree
  - src: "$here/airsdr.sh"
    dst: /usr/bin/airsdr
    file_info:
      mode: 0755
  - src: "$here/$app_id.desktop"
    dst: /usr/share/applications/$app_id.desktop
  - src: "$root/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"
    dst: /usr/share/icons/hicolor/192x192/apps/$app_id.png
  - src: "$rules"
    dst: /usr/lib/udev/rules.d/60-airsdr.rules
  - src: "$here/airsdr-blacklist-dvb.conf"
    dst: /usr/lib/modprobe.d/airsdr-blacklist-dvb.conf
  - src: "$root/LICENSE"
    dst: /usr/share/licenses/airsdr/LICENSE
  - src: "$root/native/third_party/NOTICE.md"
    dst: /usr/share/doc/airsdr/THIRD-PARTY-NOTICE.md
scripts:
  postinstall: "$here/postinstall.sh"
overrides:
  deb:
    depends:
$(echo "$deb_depends" | yaml_list)
  rpm:
    depends:
$(echo "$rpm_depends" | yaml_list)
  archlinux:
    depends:
      - "gtk3"
      - "alsa-lib"
      - "libglvnd"
rpm:
  group: Applications/Communications
archlinux:
  packager: "ivanik <ivan170102@gmail.com>"
EOF

echo "--- nfpm.yaml"
cat "$work/nfpm.yaml"
echo "---"

# Arch pkgver cannot contain '+', so it gets its own version string.
sed "s|^version: .*|version: \"$ARCH_VERSION\"|" "$work/nfpm.yaml" > "$work/nfpm-arch.yaml"
"$nfpm" package --config "$work/nfpm.yaml" --packager deb --target "$out/"
"$nfpm" package --config "$work/nfpm.yaml" --packager rpm --target "$out/"
"$nfpm" package --config "$work/nfpm-arch.yaml" --packager archlinux --target "$out/"

tar_name="airsdr-$FULL_VERSION-linux-$(uname -m).tar.gz"
tar -C "$(dirname "$bundle")" --transform "s|^$(basename "$bundle")|airsdr|" \
  -czf "$out/$tar_name" "$(basename "$bundle")"

echo "Packages in $out:"
ls -l "$out"

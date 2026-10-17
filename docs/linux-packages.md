# Linux packages

CI (`linux` job in `.github/workflows/ci.yml`) turns the
`flutter build linux --release` bundle into packages with
[nFPM](https://nfpm.goreleaser.com). One nFPM config produces all formats, so
there is no per-distribution packaging code:

| File | Distributions |
|---|---|
| `airsdr_<ver>_amd64.deb` | Debian 13+, Ubuntu 24.04+ and derivatives |
| `airsdr-<ver>.x86_64.rpm` | Fedora, openSUSE Tumbleweed, other rpm distributions |
| `airsdr-<ver>-x86_64.pkg.tar.zst` | Arch Linux and derivatives |
| `airsdr-<ver>-linux-x86_64.tar.gz` | anything else: unpack and run `airsdr/sdr_flutter` |

The bundle is built on Ubuntu 24.04, so the host needs glibc 2.39 or newer.
The `linux-install` job installs each package on clean Debian 13,
Ubuntu 24.04, Fedora, openSUSE Tumbleweed and Arch containers.

## Layout

| Path | Content |
|---|---|
| `/opt/airsdr/` | the Flutter bundle, with `lib/libsdrcore.so` built from source |
| `/usr/bin/airsdr` | launcher for `/opt/airsdr/sdr_flutter`; sets `SDR_AUDIO_SINK=alsa` unless it is already set (the app's Linux default is the null sink) |
| `/usr/share/applications/net.ivanik.sdr_flutter.desktop` | menu entry |
| `/usr/share/icons/hicolor/192x192/apps/net.ivanik.sdr_flutter.png` | icon |
| `/usr/lib/udev/rules.d/60-airsdr.rules` | `uaccess` rules for every USB id in `android/app/src/main/res/xml/device_filter.xml` |
| `/usr/lib/modprobe.d/airsdr-blacklist-dvb.conf` | blacklists the DVB-T driver (`dvb_usb_rtl28xxu`) that claims RTL2832U dongles |

The udev rules let the logged-in desktop user open the dongles without root.
The post-install script reloads udev. The DVB blacklist takes effect after the
module is unloaded (`sudo modprobe -r dvb_usb_rtl28xxu`) or after a reboot.

## Dependencies

- deb: `libc6`, `libstdc++6`, `libgtk-3-0t64 | libgtk-3-0`,
  `libasound2t64 | libasound2`, `libepoxy0`, `libegl1`. Packages renamed for
  the time64 ABI also accept the old name.
- rpm: soname dependencies (`libgtk-3.so.0()(64bit)`, ...) of every bundled
  ELF file, which resolve on every rpm distribution regardless of package
  names.
- Arch: `gtk3`, `alsa-lib`, `libglvnd`.

The Flutter engine loads `libEGL.so.1` with `dlopen()`, so no NEEDED entry
names it. It is listed explicitly: without it the window stays black.

## Versions

`tool/version.sh` (see [releasing.md](releasing.md)): a tagged release builds
`1.2.3`; any other commit builds `1.2.3+git<N>.g<sha>`, and the Arch package
uses `1.2.3.r<N>.g<sha>` because pkgver allows no `+`.

## Building locally

On a Linux host with Flutter, the Linux desktop build dependencies and
`nfpm`:

    flutter build linux --release
    packaging/linux/build-packages.sh build/linux/x64/release/bundle dist

## Not covered yet

- No AppImage or Flatpak. A Flatpak would need its own manifest with the
  Flutter SDK as a build source and a USB device permission.
- No arm64 packages: CI builds x86_64 only. The script also works on arm64.
- Packages are not signed and there is no apt/dnf repository.

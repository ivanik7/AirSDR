#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Apply the new udev rules to SDR dongles that are already plugged in.
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules >/dev/null 2>&1 || true
  udevadm trigger --subsystem-match=usb --action=change >/dev/null 2>&1 || true
fi
exit 0

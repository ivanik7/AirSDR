#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Launcher installed as /usr/bin/airsdr by the AirSDR packages.
# The app's Linux default audio sink is "null"; packaged installs play
# through ALSA's default PCM instead. Set SDR_AUDIO_SINK to override.
export SDR_AUDIO_SINK="${SDR_AUDIO_SINK:-alsa}"
exec /opt/airsdr/sdr_flutter "$@"

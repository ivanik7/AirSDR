// SPDX-License-Identifier: GPL-3.0-or-later
//
// miniaudio build options shared by miniaudio_impl.c and miniaudio_sink.cpp
// (both must see the same MA_* configuration, since it changes struct
// layouts). Playback devices only.
#ifndef SDRCORE_MINIAUDIO_CONFIG_H
#define SDRCORE_MINIAUDIO_CONFIG_H

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#if defined(__APPLE__)
// Link CoreAudio/AudioToolbox/CoreFoundation at build time instead of
// dlopen()ing them, so a notarized macOS app needs no extra entitlements
// (miniaudio.h section 2.2).
#define MA_NO_RUNTIME_LINKING
#endif

#endif  // SDRCORE_MINIAUDIO_CONFIG_H

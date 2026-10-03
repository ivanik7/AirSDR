# SPDX-License-Identifier: GPL-3.0-or-later
# Placeholder until the audio sink backends land (see audio_sink.h).
add_library(sdrcore_audio INTERFACE)
target_include_directories(sdrcore_audio INTERFACE ${CMAKE_CURRENT_LIST_DIR})

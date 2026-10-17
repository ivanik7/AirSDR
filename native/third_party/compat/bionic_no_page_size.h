// SPDX-License-Identifier: GPL-3.0-or-later
//
// Force-included into csdr_sstv on Android (csdr_sstv.cmake). Bionic always
// defines PAGE_SIZE as a macro on 32-bit ARM and x86, which breaks the local
// `PAGE_SIZE` constant in csdr's ringbuffer.cpp. Pull the definition in once
// (its include guard keeps it from coming back) and drop it, so
// ringbuffer.cpp asks sysconf(_SC_PAGESIZE) as on other platforms.
#pragma once
#include <limits.h>
#include <sys/user.h>
#undef PAGE_SIZE
#undef PAGE_MASK

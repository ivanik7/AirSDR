// SPDX-License-Identifier: GPL-3.0-or-later
// macOS has no <malloc.h>; digiham's lc.cpp only needs malloc/free from it.
// Added to the include path of sdrcore_dmr_framing on Apple (dmr_framing.cmake).
#pragma once
#include <stdlib.h>

/* SPDX-License-Identifier: GPL-2.0-or-later */
/* In-process replacement for the dxlAPRS osic layer (upstream-os/osic.h),
   declaring only what lorarx.c, loraprotocols.c and aprsstr.c reference.
   The embedded build opens no file, pipe, tty or socket and prints nothing;
   see lorarx_os.c. Signatures match upstream byte for byte. */
#ifndef __OSIC_H__
#define __OSIC_H__
#include <stdint.h>
#include "X2C.h"

void osic_WrUINT32(uint32_t x, uint32_t witdh);
void osic_WrINT32(int32_t x, uint32_t witdh);
void osic_WrFixed(float x, int32_t place, uint32_t witdh);
void osic_Close(int32_t fd);
void osic_Seekend(int32_t fd, int32_t rel);
void X2C_BEGIN(int *argc, char *argv[],
	       int gc_auto, int32_t gc_threshold, int32_t heap_limit);
void X2C_PCOPY(void **ppcpy, size_t size);
int32_t X2C_TRUNCI(double x, int32_t min0, int32_t max0);
uint32_t X2C_TRUNCC(double x, uint32_t min0, uint32_t max0);
void osic_alloc(X2C_ADDRESS *p, uint32_t size);
uint32_t osic_time(void);
uint32_t X2C_LSH(uint32_t a, int32_t length, int32_t n);
char X2C_IN(uint32_t i, uint32_t bits, uint32_t set);
void X2C_DYNALLOCATE(char **a, size_t size, size_t lens[], size_t dims);
void X2C_DYNDEALLOCATE(char **a);
#endif /* __OSIC_H__ */

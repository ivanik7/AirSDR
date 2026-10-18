/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * In-process OS layer for the embedded lorarx build (SDRCORE_LORARX_EMBED).
 * Replaces upstream-os/{osi,osic,udp}.c, which stay vendored verbatim and are
 * used only by the reference (oracle) build. Pure helpers (X2C_TRUNC*,
 * X2C_LSH, X2C_IN, dynamic arrays, X2C_PCOPY) are copied unchanged from
 * upstream osic.c (Copyright (C) Hannes Schmelzer <oe5hpm@oevsv.at>,
 * Christian Rabler <oe5dxl@oevsv.at>, GPL-2.0+), so numerics are identical.
 * Everything that would touch a file, pipe, socket, stdout or stderr is inert:
 * IQ arrives through lorarx_embed_block() and JSON leaves through
 * lorarx_embed_emit(). Assertion traps unwind via lorarx_embed_abort()
 * instead of terminating the host application.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "osi.h"
#include "lorarx_embed.h"

static int osic_argc, argc_delivered;
static char **osic_argv;

/* Console output: the embedded decoder prints nothing. */
void osic_WrUINT32(uint32_t x, uint32_t witdh) { (void)x; (void)witdh; }
void osic_WrINT32(int32_t x, uint32_t witdh) { (void)x; (void)witdh; }
void osic_WrFixed(float x, int32_t place, uint32_t witdh) { (void)x; (void)place; (void)witdh; }
void osi_WrStr(char s[], uint32_t s_len) { (void)s; (void)s_len; }
void osi_WrStrLn(char s[], uint32_t s_len) { (void)s; (void)s_len; }
void osi_Werr(char text[], uint32_t text_len) { (void)text; (void)text_len; }

/* Files, pipes and sockets: none can be opened. Options that need one
   (-Y d|f, -U/-L/-J/-u/-t) therefore fail or stay inert exactly as if the
   path or socket were unavailable. */
int32_t osi_OpenWrite(char fn[], uint32_t fn_len) { (void)fn; (void)fn_len; return -1; }
int32_t osi_OpenRead(char fn[], uint32_t fn_len) { (void)fn; (void)fn_len; return -1; }
int32_t osi_OpenNONBLOCK(char fn[], uint32_t fn_len) { (void)fn; (void)fn_len; return -1; }
int32_t osi_RdBin(int32_t fd, char buf[], uint32_t buf_len, uint32_t size)
{
	(void)fd; (void)buf; (void)buf_len; (void)size;
	return -1;
}
void osi_WrBin(int32_t fd, char buf[], uint32_t buf_len, uint32_t size)
{
	(void)fd; (void)buf; (void)buf_len; (void)size;
}
char osi_IsFifo(int32_t fd) { (void)fd; return 0; }
void osic_Close(int32_t fd) { (void)fd; }
void osic_Seekend(int32_t fd, int32_t rel) { (void)fd; (void)rel; }
long openudp(void) { return -1; }
long udpsend(long fd, char buf[], long len, unsigned long port, unsigned long ip)
{
	(void)fd; (void)buf; (void)len; (void)port; (void)ip;
	return -1;
}

void osi_BEGIN(void) {}

/* Argument access: same semantics as upstream osic_NextArg. */
void osi_NextArg(char s[], uint32_t s_len)
{
	if (argc_delivered >= osic_argc-1) {
		s[0] = 0;
		return;
	}
	strncpy(s, osic_argv[argc_delivered+1], s_len);
	argc_delivered++;
}

/* Upstream returns early when called twice; the embed restarts per start(). */
void X2C_BEGIN(int *argc, char *argv[],
	       int gc_auto, int32_t gc_threshold, int32_t heap_limit)
{
	(void)gc_auto; (void)gc_threshold; (void)heap_limit;
	osic_argc = *argc;
	osic_argv = argv;
	argc_delivered = 0;
}

void X2C_PCOPY(void **ppcpy, size_t size)
{
	void *pnew;

	pnew = malloc(size);
	if (pnew == NULL)
		return;
	memcpy(pnew, *ppcpy, size);
	*ppcpy = pnew;
}

int32_t X2C_TRUNCI(double x, int32_t min0, int32_t max0)
{
	int32_t i;

	if (x < (double)min0 || x > (double)max0)
		lorarx_embed_abort(); /* upstream: assert(0) */
	i = (int32_t)x;
	if (x > 0.0) {
		if ((double)i > x)
			--i;
	} else if ((double)i < x) {
		++i;
	}
	return i;
}

uint32_t X2C_TRUNCC(double x, uint32_t min0, uint32_t max0)
{
	uint32_t i;

	if (x < (double)min0)
		i = (uint32_t)min0;
	if (x > (double)max0)
		i = (uint32_t)max0;

	i = (uint32_t)x;
	if ((double)i > x)
		--i;
	return i;
}

void osic_alloc(X2C_ADDRESS *p, uint32_t size)
{
	void *pmem;

	pmem = malloc(size);
	if (pmem == NULL)
		return;
	*p = pmem;
}

uint32_t osic_time(void)
{
	return time(NULL);
}

uint32_t osi_realcard(float x)
{
	return (uint32_t)X2C_TRUNCC(x, 0UL, X2C_max_longcard);
}

uint32_t X2C_LSH(uint32_t a, int32_t length, int32_t n)
{
	uint32_t m;

	m = 0;
	m = (length == 32) ? 0xFFFFFFFFl : (1 << length) - 1;
	if (n > 0) {
		if (n >= (int32_t)length)
			return 0;
		return (a << n) & m;
	}

	if (n <= (int32_t)-length)
		return 0;
	return (a >> -n) & m;
}

char X2C_IN(uint32_t i, uint32_t bits, uint32_t set)
{
	if (i < bits)
		return (((1 << (int)i) & set) != 0);
	return 0;
}

struct xrMM_Dynarr {
	char *a;
	size_t n[15];
};

static size_t xrMM_DynarrDescSize(size_t i)
{
	return (sizeof(char *) + i * sizeof(size_t) * 2);
}

static void X2C_InitDesc(struct xrMM_Dynarr *d, size_t *size, size_t lens[], size_t dims)
{
	uint32_t i;
	uint32_t tmp;

	d->n[(dims - 1) * 2] = lens[0];
	tmp = dims - 1;
	i = 1;
	if (i <= tmp) {
		for (;; i++) {
			*size =  *size * lens[dims-i];
			d->n[i * 2 - 1] = *size;
			d->n[(dims - i) * 2 - 2] = lens[i];
			if (i == tmp)
				break;
		}
	}
	*size =  *size*lens[0];
}

void X2C_DYNALLOCATE(char **a, size_t size, size_t lens[], size_t dims)
{
	struct xrMM_Dynarr *desc;

	*a = 0;
	desc = malloc(xrMM_DynarrDescSize(dims));
	if (desc) {
		X2C_InitDesc(desc, &size, lens, dims);
		desc->a = malloc(size);
		if (desc->a == 0)
			free(desc);
		else
			*a = (char *)desc;
	}
}

void X2C_DYNDEALLOCATE(char **a)
{
	struct xrMM_Dynarr *d;

	if (*a) {
		d = (struct xrMM_Dynarr *)*a;
		free(d->a);
		free(d);
	}
}

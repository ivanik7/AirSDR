/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef SDRCORE_LORARX_EMBED_H
#define SDRCORE_LORARX_EMBED_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Global-state upstream demodulator: caller serializes every entry and callback. */
int lorarx_embed_start(int argc, char **argv);
int lorarx_embed_block(const float *interleaved_iq, size_t complex_frames);
void lorarx_embed_clear(void);
/* Application-owned JSON sink; the demodulator never opens a file or socket. */
void lorarx_embed_emit(const char *json, size_t length);
#ifdef __cplusplus
}
#endif
#endif

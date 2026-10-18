/* SPDX-License-Identifier: GPL-2.0-or-later */
/* In-process entry points for the vendored OE5DXL lorarx demodulator.
   Built only with -DSDRCORE_LORARX_EMBED; the unmodified upstream main()
   (and its file/pipe/UDP IO) is compiled out. */
#ifndef SDRCORE_LORARX_EMBED_H
#define SDRCORE_LORARX_EMBED_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Upstream inreform() reads exactly isize*8192 bytes per call, i.e. 4096
   complex f32 frames; every block passed in must be exactly this size. */
#define LORARX_EMBED_BLOCK_FRAMES 4096u
/* The demodulator keeps all state in process globals: one instance per
   process, and the caller serializes every call and callback.
   start(): upstream main() up to opening the IQ input, using the same argv
     (only "-f f32" input is accepted), plus main()'s first demod pass.
     Returns 1 on success, 0 when upstream would abort (bad options, OOM).
   block(): one more turn of main()'s read/demod loop on one block. Every
     JSON line that upstream would write to -j is passed to
     lorarx_embed_emit() before block() returns. 0 = aborted/not started.
   clear(): frees everything; state equals a freshly started process. */
int lorarx_embed_start(int argc, char **argv);
int lorarx_embed_block(const float *interleaved_iq, size_t complex_frames);
void lorarx_embed_clear(void);
/* Unwinds the active start()/block() call (upstream abort path). */
void lorarx_embed_abort(void);
/* Application-owned JSON sink; the demodulator never opens a file or socket. */
void lorarx_embed_emit(const char *json, size_t length);
#ifdef __cplusplus
}
#endif
#endif

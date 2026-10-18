/* SPDX-License-Identifier: GPL-2.0-or-later */
/* In-process replacement for the dxlAPRS osi layer (upstream-os/osi.h).
   Only the entry points the vendored decoder sources reference are
   declared; no tcp/termios/dirent dependency, so the embed also builds for
   Android and Windows (llvm-mingw). */
#ifndef osi_H_
#define osi_H_
#ifndef X2C_H_
#include "X2C.h"
#endif
#include "udp.h"
#include "mlib.h"
#include <osic.h>

extern int32_t osi_OpenWrite(char [], uint32_t);
extern int32_t osi_OpenRead(char [], uint32_t);
extern int32_t osi_OpenNONBLOCK(char [], uint32_t);
extern int32_t osi_RdBin(int32_t, char [], uint32_t, uint32_t);
extern void osi_WrBin(int32_t, char [], uint32_t, uint32_t);
extern void osi_Werr(char [], uint32_t);
extern char osi_IsFifo(int32_t);
extern void osi_NextArg(char [], uint32_t);
extern void osi_WrStr(char [], uint32_t);
extern void osi_WrStrLn(char [], uint32_t);
extern uint32_t osi_realcard(float);
extern void osi_BEGIN(void);

#endif /* osi_H_ */

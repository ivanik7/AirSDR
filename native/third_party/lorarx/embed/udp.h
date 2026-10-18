/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Embedded build: no sockets. openudp() fails and udpsend() drops, so the
   -U/-L/-J/-u/-t options are inert (OpenWebRX+ passes none of them). */
#ifndef udp_H_
#define udp_H_
extern long openudp(void);
extern long udpsend(long, char [], long, unsigned long, unsigned long);
#endif /* udp_H_ */

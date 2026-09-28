/* Fake libusb control API for the librtlsdr oracle. SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef FAKE_LIBUSB_CTL_H
#define FAKE_LIBUSB_CTL_H

#include <stdio.h>

enum fake_tuner {
	FAKE_TUNER_NONE = 0,
	FAKE_TUNER_E4000,
	FAKE_TUNER_FC0012,
	FAKE_TUNER_FC0013,
	FAKE_TUNER_FC2580,
	FAKE_TUNER_R820T,
	FAKE_TUNER_R828D,
};

struct fake_model {
	enum fake_tuner tuner;
	char manufact[64];
	char product[64];
	char serial[64];
	int pll_lock;          /* R82xx: PLL lock bit reported (except every 7th read) */
	int fail_first_write;  /* first block-register OUT transfer fails (-> reset path) */
};

void fake_usb_setup(FILE *out, const struct fake_model *m);
void fake_usb_trace(const char *fmt, ...);

#endif

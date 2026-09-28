/* Scenario configuration of the fake libusb (see fake_libusb.c).
 * SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once

typedef struct {
	int bcd_device;     /* descriptor bcdDevice == usb_api_version */
	int current_config; /* answer of GET_CONFIGURATION */
	int fail_req;       /* bRequest answered with LIBUSB_ERROR_PIPE (-1: none) */
	int short_req;      /* bRequest answered with half the bytes (-1: none) */
	int product_id;
} fake_config_t;

extern fake_config_t fake_config;

void fake_trace_open(const char* path);
void fake_trace_close(void);
void fake_trace(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

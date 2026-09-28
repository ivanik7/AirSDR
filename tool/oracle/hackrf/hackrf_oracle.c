/*
 * libhackrf host oracle: runs fixed scenarios against the real
 * host/libhackrf/src/hackrf.c linked with fake_libusb.c and writes a trace.
 * The Dart test test/drivers/hackrf/hackrf_oracle_test.dart runs the very
 * same scenarios against lib/drivers/hackrf/hackrf.dart and compares traces
 * with the golden files produced by this program (tool/oracle/hackrf/golden).
 *
 * Usage: hackrf_oracle <main|oldfw|errors|openfail|rates> <trace-file>
 *
 * Keep this file and the scenarios in hackrf_oracle_test.dart in sync.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "hackrf.h"
#include "fake_libusb.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int rx_cb(hackrf_transfer* transfer)
{
	(void) transfer;
	return 0;
}

static uint64_t dbits(double d)
{
	uint64_t u;
	memcpy(&u, &d, sizeof(u));
	return u;
}

#define R(name, expr)                                     \
	do {                                              \
		int _r = (expr);                          \
		fake_trace("RESULT %s=%d", name, _r);     \
	} while (0)

static void sample_rate(hackrf_device* dev, double sr)
{
	int r = hackrf_set_sample_rate(dev, sr);
	fake_trace("RESULT set_sample_rate(%016" PRIx64 ")=%d", dbits(sr), r);
}

static hackrf_device* do_open(void)
{
	hackrf_device* dev = NULL;
	int r = hackrf_open(&dev);
	fake_trace("RESULT open=%d", r);
	if (r != HACKRF_SUCCESS) {
		fake_trace("INFO open_error=%s", hackrf_error_name(r));
		return NULL;
	}
	return dev;
}

static void do_close(hackrf_device* dev)
{
	R("close", hackrf_close(dev));
}

static void scenario_main(void)
{
	hackrf_device* dev;
	uint16_t api = 0;
	uint8_t board_id = BOARD_ID_UNDETECTED;
	char version[255 + 1];
	read_partid_serialno_t ps;
	const double rates[] = {2e6, 8e6, 20e6, 10.123456e6};
	const uint64_t freqs[] = {100000000ull, 433920000ull, 2400000000ull};
	size_t i;

	fake_config.bcd_device = 0x0112;
	fake_config.current_config = 0;

	dev = do_open();
	if (dev == NULL)
		return;

	R("usb_api_version_read", hackrf_usb_api_version_read(dev, &api));
	fake_trace("INFO usb_api_version=%04x", api);

	R("board_id_read", hackrf_board_id_read(dev, &board_id));
	fake_trace("INFO board_id=%u name=%s", board_id, hackrf_board_id_name(board_id));

	R("version_string_read", hackrf_version_string_read(dev, version, 255));
	fake_trace("INFO version=%s", version);

	R("board_partid_serialno_read", hackrf_board_partid_serialno_read(dev, &ps));
	fake_trace(
		"INFO part_id=%08x %08x serial=%08x %08x %08x %08x",
		ps.part_id[0],
		ps.part_id[1],
		ps.serial_no[0],
		ps.serial_no[1],
		ps.serial_no[2],
		ps.serial_no[3]);

	/* hackrf_source.cpp start(): set_sample_rate, then baseband filter
	 * (Auto == hackrf_compute_baseband_filter_bw(sampleRate)) */
	for (i = 0; i < sizeof(rates) / sizeof(rates[0]); i++) {
		uint32_t bw;
		sample_rate(dev, rates[i]);
		bw = hackrf_compute_baseband_filter_bw((uint32_t) rates[i]);
		fake_trace("INFO bw_auto=%u", bw);
		R("set_baseband_filter_bandwidth", hackrf_set_baseband_filter_bandwidth(dev, bw));
	}

	for (i = 0; i < sizeof(freqs) / sizeof(freqs[0]); i++) {
		R("set_freq", hackrf_set_freq(dev, freqs[i]));
	}

	R("set_freq_explicit",
	  hackrf_set_freq_explicit(dev, 2600000000ull, 2500000000ull, RF_PATH_FILTER_HIGH_PASS));
	R("set_freq_explicit_bypass",
	  hackrf_set_freq_explicit(dev, 2450000000ull, 0ull, RF_PATH_FILTER_BYPASS));
	R("set_freq_explicit_bad_if",
	  hackrf_set_freq_explicit(dev, 1900000000ull, 2500000000ull, RF_PATH_FILTER_LOW_PASS));
	R("set_freq_explicit_bad_lo",
	  hackrf_set_freq_explicit(dev, 2600000000ull, 80000000ull, RF_PATH_FILTER_LOW_PASS));

	R("set_lna_gain(16)", hackrf_set_lna_gain(dev, 16));
	R("set_vga_gain(20)", hackrf_set_vga_gain(dev, 20));
	R("set_lna_gain(39)", hackrf_set_lna_gain(dev, 39));
	R("set_lna_gain(41)", hackrf_set_lna_gain(dev, 41));
	R("set_vga_gain(21)", hackrf_set_vga_gain(dev, 21));
	R("set_vga_gain(62)", hackrf_set_vga_gain(dev, 62));
	R("set_vga_gain(63)", hackrf_set_vga_gain(dev, 63));
	R("set_amp_enable(1)", hackrf_set_amp_enable(dev, 1));
	R("set_amp_enable(0)", hackrf_set_amp_enable(dev, 0));
	R("set_antenna_enable(1)", hackrf_set_antenna_enable(dev, 1));
	R("set_antenna_enable(0)", hackrf_set_antenna_enable(dev, 0));

	R("is_streaming", hackrf_is_streaming(dev));
	R("start_rx", hackrf_start_rx(dev, rx_cb, NULL));
	R("is_streaming", hackrf_is_streaming(dev));
	R("start_rx_again", hackrf_start_rx(dev, rx_cb, NULL));
	R("stop_rx", hackrf_stop_rx(dev));
	R("is_streaming", hackrf_is_streaming(dev));
	R("stop_rx_again", hackrf_stop_rx(dev));

	/* SDR++ hackrf_source stop(): no hackrf_stop_rx, just hackrf_close */
	R("start_rx", hackrf_start_rx(dev, rx_cb, NULL));
	do_close(dev);
}

static void scenario_oldfw(void)
{
	hackrf_device* dev;
	uint16_t api = 0;

	fake_config.bcd_device = 0x0100;
	fake_config.current_config = 1;
	fake_config.product_id = 0x604b;

	dev = do_open();
	if (dev == NULL)
		return;
	R("usb_api_version_read", hackrf_usb_api_version_read(dev, &api));
	fake_trace("INFO usb_api_version=%04x", api);
	sample_rate(dev, 2e6);
	do_close(dev);
}

static void scenario_errors(void)
{
	hackrf_device* dev;
	int r;

	fake_config.bcd_device = 0x0112;
	fake_config.current_config = 0;
	fake_config.fail_req = 16;  /* SET_FREQ -> LIBUSB_ERROR_PIPE */
	fake_config.short_req = 6;  /* SAMPLE_RATE_SET -> short write */

	dev = do_open();
	if (dev == NULL)
		return;

	r = hackrf_set_freq(dev, 100000000ull);
	fake_trace("RESULT set_freq=%d", r);
	fake_trace("INFO error_name=%s", hackrf_error_name(r));

	sample_rate(dev, 10e6);
	R("set_lna_gain(8)", hackrf_set_lna_gain(dev, 8));
	do_close(dev);
}

static void scenario_openfail(void)
{
	fake_config.bcd_device = 0x0112;
	fake_config.current_config = 0;
	fake_config.fail_req = 61; /* GET_BUFFER_SIZE */
	(void) do_open();
}

static void scenario_rates(void)
{
	hackrf_device* dev;
	size_t i;
	const double rates[] = {
		1e6,
		2e6,
		2.048e6,
		2.4e6,
		3.2e6,
		4e6,
		5e6,
		8e6,
		10e6,
		10.123456e6,
		12.5e6,
		16e6,
		20e6,
		8e6 / 3,
		20e6 / 3,
		10e6 / 7,
		1234567.891,
		5555555.5555,
		7.777777e6,
		19999999.999,
		4410000.5,
		3e6 + 1.0 / 3,
		6e6 + 0.25,
		9e6 + 0.1,
	};
	const uint32_t bws[] = {
		0,
		1,
		1000000,
		1749999,
		1750000,
		1750001,
		2499999,
		2500000,
		3000000,
		5500000,
		7500000,
		9000000,
		10000000,
		13999999,
		15000001,
		20000000,
		24000000,
		27999999,
		28000000,
		28000001,
		40000000,
		0xffffffffu,
	};

	fake_config.bcd_device = 0x0112;
	fake_config.current_config = 1;

	for (i = 0; i < sizeof(bws) / sizeof(bws[0]); i++) {
		fake_trace(
			"INFO bw(%u)=%u lt=%u",
			bws[i],
			hackrf_compute_baseband_filter_bw(bws[i]),
			hackrf_compute_baseband_filter_bw_round_down_lt(bws[i]));
	}

	dev = do_open();
	if (dev == NULL)
		return;
	for (i = 0; i < sizeof(rates) / sizeof(rates[0]); i++)
		sample_rate(dev, rates[i]);
	for (i = 0; i < 16; i++)
		fake_trace("INFO error_name(%d)=%s", -(int) i, hackrf_error_name((enum hackrf_error) - (int) i));
	{
		const int codes[] = {1, -1000, -1001, -1002, -1003, -1004, -1005, -2000, -9999, 42};
		for (i = 0; i < sizeof(codes) / sizeof(codes[0]); i++)
			fake_trace(
				"INFO error_name(%d)=%s",
				codes[i],
				hackrf_error_name((enum hackrf_error) codes[i]));
	}
	for (i = 0; i < 8; i++)
		fake_trace("INFO board_id_name(%zu)=%s", i, hackrf_board_id_name((enum hackrf_board_id) i));
	fake_trace("INFO board_id_name(254)=%s", hackrf_board_id_name(BOARD_ID_UNRECOGNIZED));
	fake_trace("INFO board_id_name(255)=%s", hackrf_board_id_name(BOARD_ID_UNDETECTED));
	do_close(dev);
}

int main(int argc, char** argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s <scenario> <trace>\n", argv[0]);
		return 1;
	}
	fake_trace_open(argv[2]);
	R("init", hackrf_init());
	if (!strcmp(argv[1], "main"))
		scenario_main();
	else if (!strcmp(argv[1], "oldfw"))
		scenario_oldfw();
	else if (!strcmp(argv[1], "errors"))
		scenario_errors();
	else if (!strcmp(argv[1], "openfail"))
		scenario_openfail();
	else if (!strcmp(argv[1], "rates"))
		scenario_rates();
	else {
		fprintf(stderr, "unknown scenario %s\n", argv[1]);
		return 1;
	}
	fake_trace_close();
	return 0;
}

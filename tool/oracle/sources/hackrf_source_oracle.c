/*
 * libhackrf host oracle for the SDR++ hackrf_source module port
 * (lib/sdrpp/modules/sources/hackrf_source.dart): replays the exact libhackrf
 * call sequence of hackrf_source/src/main.cpp start()/tune()/menu/stop()
 * against the real hackrf.c linked with tool/oracle/hackrf/fake_libusb.
 *
 * Usage: hackrf_source_oracle <default|configured> <trace-file>
 * Keep in sync with test/sdrpp/modules/sources/hackrf_source_test.dart.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "hackrf.h"
#include "fake_libusb.h"

#include <stdio.h>
#include <string.h>

static int rx_cb(hackrf_transfer* transfer)
{
	(void) transfer;
	return 0;
}

static const int bandwidths[] = {1750000, 2500000, 3500000, 5000000, 5500000, 6000000,
				 7000000, 8000000, 9000000, 10000000, 12000000, 14000000,
				 15000000, 20000000, 24000000, 28000000};

static int sampleRate;

/* main.cpp:238-241 */
static int bandwidthIdToBw(int id)
{
	if (id == 16) {
		return hackrf_compute_baseband_filter_bw(sampleRate);
	}
	return bandwidths[id];
}

/* main.cpp:243-274 with hackrf_open (fake: the single fake device) instead
 * of hackrf_open_by_fd */
static hackrf_device* start(int bwId, double freq, int biasT, int amp, float lna, float vga)
{
	hackrf_device* dev = NULL;
	if (hackrf_open(&dev) != HACKRF_SUCCESS)
		return NULL;
	hackrf_set_sample_rate(dev, sampleRate);
	hackrf_set_baseband_filter_bandwidth(dev, bandwidthIdToBw(bwId));
	hackrf_set_freq(dev, freq);

	hackrf_set_antenna_enable(dev, biasT);
	hackrf_set_amp_enable(dev, amp);
	hackrf_set_lna_gain(dev, lna);
	hackrf_set_vga_gain(dev, vga);

	hackrf_start_rx(dev, rx_cb, NULL);
	return dev;
}

static void scenario_default(void)
{
	hackrf_device* dev;
	fake_config.bcd_device = 0x0112;
	fake_config.current_config = 0;
	hackrf_init();
	sampleRate = 2000000;
	dev = start(16, 100000000.0, 0, 0, 0, 0);
	if (!dev)
		return;
	/* tune() */
	hackrf_set_freq(dev, 433920000.0);
	/* stop(): no hackrf_stop_rx */
	hackrf_close(dev);
}

static void scenario_configured(void)
{
	hackrf_device* dev;
	fake_config.bcd_device = 0x0112;
	fake_config.current_config = 1;
	hackrf_init();
	/* config: sampleRate 20M, bandwidth Auto, lna 40, vga 62, biasT, amp */
	sampleRate = 20000000;
	dev = start(16, 100000000.0, 1, 1, 40, 62);
	if (!dev)
		return;
	hackrf_set_freq(dev, 2400000000.0);
	/* menu while running (main.cpp:332-381) */
	hackrf_set_baseband_filter_bandwidth(dev, bandwidthIdToBw(5)); /* 6MHz */
	hackrf_set_lna_gain(dev, 24);
	hackrf_set_vga_gain(dev, 30);
	hackrf_set_antenna_enable(dev, 0);
	hackrf_set_amp_enable(dev, 0);
	hackrf_set_freq(dev, 145500000.0);
	hackrf_close(dev);
}

int main(int argc, char** argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s <scenario> <trace>\n", argv[0]);
		return 1;
	}
	fake_trace_open(argv[2]);
	if (!strcmp(argv[1], "default"))
		scenario_default();
	else if (!strcmp(argv[1], "configured"))
		scenario_configured();
	else {
		fprintf(stderr, "unknown scenario %s\n", argv[1]);
		return 1;
	}
	fake_trace_close();
	return 0;
}

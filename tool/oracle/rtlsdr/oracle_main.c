/*
 * librtlsdr host oracle: runs a scenario script against the real osmocom
 * librtlsdr (compiled with the fake libusb in fake_libusb.c) and writes the
 * resulting USB trace. The Dart test (test/drivers/rtlsdr/oracle_trace_test.dart)
 * runs the same scenario through the Dart port and diffs the traces.
 *
 * usage: rtlsdr_oracle <scenario.txt> <trace.out>
 *
 * Scenario format: one command per line, '#' comments. The first command must
 * be "model key=value ..." (tuner=r820t|r828d|e4000|fc0012|fc0013|fc2580|none,
 * manufact=, product=, serial= (use '_' for spaces), lock=0|1, failfirst=0|1).
 * Every API call is echoed into the trace as "CALL <cmd> <args> -> <ret>".
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rtl-sdr.h"
#include "fake_libusb.h"

static void unscore(char *s)
{
	for (; *s; s++)
		if (*s == '_')
			*s = ' ';
}

static void parse_model(char *args, struct fake_model *m)
{
	char *tok;
	memset(m, 0, sizeof(*m));
	strcpy(m->manufact, "Realtek");
	strcpy(m->product, "RTL2838UHIDIR");
	strcpy(m->serial, "00000001");
	m->pll_lock = 1;
	for (tok = strtok(args, " \t"); tok; tok = strtok(NULL, " \t")) {
		char *eq = strchr(tok, '=');
		if (!eq)
			continue;
		*eq = 0;
		if (!strcmp(tok, "tuner")) {
			const char *v = eq + 1;
			m->tuner = !strcmp(v, "r820t") ? FAKE_TUNER_R820T :
				   !strcmp(v, "r828d") ? FAKE_TUNER_R828D :
				   !strcmp(v, "e4000") ? FAKE_TUNER_E4000 :
				   !strcmp(v, "fc0012") ? FAKE_TUNER_FC0012 :
				   !strcmp(v, "fc0013") ? FAKE_TUNER_FC0013 :
				   !strcmp(v, "fc2580") ? FAKE_TUNER_FC2580 : FAKE_TUNER_NONE;
		} else if (!strcmp(tok, "manufact")) {
			snprintf(m->manufact, sizeof(m->manufact), "%s", eq + 1);
			unscore(m->manufact);
		} else if (!strcmp(tok, "product")) {
			snprintf(m->product, sizeof(m->product), "%s", eq + 1);
			unscore(m->product);
		} else if (!strcmp(tok, "serial")) {
			snprintf(m->serial, sizeof(m->serial), "%s", eq + 1);
			unscore(m->serial);
		} else if (!strcmp(tok, "lock")) {
			m->pll_lock = atoi(eq + 1);
		} else if (!strcmp(tok, "failfirst")) {
			m->fail_first_write = atoi(eq + 1);
		}
	}
}

int main(int argc, char **argv)
{
	FILE *in, *out;
	char line[512];
	rtlsdr_dev_t *dev = NULL;

	if (argc != 3) {
		fprintf(stderr, "usage: %s <scenario> <trace>\n", argv[0]);
		return 2;
	}
	in = fopen(argv[1], "r");
	out = fopen(argv[2], "w");
	if (!in || !out) {
		perror("fopen");
		return 2;
	}

	while (fgets(line, sizeof(line), in)) {
		char cmd[64];
		long a = 0, b = 0;
		int n, r;
		char *nl = strpbrk(line, "\r\n");
		if (nl)
			*nl = 0;
		if (line[0] == '#' || line[0] == 0)
			continue;
		n = sscanf(line, "%63s %ld %ld", cmd, &a, &b);
		if (n < 1)
			continue;

		if (!strcmp(cmd, "model")) {
			struct fake_model m;
			parse_model(line + 5, &m);
			fake_usb_setup(out, &m);
			continue;
		}

		if (!strcmp(cmd, "open")) {
			r = rtlsdr_open(&dev, 0);
			fake_usb_trace("CALL open -> %d\n", r);
		} else if (!strcmp(cmd, "close")) {
			r = rtlsdr_close(dev);
			dev = NULL;
			fake_usb_trace("CALL close -> %d\n", r);
		} else if (!strcmp(cmd, "set_sample_rate")) {
			r = rtlsdr_set_sample_rate(dev, (uint32_t)a);
			fake_usb_trace("CALL %s %ld -> %d\n", cmd, a, r);
		} else if (!strcmp(cmd, "get_sample_rate")) {
			fake_usb_trace("CALL %s -> %u\n", cmd, rtlsdr_get_sample_rate(dev));
		} else if (!strcmp(cmd, "set_center_freq")) {
			r = rtlsdr_set_center_freq(dev, (uint32_t)a);
			fake_usb_trace("CALL %s %ld -> %d\n", cmd, a, r);
		} else if (!strcmp(cmd, "get_center_freq")) {
			fake_usb_trace("CALL %s -> %u\n", cmd, rtlsdr_get_center_freq(dev));
		} else if (!strcmp(cmd, "set_freq_correction")) {
			r = rtlsdr_set_freq_correction(dev, (int)a);
			fake_usb_trace("CALL %s %ld -> %d\n", cmd, a, r);
		} else if (!strcmp(cmd, "get_freq_correction")) {
			fake_usb_trace("CALL %s -> %d\n", cmd, rtlsdr_get_freq_correction(dev));
		} else if (!strcmp(cmd, "set_xtal_freq")) {
			r = rtlsdr_set_xtal_freq(dev, (uint32_t)a, (uint32_t)b);
			fake_usb_trace("CALL %s %ld %ld -> %d\n", cmd, a, b, r);
		} else if (!strcmp(cmd, "get_xtal_freq")) {
			uint32_t rx = 0, tx = 0;
			r = rtlsdr_get_xtal_freq(dev, &rx, &tx);
			fake_usb_trace("CALL %s -> %d %u %u\n", cmd, r, rx, tx);
		} else if (!strcmp(cmd, "get_tuner_type")) {
			fake_usb_trace("CALL %s -> %d\n", cmd, (int)rtlsdr_get_tuner_type(dev));
		} else if (!strcmp(cmd, "get_tuner_gains")) {
			int gains[64], i;
			r = rtlsdr_get_tuner_gains(dev, gains);
			fake_usb_trace("CALL %s -> %d", cmd, r);
			for (i = 0; i < r; i++)
				fake_usb_trace(" %d", gains[i]);
			fake_usb_trace("\n");
		} else if (!strcmp(cmd, "set_tuner_bandwidth")) {
			r = rtlsdr_set_tuner_bandwidth(dev, (uint32_t)a);
			fake_usb_trace("CALL %s %ld -> %d\n", cmd, a, r);
		} else if (!strcmp(cmd, "set_tuner_gain")) {
			r = rtlsdr_set_tuner_gain(dev, (int)a);
			fake_usb_trace("CALL %s %ld -> %d\n", cmd, a, r);
		} else if (!strcmp(cmd, "get_tuner_gain")) {
			fake_usb_trace("CALL %s -> %d\n", cmd, rtlsdr_get_tuner_gain(dev));
		} else if (!strcmp(cmd, "set_tuner_if_gain")) {
			r = rtlsdr_set_tuner_if_gain(dev, (int)a, (int)b);
			fake_usb_trace("CALL %s %ld %ld -> %d\n", cmd, a, b, r);
		} else if (!strcmp(cmd, "set_tuner_gain_mode")) {
			r = rtlsdr_set_tuner_gain_mode(dev, (int)a);
			fake_usb_trace("CALL %s %ld -> %d\n", cmd, a, r);
		} else if (!strcmp(cmd, "set_testmode")) {
			r = rtlsdr_set_testmode(dev, (int)a);
			fake_usb_trace("CALL %s %ld -> %d\n", cmd, a, r);
		} else if (!strcmp(cmd, "set_agc_mode")) {
			r = rtlsdr_set_agc_mode(dev, (int)a);
			fake_usb_trace("CALL %s %ld -> %d\n", cmd, a, r);
		} else if (!strcmp(cmd, "set_direct_sampling")) {
			r = rtlsdr_set_direct_sampling(dev, (int)a);
			fake_usb_trace("CALL %s %ld -> %d\n", cmd, a, r);
		} else if (!strcmp(cmd, "get_direct_sampling")) {
			fake_usb_trace("CALL %s -> %d\n", cmd, rtlsdr_get_direct_sampling(dev));
		} else if (!strcmp(cmd, "set_offset_tuning")) {
			r = rtlsdr_set_offset_tuning(dev, (int)a);
			fake_usb_trace("CALL %s %ld -> %d\n", cmd, a, r);
		} else if (!strcmp(cmd, "get_offset_tuning")) {
			fake_usb_trace("CALL %s -> %d\n", cmd, rtlsdr_get_offset_tuning(dev));
		} else if (!strcmp(cmd, "set_bias_tee")) {
			r = rtlsdr_set_bias_tee(dev, (int)a);
			fake_usb_trace("CALL %s %ld -> %d\n", cmd, a, r);
		} else if (!strcmp(cmd, "set_bias_tee_gpio")) {
			r = rtlsdr_set_bias_tee_gpio(dev, (int)a, (int)b);
			fake_usb_trace("CALL %s %ld %ld -> %d\n", cmd, a, b, r);
		} else if (!strcmp(cmd, "reset_buffer")) {
			r = rtlsdr_reset_buffer(dev);
			fake_usb_trace("CALL %s -> %d\n", cmd, r);
		} else if (!strcmp(cmd, "read_sync")) {
			unsigned char *buf = malloc(a);
			int nread = 0;
			unsigned sum = 0;
			long i;
			r = rtlsdr_read_sync(dev, buf, (int)a, &nread);
			for (i = 0; i < nread; i++)
				sum = sum * 31 + buf[i];
			fake_usb_trace("CALL %s %ld -> %d %d %u\n", cmd, a, r, nread, sum);
			free(buf);
		} else if (!strcmp(cmd, "read_eeprom")) {
			uint8_t buf[256];
			int i;
			memset(buf, 0, sizeof(buf));
			r = rtlsdr_read_eeprom(dev, buf, (uint8_t)a, (uint16_t)b);
			fake_usb_trace("CALL %s %ld %ld -> %d", cmd, a, b, r);
			for (i = 0; i < b && i < 256; i++)
				fake_usb_trace(" %02x", buf[i]);
			fake_usb_trace("\n");
		} else if (!strcmp(cmd, "write_eeprom")) {
			/* write_eeprom <offset> <len>: data[i] = (i * 5 + 1) */
			uint8_t buf[256];
			int i;
			for (i = 0; i < 256; i++)
				buf[i] = (uint8_t)(i * 5 + 1);
			r = rtlsdr_write_eeprom(dev, buf, (uint8_t)a, (uint16_t)b);
			fake_usb_trace("CALL %s %ld %ld -> %d\n", cmd, a, b, r);
		} else if (!strcmp(cmd, "get_usb_strings")) {
			char m[256], p[256], s[256];
			r = rtlsdr_get_usb_strings(dev, m, p, s);
			fake_usb_trace("CALL %s -> %d [%s] [%s] [%s]\n", cmd, r, m, p, s);
		} else {
			fprintf(stderr, "unknown command: %s\n", cmd);
			return 3;
		}
	}

	fclose(out);
	fclose(in);
	return 0;
}

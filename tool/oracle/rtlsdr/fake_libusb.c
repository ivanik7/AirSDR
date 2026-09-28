/*
 * Fake libusb-1.0 for the librtlsdr host oracle.
 *
 * Records every device-visible libusb call into a trace (one line per call)
 * and answers IN transfers from a small deterministic RTL2832U + tuner model.
 * Enumeration-only calls (init, device list, descriptors, kernel driver
 * checks) are NOT traced because the Dart port receives an already opened
 * UsbDeviceHandle.
 *
 * Trace line formats (shared with test/drivers/rtlsdr/oracle_replay.dart):
 *   CTRL rt=c0 req=00 val=0120 idx=000a len=1 to=300 ret=1 data=00
 *   BULK ep=81 len=512 to=0 ret=0 act=512
 *   STR idx=1 ret=10 s=RTLSDRBlog
 *   CLAIM if=0 ret=0 | RELEASE if=0 ret=0 | RESET ret=0 | CLOSE
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include "libusb.h"
#include "fake_libusb.h"

struct libusb_context { int dummy; };
struct libusb_device { struct libusb_device_descriptor dd; };
struct libusb_device_handle { libusb_device *dev; };

static FILE *trace_out;
static struct fake_model model;
static libusb_device the_device;
static libusb_device_handle the_handle;

/* RTL2832U register model */
static uint8_t block_mem[8][0x10000];     /* block regs (USBB, SYSB, ...) */
static uint8_t demod_mem[16][0x100];      /* demod pages */

/* I2C model */
static uint8_t i2c_ptr[256];
static uint8_t i2c_regs[256][256];
static uint8_t eeprom[256];
static unsigned r82xx_reads;

void fake_usb_trace(const char *fmt, ...)
{
	va_list ap;
	if (!trace_out)
		return;
	va_start(ap, fmt);
	vfprintf(trace_out, fmt, ap);
	va_end(ap);
	fflush(trace_out);
}

static uint8_t bitrev(uint8_t byte)
{
	static const uint8_t lut[16] = { 0x0, 0x8, 0x4, 0xc, 0x2, 0xa, 0x6, 0xe,
					 0x1, 0x9, 0x5, 0xd, 0x3, 0xb, 0x7, 0xf };
	return (lut[byte & 0xf] << 4) | lut[byte >> 4];
}

void fake_usb_setup(FILE *out, const struct fake_model *m)
{
	int i;

	trace_out = out;
	model = *m;
	memset(block_mem, 0, sizeof(block_mem));
	memset(demod_mem, 0, sizeof(demod_mem));
	memset(i2c_ptr, 0, sizeof(i2c_ptr));
	memset(i2c_regs, 0, sizeof(i2c_regs));
	r82xx_reads = 0;
	for (i = 0; i < 256; i++)
		eeprom[i] = (uint8_t)(i * 7 + 3);

	/* tuner ID registers (read raw, without bitrev) */
	switch (model.tuner) {
	case FAKE_TUNER_E4000:	i2c_regs[0xc8][0x02] = 0x40; break;
	case FAKE_TUNER_FC0013:	i2c_regs[0xc6][0x00] = 0xa3; break;
	case FAKE_TUNER_FC0012:	i2c_regs[0xc6][0x00] = 0xa1; break;
	case FAKE_TUNER_FC2580:	i2c_regs[0xac][0x01] = 0x56; break;
	default: break;
	}

	memset(&the_device, 0, sizeof(the_device));
	the_device.dd.idVendor = 0x0bda;
	the_device.dd.idProduct = 0x2838;
	the_device.dd.iManufacturer = 1;
	the_device.dd.iProduct = 2;
	the_device.dd.iSerialNumber = 3;
	the_handle.dev = &the_device;
}

static int i2c_present(uint8_t addr)
{
	if (addr == 0xa0)
		return 1; /* EEPROM always present */
	switch (model.tuner) {
	case FAKE_TUNER_R820T:	return addr == 0x34;
	case FAKE_TUNER_R828D:	return addr == 0x74;
	case FAKE_TUNER_E4000:	return addr == 0xc8;
	case FAKE_TUNER_FC0013:
	case FAKE_TUNER_FC0012:	return addr == 0xc6;
	case FAKE_TUNER_FC2580:	return addr == 0xac;
	default:		return 0;
	}
}

static int is_r82xx_addr(uint8_t addr)
{
	return (model.tuner == FAKE_TUNER_R820T && addr == 0x34) ||
	       (model.tuner == FAKE_TUNER_R828D && addr == 0x74);
}

/* returns bytes transferred or a LIBUSB_ERROR */
static int model_i2c(int in, uint8_t addr, unsigned char *data, uint16_t len)
{
	int i;

	if (!i2c_present(addr))
		return LIBUSB_ERROR_PIPE;

	if (!in) {
		if (len < 1)
			return 0;
		if (addr == 0xa0) {
			i2c_ptr[addr] = data[0];
			for (i = 1; i < len; i++)
				eeprom[(uint8_t)(data[0] + i - 1)] = data[i];
			return len;
		}
		i2c_ptr[addr] = data[0];
		for (i = 1; i < len; i++)
			i2c_regs[addr][(uint8_t)(data[0] + i - 1)] = data[i];
		return len;
	}

	if (addr == 0xa0) {
		for (i = 0; i < len; i++)
			data[i] = eeprom[i2c_ptr[addr]++];
		return len;
	}

	if (is_r82xx_addr(addr)) {
		/* R82xx always reads from reg 0; bytes 1.. are bit reversed */
		uint8_t st[8];
		unsigned n = r82xx_reads++;
		int lock = model.pll_lock && (n % 7 != 6);
		memset(st, 0, sizeof(st));
		st[0] = 0x96;					/* ID 0x69 raw */
		st[1] = 0x00;
		st[2] = (lock ? 0x40 : 0x00) | 0x1c;		/* lock + vco band */
		st[3] = (uint8_t)(0x21 + n);			/* gain readback */
		st[4] = ((n % 3) << 4) | ((n % 2) ? 0x08 : 0x0f); /* vco fine tune, fil cal code */
		for (i = 0; i < len; i++)
			data[i] = (i == 0) ? 0x69 : bitrev(st[i < 8 ? i : 7]);
		return len;
	}

	for (i = 0; i < len; i++)
		data[i] = i2c_regs[addr][(uint8_t)(i2c_ptr[addr] + i)];
	return len;
}

static int model_ctrl(uint8_t rt, uint16_t val, uint16_t idx, unsigned char *data, uint16_t len)
{
	int in = rt & 0x80;
	int i;

	if ((rt & 0x60) != LIBUSB_REQUEST_TYPE_VENDOR)
		return LIBUSB_ERROR_PIPE;

	if ((val & 0xff) == 0x20 && ((idx >> 8) == 0)) {
		/* demod register: val = addr<<8 | 0x20, idx = [0x10|]page */
		uint8_t page = idx & 0x0f;
		uint8_t addr = val >> 8;
		for (i = 0; i < len; i++) {
			if (in)
				data[i] = demod_mem[page][(uint8_t)(addr + i)];
			else
				demod_mem[page][(uint8_t)(addr + i)] = data[i];
		}
		return len;
	}

	{
		uint8_t block = idx >> 8;
		if (block == 6) /* IICB */
			return model_i2c(in, (uint8_t)val, data, len);
		if (block > 7)
			return LIBUSB_ERROR_PIPE;
		for (i = 0; i < len; i++) {
			if (in)
				data[i] = block_mem[block][(uint16_t)(val + i)];
			else
				block_mem[block][(uint16_t)(val + i)] = data[i];
		}
		if (model.fail_first_write && !in) {
			model.fail_first_write = 0;
			return LIBUSB_ERROR_IO;
		}
		return len;
	}
}

/* ---- libusb API ---- */

int libusb_init(libusb_context **ctx)
{
	static libusb_context c;
	if (ctx)
		*ctx = &c;
	return 0;
}

void libusb_exit(libusb_context *ctx) { (void)ctx; }

ssize_t libusb_get_device_list(libusb_context *ctx, libusb_device ***list)
{
	static libusb_device *l[2];
	(void)ctx;
	l[0] = &the_device;
	l[1] = NULL;
	*list = l;
	return 1;
}

void libusb_free_device_list(libusb_device **list, int unref) { (void)list; (void)unref; }

int libusb_get_device_descriptor(libusb_device *dev, struct libusb_device_descriptor *desc)
{
	*desc = dev->dd;
	return 0;
}

libusb_device *libusb_get_device(libusb_device_handle *h) { return h->dev; }

int libusb_open(libusb_device *dev, libusb_device_handle **h)
{
	(void)dev;
	*h = &the_handle;
	return 0;
}

void libusb_close(libusb_device_handle *h)
{
	(void)h;
	fake_usb_trace("CLOSE\n");
}

int libusb_kernel_driver_active(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_detach_kernel_driver(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_attach_kernel_driver(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }

int libusb_claim_interface(libusb_device_handle *h, int i)
{
	(void)h;
	fake_usb_trace("CLAIM if=%d ret=0\n", i);
	return 0;
}

int libusb_release_interface(libusb_device_handle *h, int i)
{
	(void)h;
	fake_usb_trace("RELEASE if=%d ret=0\n", i);
	return 0;
}

int libusb_reset_device(libusb_device_handle *h)
{
	(void)h;
	fake_usb_trace("RESET ret=0\n");
	return 0;
}

int libusb_get_string_descriptor_ascii(libusb_device_handle *h, uint8_t idx,
				       unsigned char *data, int length)
{
	const char *s;
	int n;
	(void)h;
	if (idx == 0) {
		fake_usb_trace("STR idx=0 ret=%d s=\n", LIBUSB_ERROR_INVALID_PARAM);
		return LIBUSB_ERROR_INVALID_PARAM;
	}
	s = idx == 1 ? model.manufact : idx == 2 ? model.product : model.serial;
	n = (int)strlen(s);
	if (n > length - 1)
		n = length - 1;
	memcpy(data, s, n);
	data[n] = 0;
	fake_usb_trace("STR idx=%u ret=%d s=%s\n", idx, n, s);
	return n;
}

int libusb_control_transfer(libusb_device_handle *h, uint8_t rt, uint8_t req,
			    uint16_t val, uint16_t idx, unsigned char *data,
			    uint16_t len, unsigned int timeout)
{
	int r, i, n;
	(void)h;

	r = model_ctrl(rt, val, idx, data, len);

	fake_usb_trace("CTRL rt=%02x req=%02x val=%04x idx=%04x len=%u to=%u ret=%d data=",
		       rt, req, val, idx, len, timeout, r);
	/* OUT: the bytes sent; IN: the bytes returned */
	n = (rt & 0x80) ? (r > 0 ? r : 0) : len;
	for (i = 0; i < n; i++)
		fake_usb_trace("%02x", data[i]);
	fake_usb_trace("\n");
	return r;
}

int libusb_bulk_transfer(libusb_device_handle *h, unsigned char ep,
			 unsigned char *data, int length, int *actual, unsigned int timeout)
{
	int i;
	(void)h;
	for (i = 0; i < length; i++)
		data[i] = (unsigned char)(i * 3 + 1);
	if (actual)
		*actual = length;
	fake_usb_trace("BULK ep=%02x len=%d to=%u ret=0 act=%d\n", ep, length, timeout, length);
	return 0;
}

/* async API: only needed to link, the oracle scenarios do not stream */
struct libusb_transfer *libusb_alloc_transfer(int iso)
{
	(void)iso;
	return calloc(1, sizeof(struct libusb_transfer));
}

void libusb_free_transfer(struct libusb_transfer *t) { free(t); }
int libusb_submit_transfer(struct libusb_transfer *t) { (void)t; return LIBUSB_ERROR_NOT_SUPPORTED; }
int libusb_cancel_transfer(struct libusb_transfer *t) { (void)t; return LIBUSB_ERROR_NOT_FOUND; }
int libusb_handle_events_timeout_completed(libusb_context *c, struct timeval *tv, int *done)
{
	(void)c; (void)tv; (void)done;
	return LIBUSB_ERROR_NOT_SUPPORTED;
}

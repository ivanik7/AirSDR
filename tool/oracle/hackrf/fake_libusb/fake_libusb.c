/*
 * Fake libusb backend for the libhackrf host oracle.
 *
 * Records every USB operation hackrf.c performs into a text trace. The trace
 * format is shared with the Dart recording fake
 * (test/drivers/hackrf/recording_usb_handle.dart) so both traces can be diffed:
 *
 *   CTRL <bmRequestType> <bRequest> <wValue> <wIndex> len=<wLength> to=<timeout> ret=<r> data=<hex>
 *       OUT: data = first wLength bytes sent;  IN: data = bytes returned (ret > 0)
 *   SET_CONFIGURATION <n> | CLAIM_INTERFACE <n> | RELEASE_INTERFACE <n> | CLOSE
 *   SUBMIT ep=<ep> len=<len>        (libusb_submit_transfer)
 *   CANCEL ep=<ep>                  (libusb_cancel_transfer)
 *
 * libusb_get_configuration() is recorded as the standard GET_CONFIGURATION
 * request (0x80/0x08, 1 byte), which is what the Dart port issues (the
 * UsbDeviceHandle contract has no getConfiguration()).
 *
 * IN responses are scripted (fake_script_in) identically to the Dart fake.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "libusb.h"
#include "fake_libusb.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct libusb_context {
	int dummy;
};
struct libusb_device {
	int dummy;
};
struct libusb_device_handle {
	int dummy;
};

static struct libusb_context g_ctx;
static struct libusb_device g_dev;
static struct libusb_device_handle g_handle;

fake_config_t fake_config = {
	.bcd_device = 0x0112,
	.current_config = 0,
	.fail_req = -1,
	.short_req = -1,
	.product_id = 0x6089,
};

static FILE* g_trace;
static pthread_mutex_t g_trace_lock = PTHREAD_MUTEX_INITIALIZER;

void fake_trace_open(const char* path)
{
	g_trace = path ? fopen(path, "w") : stdout;
	if (g_trace == NULL) {
		perror(path);
		exit(2);
	}
}

void fake_trace_close(void)
{
	if (g_trace != NULL && g_trace != stdout)
		fclose(g_trace);
	g_trace = NULL;
}

void fake_trace(const char* fmt, ...)
{
	va_list ap;
	pthread_mutex_lock(&g_trace_lock);
	va_start(ap, fmt);
	vfprintf(g_trace, fmt, ap);
	va_end(ap);
	fputc('\n', g_trace);
	fflush(g_trace);
	pthread_mutex_unlock(&g_trace_lock);
}

static void trace_ctrl(
	uint8_t rt,
	uint8_t req,
	uint16_t val,
	uint16_t idx,
	uint16_t len,
	unsigned int to,
	int ret,
	const unsigned char* data,
	int ndata)
{
	char hex[2 * 512 + 1];
	int i;
	hex[0] = 0;
	for (i = 0; i < ndata && i < 512; i++)
		sprintf(&hex[2 * i], "%02x", data[i]);
	fake_trace(
		"CTRL %02x %02x %04x %04x len=%u to=%u ret=%d data=%s",
		rt,
		req,
		val,
		idx,
		len,
		to,
		ret,
		hex);
}

/*
 * Scripted IN responses. Must match RecordingUsbHandle.scriptIn() in Dart.
 * Returns number of bytes written to out, or a negative libusb error.
 */
static int fake_script_in(uint8_t rt, uint8_t req, uint16_t val, uint16_t idx, unsigned char* out)
{
	(void) val;
	if (rt == 0x80 && req == 0x08) { /* GET_CONFIGURATION */
		out[0] = (unsigned char) fake_config.current_config;
		return 1;
	}
	if (rt != 0xc0)
		return LIBUSB_ERROR_PIPE;
	switch (req) {
	case 14: /* BOARD_ID_READ: HackRF One (OG) */
		out[0] = 2;
		return 1;
	case 15: { /* VERSION_STRING_READ */
		const char* s = "fake-2026.01.0";
		memcpy(out, s, strlen(s));
		return (int) strlen(s);
	}
	case 18: { /* BOARD_PARTID_SERIALNO_READ: u32 part_id[2], u32 serial_no[4], LE */
		static const unsigned char r[24] = {
			0x3c, 0xcb, 0x00, 0xa0, 0x46, 0x4f, 0x57, 0x00, /* part_id */
			0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, /* serial 0,1 */
			0x78, 0x56, 0x34, 0x12, 0xf0, 0xde, 0xbc, 0x9a, /* serial 2,3 */
		};
		memcpy(out, r, sizeof(r));
		return (int) sizeof(r);
	}
	case 19: /* SET_LNA_GAIN: always accepted */
		out[0] = 1;
		return 1;
	case 20: /* SET_VGA_GAIN: firmware "rejects" 62 to exercise retval==0 */
		out[0] = (idx == 62) ? 0 : 1;
		return 1;
	case 45: /* BOARD_REV_READ */
		out[0] = 5;
		return 1;
	case 61: /* GET_BUFFER_SIZE: 32768 LE */
		out[0] = 0x00;
		out[1] = 0x80;
		out[2] = 0x00;
		out[3] = 0x00;
		return 4;
	default:
		return LIBUSB_ERROR_PIPE;
	}
}

int libusb_control_transfer(
	libusb_device_handle* dev_handle,
	uint8_t request_type,
	uint8_t bRequest,
	uint16_t wValue,
	uint16_t wIndex,
	unsigned char* data,
	uint16_t wLength,
	unsigned int timeout)
{
	unsigned char resp[512];
	int ret;
	(void) dev_handle;

	if (bRequest == fake_config.fail_req) {
		trace_ctrl(request_type, bRequest, wValue, wIndex, wLength, timeout, LIBUSB_ERROR_PIPE, NULL, 0);
		return LIBUSB_ERROR_PIPE;
	}

	if (request_type & LIBUSB_ENDPOINT_IN) {
		ret = fake_script_in(request_type, bRequest, wValue, wIndex, resp);
		if (ret > wLength)
			ret = wLength;
		if (ret > 0 && bRequest == fake_config.short_req)
			ret = ret / 2;
		if (ret > 0)
			memcpy(data, resp, ret);
		trace_ctrl(request_type, bRequest, wValue, wIndex, wLength, timeout, ret, data, ret > 0 ? ret : 0);
	} else {
		ret = wLength;
		if (bRequest == fake_config.short_req)
			ret = wLength / 2;
		trace_ctrl(request_type, bRequest, wValue, wIndex, wLength, timeout, ret, data, wLength);
	}
	return ret;
}

int libusb_get_configuration(libusb_device_handle* dev, int* config)
{
	unsigned char b;
	int r = libusb_control_transfer(dev, 0x80, 0x08, 0, 0, &b, 1, 1000);
	if (r < 0)
		return r;
	if (r != 1)
		return LIBUSB_ERROR_IO;
	*config = b;
	return LIBUSB_SUCCESS;
}

int libusb_set_configuration(libusb_device_handle* dev_handle, int configuration)
{
	(void) dev_handle;
	fake_trace("SET_CONFIGURATION %d", configuration);
	fake_config.current_config = configuration;
	return LIBUSB_SUCCESS;
}

int libusb_claim_interface(libusb_device_handle* dev_handle, int interface_number)
{
	(void) dev_handle;
	fake_trace("CLAIM_INTERFACE %d", interface_number);
	return LIBUSB_SUCCESS;
}

int libusb_release_interface(libusb_device_handle* dev_handle, int interface_number)
{
	(void) dev_handle;
	fake_trace("RELEASE_INTERFACE %d", interface_number);
	return LIBUSB_SUCCESS;
}

void libusb_close(libusb_device_handle* dev_handle)
{
	(void) dev_handle;
	fake_trace("CLOSE");
}

/* Android: no kernel driver is ever bound for the app; mimic
 * LIBUSB_ERROR_NOT_SUPPORTED so detach_kernel_drivers() is a no-op. */
int libusb_kernel_driver_active(libusb_device_handle* dev_handle, int interface_number)
{
	(void) dev_handle;
	(void) interface_number;
	return LIBUSB_ERROR_NOT_SUPPORTED;
}

int libusb_detach_kernel_driver(libusb_device_handle* dev_handle, int interface_number)
{
	(void) dev_handle;
	(void) interface_number;
	return LIBUSB_ERROR_NOT_SUPPORTED;
}

int libusb_init(libusb_context** ctx)
{
	*ctx = &g_ctx;
	return LIBUSB_SUCCESS;
}

void libusb_exit(libusb_context* ctx)
{
	(void) ctx;
}

const char* libusb_strerror(int errcode)
{
	/* English strings of libusb 1.0.2x strerror.c */
	switch (errcode) {
	case LIBUSB_SUCCESS:
		return "Success";
	case LIBUSB_ERROR_IO:
		return "Input/Output Error";
	case LIBUSB_ERROR_INVALID_PARAM:
		return "Invalid parameter";
	case LIBUSB_ERROR_ACCESS:
		return "Access denied (insufficient permissions)";
	case LIBUSB_ERROR_NO_DEVICE:
		return "No such device (it may have been disconnected)";
	case LIBUSB_ERROR_NOT_FOUND:
		return "Entity not found";
	case LIBUSB_ERROR_BUSY:
		return "Resource busy";
	case LIBUSB_ERROR_TIMEOUT:
		return "Operation timed out";
	case LIBUSB_ERROR_OVERFLOW:
		return "Overflow";
	case LIBUSB_ERROR_PIPE:
		return "Pipe error";
	case LIBUSB_ERROR_INTERRUPTED:
		return "System call interrupted (perhaps due to signal)";
	case LIBUSB_ERROR_NO_MEM:
		return "Insufficient memory";
	case LIBUSB_ERROR_NOT_SUPPORTED:
		return "Operation not supported or unimplemented on this platform";
	case LIBUSB_ERROR_OTHER:
		return "Other error";
	default:
		return "**UNKNOWN**";
	}
}

ssize_t libusb_get_device_list(libusb_context* ctx, libusb_device*** list)
{
	(void) ctx;
	libusb_device** l = calloc(2, sizeof(*l));
	l[0] = &g_dev;
	*list = l;
	return 1;
}

void libusb_free_device_list(libusb_device** list, int unref_devices)
{
	(void) unref_devices;
	free(list);
}

int libusb_get_device_descriptor(libusb_device* dev, struct libusb_device_descriptor* desc)
{
	(void) dev;
	memset(desc, 0, sizeof(*desc));
	desc->bLength = 18;
	desc->bDescriptorType = 1;
	desc->bcdUSB = 0x0200;
	desc->idVendor = 0x1d50;
	desc->idProduct = (uint16_t) fake_config.product_id;
	desc->bcdDevice = (uint16_t) fake_config.bcd_device;
	desc->iManufacturer = 1;
	desc->iProduct = 2;
	desc->iSerialNumber = 3;
	desc->bNumConfigurations = 1;
	return LIBUSB_SUCCESS;
}

static struct libusb_config_descriptor g_config = {
	.bLength = 9,
	.bDescriptorType = 2,
	.wTotalLength = 32,
	.bNumInterfaces = 1,
	.bConfigurationValue = 1,
};

int libusb_get_active_config_descriptor(libusb_device* dev, struct libusb_config_descriptor** config)
{
	(void) dev;
	*config = &g_config;
	return LIBUSB_SUCCESS;
}

void libusb_free_config_descriptor(struct libusb_config_descriptor* config)
{
	(void) config;
}

uint8_t libusb_get_bus_number(libusb_device* dev)
{
	(void) dev;
	return 1;
}

libusb_device* libusb_get_parent(libusb_device* dev)
{
	(void) dev;
	return NULL;
}

libusb_device* libusb_get_device(libusb_device_handle* dev_handle)
{
	(void) dev_handle;
	return &g_dev;
}

int libusb_open(libusb_device* dev, libusb_device_handle** dev_handle)
{
	(void) dev;
	*dev_handle = &g_handle;
	return LIBUSB_SUCCESS;
}

libusb_device_handle* libusb_open_device_with_vid_pid(
	libusb_context* ctx,
	uint16_t vendor_id,
	uint16_t product_id)
{
	(void) ctx;
	if (vendor_id == 0x1d50 && product_id == fake_config.product_id)
		return &g_handle;
	return NULL;
}

int libusb_get_string_descriptor_ascii(
	libusb_device_handle* dev_handle,
	uint8_t desc_index,
	unsigned char* data,
	int length)
{
	(void) dev_handle;
	(void) desc_index;
	const char* s = "0000000000000000000000001234567890abcdef";
	int n = (int) strlen(s);
	if (n > length - 1)
		n = length - 1;
	memcpy(data, s, n);
	data[n] = 0;
	return n;
}

int libusb_bulk_transfer(
	libusb_device_handle* dev_handle,
	unsigned char endpoint,
	unsigned char* data,
	int length,
	int* actual_length,
	unsigned int timeout)
{
	(void) dev_handle;
	(void) data;
	(void) timeout;
	fake_trace("BULK ep=%02x len=%d", endpoint, length);
	*actual_length = length;
	return LIBUSB_SUCCESS;
}

/* ---- async transfers: submitted transfers never complete on their own;
 * cancelled ones complete with LIBUSB_TRANSFER_CANCELLED on the event thread. */

static pthread_mutex_t g_q_lock = PTHREAD_MUTEX_INITIALIZER;
static struct libusb_transfer* g_completions[64];
static int g_ncompletions;

struct libusb_transfer* libusb_alloc_transfer(int iso_packets)
{
	(void) iso_packets;
	return calloc(1, sizeof(struct libusb_transfer));
}

void libusb_free_transfer(struct libusb_transfer* transfer)
{
	if (transfer == NULL)
		return;
	if (transfer->flags & LIBUSB_TRANSFER_FREE_BUFFER)
		free(transfer->buffer);
	free(transfer);
}

int libusb_submit_transfer(struct libusb_transfer* transfer)
{
	fake_trace("SUBMIT ep=%02x len=%d", transfer->endpoint, transfer->length);
	return LIBUSB_SUCCESS;
}

int libusb_cancel_transfer(struct libusb_transfer* transfer)
{
	fake_trace("CANCEL ep=%02x", transfer->endpoint);
	pthread_mutex_lock(&g_q_lock);
	transfer->status = LIBUSB_TRANSFER_CANCELLED;
	transfer->actual_length = 0;
	g_completions[g_ncompletions++] = transfer;
	pthread_mutex_unlock(&g_q_lock);
	return LIBUSB_SUCCESS;
}

int libusb_handle_events_timeout(libusb_context* ctx, struct timeval* tv)
{
	struct libusb_transfer* local[64];
	int n, i;
	(void) ctx;
	(void) tv;
	pthread_mutex_lock(&g_q_lock);
	n = g_ncompletions;
	memcpy(local, g_completions, n * sizeof(local[0]));
	g_ncompletions = 0;
	pthread_mutex_unlock(&g_q_lock);
	for (i = 0; i < n; i++)
		local[i]->callback(local[i]);
	if (n == 0)
		usleep(1000);
	return LIBUSB_SUCCESS;
}

void libusb_interrupt_event_handler(libusb_context* ctx)
{
	(void) ctx;
}

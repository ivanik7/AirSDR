/*
 * Minimal fake <libusb.h> for building libhackrf (host/libhackrf/src/hackrf.c)
 * on the host as a test oracle. Only the declarations used by hackrf.c are
 * provided. Every control transfer / configuration / claim / submit / cancel
 * call is recorded into a trace (see fake_libusb.c), IN transfers are answered
 * from a script shared with the Dart recording fake
 * (test/drivers/hackrf/recording_usb_handle.dart).
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#pragma once

#include <stdint.h>
#include <stddef.h>
#include <sys/time.h>
#include <sys/types.h>

#define LIBUSB_CALL
/* < 0x0100010C: hackrf.c skips the WinUSB RAW_IO block;
 * >= 0x01000103: hackrf_error_name() uses libusb_strerror(). */
#define LIBUSB_API_VERSION 0x01000109

typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;
typedef struct libusb_device_handle libusb_device_handle;

enum libusb_error {
	LIBUSB_SUCCESS = 0,
	LIBUSB_ERROR_IO = -1,
	LIBUSB_ERROR_INVALID_PARAM = -2,
	LIBUSB_ERROR_ACCESS = -3,
	LIBUSB_ERROR_NO_DEVICE = -4,
	LIBUSB_ERROR_NOT_FOUND = -5,
	LIBUSB_ERROR_BUSY = -6,
	LIBUSB_ERROR_TIMEOUT = -7,
	LIBUSB_ERROR_OVERFLOW = -8,
	LIBUSB_ERROR_PIPE = -9,
	LIBUSB_ERROR_INTERRUPTED = -10,
	LIBUSB_ERROR_NO_MEM = -11,
	LIBUSB_ERROR_NOT_SUPPORTED = -12,
	LIBUSB_ERROR_OTHER = -99,
};

enum libusb_endpoint_direction {
	LIBUSB_ENDPOINT_OUT = 0x00,
	LIBUSB_ENDPOINT_IN = 0x80,
};

enum libusb_request_type {
	LIBUSB_REQUEST_TYPE_STANDARD = (0x00 << 5),
	LIBUSB_REQUEST_TYPE_CLASS = (0x01 << 5),
	LIBUSB_REQUEST_TYPE_VENDOR = (0x02 << 5),
};

enum libusb_request_recipient {
	LIBUSB_RECIPIENT_DEVICE = 0x00,
	LIBUSB_RECIPIENT_INTERFACE = 0x01,
};

enum libusb_transfer_type {
	LIBUSB_TRANSFER_TYPE_BULK = 2,
};

enum libusb_transfer_status {
	LIBUSB_TRANSFER_COMPLETED = 0,
	LIBUSB_TRANSFER_ERROR = 1,
	LIBUSB_TRANSFER_TIMED_OUT = 2,
	LIBUSB_TRANSFER_CANCELLED = 3,
	LIBUSB_TRANSFER_STALL = 4,
	LIBUSB_TRANSFER_NO_DEVICE = 5,
	LIBUSB_TRANSFER_OVERFLOW = 6,
};

enum libusb_transfer_flags {
	LIBUSB_TRANSFER_SHORT_NOT_OK = 1 << 0,
	LIBUSB_TRANSFER_FREE_BUFFER = 1 << 1,
	LIBUSB_TRANSFER_FREE_TRANSFER = 1 << 2,
};

struct libusb_device_descriptor {
	uint8_t bLength;
	uint8_t bDescriptorType;
	uint16_t bcdUSB;
	uint8_t bDeviceClass;
	uint8_t bDeviceSubClass;
	uint8_t bDeviceProtocol;
	uint8_t bMaxPacketSize0;
	uint16_t idVendor;
	uint16_t idProduct;
	uint16_t bcdDevice;
	uint8_t iManufacturer;
	uint8_t iProduct;
	uint8_t iSerialNumber;
	uint8_t bNumConfigurations;
};

struct libusb_config_descriptor {
	uint8_t bLength;
	uint8_t bDescriptorType;
	uint16_t wTotalLength;
	uint8_t bNumInterfaces;
	uint8_t bConfigurationValue;
};

struct libusb_transfer;
typedef void(LIBUSB_CALL* libusb_transfer_cb_fn)(struct libusb_transfer* transfer);

struct libusb_transfer {
	libusb_device_handle* dev_handle;
	uint8_t flags;
	unsigned char endpoint;
	unsigned char type;
	unsigned int timeout;
	enum libusb_transfer_status status;
	int length;
	int actual_length;
	libusb_transfer_cb_fn callback;
	void* user_data;
	unsigned char* buffer;
	int num_iso_packets;
};

static inline void libusb_fill_bulk_transfer(
	struct libusb_transfer* transfer,
	libusb_device_handle* dev_handle,
	unsigned char endpoint,
	unsigned char* buffer,
	int length,
	libusb_transfer_cb_fn callback,
	void* user_data,
	unsigned int timeout)
{
	transfer->dev_handle = dev_handle;
	transfer->endpoint = endpoint;
	transfer->type = LIBUSB_TRANSFER_TYPE_BULK;
	transfer->timeout = timeout;
	transfer->buffer = buffer;
	transfer->length = length;
	transfer->user_data = user_data;
	transfer->callback = callback;
}

int libusb_init(libusb_context** ctx);
void libusb_exit(libusb_context* ctx);
const char* libusb_strerror(int errcode);

ssize_t libusb_get_device_list(libusb_context* ctx, libusb_device*** list);
void libusb_free_device_list(libusb_device** list, int unref_devices);
int libusb_get_device_descriptor(libusb_device* dev, struct libusb_device_descriptor* desc);
int libusb_get_active_config_descriptor(libusb_device* dev, struct libusb_config_descriptor** config);
void libusb_free_config_descriptor(struct libusb_config_descriptor* config);
uint8_t libusb_get_bus_number(libusb_device* dev);
libusb_device* libusb_get_parent(libusb_device* dev);
libusb_device* libusb_get_device(libusb_device_handle* dev_handle);

int libusb_open(libusb_device* dev, libusb_device_handle** dev_handle);
libusb_device_handle* libusb_open_device_with_vid_pid(
	libusb_context* ctx,
	uint16_t vendor_id,
	uint16_t product_id);
void libusb_close(libusb_device_handle* dev_handle);

int libusb_get_configuration(libusb_device_handle* dev, int* config);
int libusb_set_configuration(libusb_device_handle* dev_handle, int configuration);
int libusb_claim_interface(libusb_device_handle* dev_handle, int interface_number);
int libusb_release_interface(libusb_device_handle* dev_handle, int interface_number);
int libusb_kernel_driver_active(libusb_device_handle* dev_handle, int interface_number);
int libusb_detach_kernel_driver(libusb_device_handle* dev_handle, int interface_number);

int libusb_get_string_descriptor_ascii(
	libusb_device_handle* dev_handle,
	uint8_t desc_index,
	unsigned char* data,
	int length);

int libusb_control_transfer(
	libusb_device_handle* dev_handle,
	uint8_t request_type,
	uint8_t bRequest,
	uint16_t wValue,
	uint16_t wIndex,
	unsigned char* data,
	uint16_t wLength,
	unsigned int timeout);

int libusb_bulk_transfer(
	libusb_device_handle* dev_handle,
	unsigned char endpoint,
	unsigned char* data,
	int length,
	int* actual_length,
	unsigned int timeout);

struct libusb_transfer* libusb_alloc_transfer(int iso_packets);
void libusb_free_transfer(struct libusb_transfer* transfer);
int libusb_submit_transfer(struct libusb_transfer* transfer);
int libusb_cancel_transfer(struct libusb_transfer* transfer);

int libusb_handle_events_timeout(libusb_context* ctx, struct timeval* tv);
void libusb_interrupt_event_handler(libusb_context* ctx);

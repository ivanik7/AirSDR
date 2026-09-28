/* Host oracle for lib/usb/usbfs_abi.dart: prints ioctl numbers and struct
 * layouts from <linux/usbdevice_fs.h> as key=value lines.
 * Used by test/usb/usbfs_abi_test.dart (compiled with gcc when available).
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>
#include <stddef.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>

#define P(name, v) printf("%s=%lu\n", name, (unsigned long)(v))

int main(void)
{
	P("CONTROL", USBDEVFS_CONTROL);
	P("BULK", USBDEVFS_BULK);
	P("SETCONFIGURATION", USBDEVFS_SETCONFIGURATION);
	P("SUBMITURB", USBDEVFS_SUBMITURB);
	P("DISCARDURB", USBDEVFS_DISCARDURB);
	P("REAPURB", USBDEVFS_REAPURB);
	P("REAPURBNDELAY", USBDEVFS_REAPURBNDELAY);
	P("CLAIMINTERFACE", USBDEVFS_CLAIMINTERFACE);
	P("RELEASEINTERFACE", USBDEVFS_RELEASEINTERFACE);
	P("RESET", USBDEVFS_RESET);
	P("CLEAR_HALT", USBDEVFS_CLEAR_HALT);
	P("GET_CAPABILITIES", USBDEVFS_GET_CAPABILITIES);

	P("ctrl.size", sizeof(struct usbdevfs_ctrltransfer));
	P("ctrl.bRequestType", offsetof(struct usbdevfs_ctrltransfer, bRequestType));
	P("ctrl.bRequest", offsetof(struct usbdevfs_ctrltransfer, bRequest));
	P("ctrl.wValue", offsetof(struct usbdevfs_ctrltransfer, wValue));
	P("ctrl.wIndex", offsetof(struct usbdevfs_ctrltransfer, wIndex));
	P("ctrl.wLength", offsetof(struct usbdevfs_ctrltransfer, wLength));
	P("ctrl.timeout", offsetof(struct usbdevfs_ctrltransfer, timeout));
	P("ctrl.data", offsetof(struct usbdevfs_ctrltransfer, data));

	P("bulk.size", sizeof(struct usbdevfs_bulktransfer));
	P("bulk.ep", offsetof(struct usbdevfs_bulktransfer, ep));
	P("bulk.len", offsetof(struct usbdevfs_bulktransfer, len));
	P("bulk.timeout", offsetof(struct usbdevfs_bulktransfer, timeout));
	P("bulk.data", offsetof(struct usbdevfs_bulktransfer, data));

	P("urb.size", sizeof(struct usbdevfs_urb));
	P("urb.type", offsetof(struct usbdevfs_urb, type));
	P("urb.endpoint", offsetof(struct usbdevfs_urb, endpoint));
	P("urb.status", offsetof(struct usbdevfs_urb, status));
	P("urb.flags", offsetof(struct usbdevfs_urb, flags));
	P("urb.buffer", offsetof(struct usbdevfs_urb, buffer));
	P("urb.buffer_length", offsetof(struct usbdevfs_urb, buffer_length));
	P("urb.actual_length", offsetof(struct usbdevfs_urb, actual_length));
	P("urb.start_frame", offsetof(struct usbdevfs_urb, start_frame));
	P("urb.number_of_packets", offsetof(struct usbdevfs_urb, number_of_packets));
	P("urb.error_count", offsetof(struct usbdevfs_urb, error_count));
	P("urb.signr", offsetof(struct usbdevfs_urb, signr));
	P("urb.usercontext", offsetof(struct usbdevfs_urb, usercontext));
	return 0;
}

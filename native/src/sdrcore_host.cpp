// SPDX-License-Identifier: GPL-3.0-or-later
//
// Desktop Linux platform layer: USB enumeration and open-by-path for the
// shared ABI 2 engine (see native/include/sdrcore_host.h). Built only for
// non-Android targets; the driver/stream path stays in sdrcore.cpp.
#include "sdrcore_host.h"

#include "libusb.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <unistd.h>

namespace {

void copy_string(char* dst, size_t cap, const std::string& src) {
  if (cap == 0) return;
  const size_t n = src.size() < cap - 1 ? src.size() : cap - 1;
  std::memcpy(dst, src.data(), n);
  dst[n] = '\0';
}

// Reads one sysfs attribute, trimming the trailing newline. Empty on error.
std::string read_sysfs(const std::string& dir, const char* name) {
  const std::string path = dir + "/" + name;
  FILE* f = std::fopen(path.c_str(), "re");
  if (!f) return {};
  char buf[256];
  const size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
  std::fclose(f);
  buf[n] = '\0';
  std::string s(buf);
  while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
  return s;
}

// /sys/bus/usb/devices/<bus>-<port>[.<port>...] for a non-root device.
std::string sysfs_dir(libusb_device* dev) {
  uint8_t ports[8];
  const int n = libusb_get_port_numbers(dev, ports, sizeof(ports));
  if (n <= 0) return {};
  std::string dir = "/sys/bus/usb/devices/" +
                    std::to_string(libusb_get_bus_number(dev)) + "-";
  for (int i = 0; i < n; ++i) {
    if (i) dir += ".";
    dir += std::to_string(ports[i]);
  }
  return dir;
}

}  // namespace

extern "C" int32_t sdr_host_usb_list(SdrHostUsbDevice* out, uint32_t capacity,
                                     uint32_t* count) {
  if (!count || (capacity > 0 && !out)) return SDR_INVALID_ARGUMENT;
  for (uint32_t i = 0; i < capacity; ++i) {
    if (out[i].size != sizeof(SdrHostUsbDevice)) return SDR_INVALID_ARGUMENT;
  }
  libusb_context* ctx = nullptr;
  if (libusb_init(&ctx) != 0) return SDR_IO_ERROR;
  libusb_device** list = nullptr;
  const ssize_t n = libusb_get_device_list(ctx, &list);
  if (n < 0) {
    libusb_exit(ctx);
    return SDR_IO_ERROR;
  }
  uint32_t total = 0;
  for (ssize_t i = 0; i < n; ++i) {
    libusb_device* dev = list[i];
    libusb_device_descriptor desc{};
    if (libusb_get_device_descriptor(dev, &desc) != 0) continue;
    if (desc.bDeviceClass == LIBUSB_CLASS_HUB) continue;
    if (total < capacity) {
      SdrHostUsbDevice& d = out[total];
      std::memset(&d, 0, sizeof(d));
      d.size = sizeof(SdrHostUsbDevice);
      d.vendor_id = desc.idVendor;
      d.product_id = desc.idProduct;
      d.bus = libusb_get_bus_number(dev);
      d.address = libusb_get_device_address(dev);
      char path[32];
      std::snprintf(path, sizeof(path), "/dev/bus/usb/%03u/%03u",
                    static_cast<unsigned>(d.bus),
                    static_cast<unsigned>(d.address));
      copy_string(d.path, sizeof(d.path), path);
      const std::string dir = sysfs_dir(dev);
      if (!dir.empty()) {
        copy_string(d.manufacturer, sizeof(d.manufacturer),
                    read_sysfs(dir, "manufacturer"));
        copy_string(d.product, sizeof(d.product), read_sysfs(dir, "product"));
        copy_string(d.serial, sizeof(d.serial), read_sysfs(dir, "serial"));
      }
    }
    ++total;
  }
  libusb_free_device_list(list, 1);
  libusb_exit(ctx);
  *count = total;
  return SDR_OK;
}

extern "C" int32_t sdr_host_open_usb(SdrHandle* handle, uint8_t bus,
                                     uint8_t address, uint32_t source) {
  if (!handle || bus == 0 || address == 0 ||
      (source != SDR_RTLSDR && source != SDR_HACKRF))
    return SDR_INVALID_ARGUMENT;
  char path[32];
  std::snprintf(path, sizeof(path), "/dev/bus/usb/%03u/%03u",
                static_cast<unsigned>(bus), static_cast<unsigned>(address));
  const int fd = ::open(path, O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    if (errno == ENOENT || errno == ENODEV || errno == ENXIO)
      return SDR_HOST_NOT_FOUND;
    if (errno == EACCES || errno == EPERM) return SDR_HOST_ACCESS_DENIED;
    return SDR_IO_ERROR;
  }
  // The adapter dup()s fd and owns the duplicate for the whole session; the
  // duplicate shares this open file description, so closing ours is safe.
  const int32_t rc = sdr_v2_open_usb(handle, fd, source);
  ::close(fd);
  return rc;
}

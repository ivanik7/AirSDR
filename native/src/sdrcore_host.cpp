// SPDX-License-Identifier: GPL-3.0-or-later
//
// Desktop host platform layer (Linux, macOS, Windows): USB enumeration and
// opening for the shared ABI 2 engine (see native/include/sdrcore_host.h).
// Built only for non-Android targets; the driver/stream path stays in
// sdrcore.cpp.
//
// Linux keeps the usbfs fd path (open /dev/bus/usb/BBB/DDD, hand the fd to
// sdr_v2_open_usb) and sysfs strings. Other hosts have neither: they open by
// bus/address through the vendored driver's own libusb context, and read
// enumeration strings from cached USB string descriptors.
#include "sdrcore_host.h"

#include "libusb.h"
#include "sdrcore_internal.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>

#if defined(__linux__)
#include <fcntl.h>
#include <unistd.h>
#else
#include <map>
#include <mutex>
#include <tuple>
#endif

namespace {

void copy_string(char* dst, size_t cap, const std::string& src) {
  if (cap == 0) return;
  const size_t n = src.size() < cap - 1 ? src.size() : cap - 1;
  std::memcpy(dst, src.data(), n);
  dst[n] = '\0';
}

struct UsbStrings {
  std::string manufacturer;
  std::string product;
  std::string serial;
};

#if defined(__linux__)

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

// Never touches the device: sysfs only.
UsbStrings device_strings(libusb_device* dev,
                          const libusb_device_descriptor&) {
  UsbStrings s;
  const std::string dir = sysfs_dir(dev);
  if (dir.empty()) return s;
  s.manufacturer = read_sysfs(dir, "manufacturer");
  s.product = read_sysfs(dir, "product");
  s.serial = read_sysfs(dir, "serial");
  return s;
}

void format_path(char* out, size_t cap, uint8_t bus, uint8_t address) {
  std::snprintf(out, cap, "/dev/bus/usb/%03u/%03u", static_cast<unsigned>(bus),
                static_cast<unsigned>(address));
}

#else  // macOS, Windows

// Only supported SDRs are ever opened for their strings, so listing never
// touches unrelated USB devices (keyboards, storage, audio interfaces).
bool is_supported_sdr(uint16_t vid, uint16_t pid) {
  if (vid == 0x0bda) return pid == 0x2832 || pid == 0x2838;  // RTL2832U
  if (vid == 0x1d50)
    return pid == 0x6089 || pid == 0x604b || pid == 0xcc15;  // HackRF family
  return false;
}

std::string string_descriptor(libusb_device_handle* h, uint8_t index) {
  if (index == 0) return {};
  unsigned char buf[128];
  const int n = libusb_get_string_descriptor_ascii(h, index, buf, sizeof(buf));
  if (n <= 0) return {};
  return std::string(reinterpret_cast<const char*>(buf),
                     static_cast<size_t>(n));
}

using StringKey = std::tuple<uint8_t, uint8_t, uint16_t, uint16_t>;
std::mutex g_string_cache_mutex;
std::map<StringKey, UsbStrings> g_string_cache;

// Reads string descriptors once per (bus, address, VID, PID) and caches them.
// A device that may be streaming is never opened: while this process holds a
// native USB session only cached strings are returned. libusb_open() of a
// device held by another process or without WinUSB simply fails, which
// leaves the strings empty (Dart falls back to the VID:PID catalog name).
UsbStrings device_strings(libusb_device* dev,
                          const libusb_device_descriptor& desc) {
  if (!is_supported_sdr(desc.idVendor, desc.idProduct)) return {};
  const StringKey key{libusb_get_bus_number(dev), libusb_get_device_address(dev),
                      desc.idVendor, desc.idProduct};
  std::lock_guard<std::mutex> lock(g_string_cache_mutex);
  const auto cached = g_string_cache.find(key);
  if (cached != g_string_cache.end()) return cached->second;
  if (sdrcore_native_usb_claim_active()) return {};
  libusb_device_handle* h = nullptr;
  if (libusb_open(dev, &h) != 0 || !h) return {};
  UsbStrings s;
  s.manufacturer = string_descriptor(h, desc.iManufacturer);
  s.product = string_descriptor(h, desc.iProduct);
  s.serial = string_descriptor(h, desc.iSerialNumber);
  libusb_close(h);
  g_string_cache[key] = s;
  return s;
}

void format_path(char* out, size_t cap, uint8_t bus, uint8_t address) {
  std::snprintf(out, cap, "usb:%03u/%03u", static_cast<unsigned>(bus),
                static_cast<unsigned>(address));
}

#endif

bool valid_open_args(SdrHandle* handle, uint8_t bus, uint8_t address,
                     uint32_t source) {
  return handle && bus != 0 && address != 0 &&
         (source == SDR_RTLSDR || source == SDR_HACKRF);
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
      format_path(d.path, sizeof(d.path), d.bus, d.address);
      const UsbStrings s = device_strings(dev, desc);
      copy_string(d.manufacturer, sizeof(d.manufacturer), s.manufacturer);
      copy_string(d.product, sizeof(d.product), s.product);
      copy_string(d.serial, sizeof(d.serial), s.serial);
    }
    ++total;
  }
  libusb_free_device_list(list, 1);
  libusb_exit(ctx);
  *count = total;
  return SDR_OK;
}

extern "C" int32_t sdr_host_open_usb_direct(SdrHandle* handle, uint8_t bus,
                                            uint8_t address, uint32_t source) {
  if (!valid_open_args(handle, bus, address, source))
    return SDR_INVALID_ARGUMENT;
  return sdrcore_open_usb_bus_address(handle, bus, address, source);
}

extern "C" int32_t sdr_host_open_usb(SdrHandle* handle, uint8_t bus,
                                     uint8_t address, uint32_t source) {
  if (!valid_open_args(handle, bus, address, source))
    return SDR_INVALID_ARGUMENT;
#if defined(__linux__)
  char path[32];
  format_path(path, sizeof(path), bus, address);
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
#else
  return sdrcore_open_usb_bus_address(handle, bus, address, source);
#endif
}

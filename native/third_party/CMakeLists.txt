cmake_minimum_required(VERSION 3.22)

# Pinned, source-built third-party SDR USB drivers for the N1 native engine.
#
# Everything under third_party/<name>/ is upstream source copied verbatim at
# the pinned revision below plus (for rtl-sdr and hackrf) a minimal cherry-
# picked patch that adds open-by-fd support. No prebuilt binaries are used.
#
#   libusb  v1.0.30 (github.com/libusb/libusb)            LGPL-2.1-or-later
#   rtl-sdr 797f814 (github.com/osmocom/rtl-sdr)           GPL-2.0-or-later
#     + open-by-fd cherry-picked from AlexandreRouma/rtl-sdr@40a1598
#       (+ follow-up fixes 7f68c34, ddd6811), reapplied by hand onto 797f814
#   hackrf  7f96cc8 (github.com/greatscottgadgets/hackrf)  BSD-3-Clause
#     + open-by-fd cherry-picked from AlexandreRouma/hackrf@703160f5..b1275e9c,
#       reapplied by hand onto 7f96cc8 (host/libhackrf only)
#
# See NOTICE.md in this directory for the full provenance, revision-pin
# verification commands, and exact upstream commit list.
#
# All three libraries are compiled with -fvisibility=hidden: they are link-time
# implementation details of libsdrcore.so, not part of the ABI 2 C surface in
# native/include/sdrcore.h. Only sdr_* symbols are exported from the final .so
# (see CXX_VISIBILITY_PRESET hidden on the sdrcore target in ../CMakeLists.txt).

find_package(Threads REQUIRED)

add_library(sdrcore_libusb STATIC
    libusb/libusb/core.c
    libusb/libusb/descriptor.c
    libusb/libusb/hotplug.c
    libusb/libusb/io.c
    libusb/libusb/sync.c
    libusb/libusb/strerror.c
    libusb/libusb/os/linux_usbfs.c
    libusb/libusb/os/linux_netlink.c
    libusb/libusb/os/events_posix.c
    libusb/libusb/os/threads_posix.c
)
target_include_directories(sdrcore_libusb
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/libusb/libusb
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/libusb
)
target_compile_definitions(sdrcore_libusb PRIVATE HAVE_CONFIG_H)
target_compile_options(sdrcore_libusb PRIVATE -fvisibility=hidden)
target_link_libraries(sdrcore_libusb PUBLIC Threads::Threads)
if(ANDROID)
    target_link_libraries(sdrcore_libusb PUBLIC log)
endif()
set_target_properties(sdrcore_libusb PROPERTIES
    C_STANDARD 11
    C_EXTENSIONS ON
    POSITION_INDEPENDENT_CODE ON
)

add_library(sdrcore_rtlsdr STATIC
    rtl-sdr/src/librtlsdr.c
    rtl-sdr/src/tuner_e4k.c
    rtl-sdr/src/tuner_fc0012.c
    rtl-sdr/src/tuner_fc0013.c
    rtl-sdr/src/tuner_fc2580.c
    rtl-sdr/src/tuner_r82xx.c
)
target_include_directories(sdrcore_rtlsdr PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/rtl-sdr/include)
target_link_libraries(sdrcore_rtlsdr PUBLIC sdrcore_libusb)
target_compile_options(sdrcore_rtlsdr PRIVATE -fvisibility=hidden)
# rtlsdr_STATIC makes RTLSDR_API expand to nothing instead of an explicit
# __attribute__((visibility("default"))) (see rtl-sdr/include/rtl-sdr_export.h),
# so -fvisibility=hidden above actually hides these symbols in libsdrcore.so.
target_compile_definitions(sdrcore_rtlsdr PRIVATE rtlsdr_STATIC)
if(ANDROID)
    # Matches upstream rtlsdr_create_device(): skip libusb device discovery,
    # required on unrooted Android where only libusb_wrap_sys_device() works.
    target_compile_definitions(sdrcore_rtlsdr PRIVATE __ANDROID__)
endif()
set_target_properties(sdrcore_rtlsdr PROPERTIES
    C_STANDARD 11
    C_EXTENSIONS ON
    POSITION_INDEPENDENT_CODE ON
)

add_library(sdrcore_hackrf STATIC hackrf/libhackrf/hackrf.c)
target_include_directories(sdrcore_hackrf PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/hackrf/libhackrf)
target_link_libraries(sdrcore_hackrf PUBLIC sdrcore_libusb)
target_compile_options(sdrcore_hackrf PRIVATE -fvisibility=hidden)
target_compile_definitions(sdrcore_hackrf PRIVATE LIBRARY_RELEASE="n1-native-drivers")
if(ANDROID)
    # See hackrf_init()/hackrf_open_by_fd() in hackrf.c: without this, libusb
    # device enumeration aborts on unrooted Android before wrap_sys_device runs.
    target_compile_definitions(sdrcore_hackrf PRIVATE DISABLE_USB_DEVICE_DISCOVERY)
endif()
set_target_properties(sdrcore_hackrf PROPERTIES
    C_STANDARD 11
    C_EXTENSIONS ON
    POSITION_INDEPENDENT_CODE ON
)

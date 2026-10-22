/* Portable libmp3lame 3.100 configuration: encoder only, no host probes. */
#ifndef SDRCORE_LAME_CONFIG_H
#define SDRCORE_LAME_CONFIG_H
#include <stdint.h>
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;
typedef long double ieee854_float80_t;
#define HAVE_INT8_T 1
#define HAVE_INT16_T 1
#define HAVE_INT32_T 1
#define HAVE_INT64_T 1
#define HAVE_UINT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_UINT64_T 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_LIMITS_H 1
#define HAVE_SYS_TYPES_H 1
#define STDC_HEADERS 1
#define LAME_LIBRARY_BUILD 1
#define PACKAGE_VERSION "3.100"
#define VERSION "3.100"
#if !defined(_WIN32)
#define HAVE_UNISTD_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_GETTIMEOFDAY 1
#endif
#endif

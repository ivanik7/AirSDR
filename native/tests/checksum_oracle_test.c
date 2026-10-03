// SPDX-License-Identifier: GPL-3.0-or-later
//
// Independent oracle for the diagnostic checksum documented in
// native/include/sdrcore.h: "FNV-1a digest of consumed CU8 blocks". This
// file reimplements FNV-1a-64 from the public FNV specification (not by
// reading native/src/sdrcore.cpp) and compares it against the checksum
// sdr_v2_stats() reports after running the file source over a known CU8
// buffer. This is a reference-comparison test in the same spirit as
// tool/oracle/* (independent C computation vs. the library under test),
// scoped to the one quantity ABI 2 actually documents as a contract: the
// digest's definition and the input==processed+dropped accounting
// invariant for a complete run with no backpressure.
//
// NOT wired into native/CMakeLists.txt; build and run via
// native/tests/run_host_tests.sh.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "sdrcore.h"

#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// FNV-1a 64-bit, per http://www.isthe.com/chongo/tech/comp/fnv/ : offset
// basis 14695981039346656037, prime 1099511628211. Written independently of
// native/src/sdrcore.cpp's implementation.
static uint64_t Fnv1a64(const uint8_t* data, size_t len) {
  uint64_t h = 14695981039346656037ULL;
  for (size_t i = 0; i < len; ++i) {
    h ^= data[i];
    h *= 1099511628211ULL;
  }
  return h;
}

// Deterministic pseudo-random CU8 content (LCG), independent of any
// native-side generator.
static void FillDeterministic(uint8_t* data, size_t n, uint32_t seed) {
  uint32_t x = seed;
  for (size_t i = 0; i < n; ++i) {
    x = x * 1103515245u + 12345u;
    data[i] = (uint8_t)(x >> 16);
  }
}

static void RunChecksumCase(size_t byte_count, uint32_t seed,
                             const char* label) {
  char path[] = "/tmp/sdrcore_oracle_XXXXXX";
  int fd = mkstemp(path);
  assert(fd >= 0);
  uint8_t* data = (uint8_t*)malloc(byte_count);
  FillDeterministic(data, byte_count, seed);
  ssize_t written = write(fd, data, byte_count);
  assert(written == (ssize_t)byte_count);
  close(fd);

  int read_fd = open(path, O_RDONLY);
  assert(read_fd >= 0);
  SdrHandle* h = sdr_create();
  assert(sdr_v2_open_file(h, read_fd, 2000000) == SDR_OK);
  assert(sdr_v2_start(h) == SDR_OK);
  // Poll until the whole file has been consumed (small, bounded wait).
  SdrStats s;
  for (int i = 0; i < 200; ++i) {
    s.size = sizeof(s);
    s.revision = 2;
    assert(sdr_v2_stats(h, &s) == SDR_OK);
    if (s.input_samples >= byte_count / 2) break;
    usleep(5000);
  }
  assert(sdr_v2_stop(h) == SDR_OK);
  s.size = sizeof(s);
  s.revision = 2;
  assert(sdr_v2_stats(h, &s) == SDR_OK);
  sdr_destroy(h);
  close(read_fd);
  unlink(path);

  size_t even_len = byte_count & ~(size_t)1;  // Trailing odd byte ignored.
  uint64_t expected = Fnv1a64(data, even_len);
  free(data);

  printf("case=%s input=%llu processed=%llu dropped=%llu checksum=0x%016llx "
         "expected=0x%016llx\n",
         label, (unsigned long long)s.input_samples,
         (unsigned long long)s.processed_samples,
         (unsigned long long)s.dropped_samples,
         (unsigned long long)s.checksum, (unsigned long long)expected);

  assert(s.dropped_samples == 0);  // No backpressure expected at this size.
  assert(s.processed_samples == even_len / 2);
  assert(s.checksum == expected);
}

int main(void) {
  RunChecksumCase(4097, 1u, "odd_length_small");     // Trailing byte ignored.
  RunChecksumCase(1 << 16, 42u, "64kib_block");        // Exactly 8 ring slots.
  RunChecksumCase(1, 7u, "single_byte_no_pair");       // No complete pair at all.
  printf("All checksum oracle comparisons matched.\n");
  return 0;
}

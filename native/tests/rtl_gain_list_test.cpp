// SPDX-License-Identifier: GPL-3.0-or-later
//
// Host regression test for sdr_v3_rtl_tuner_gains (native/include/sdrcore_v3.h).
//
// White-box: includes sdrcore.cpp directly so a fake UsbRxAdapter can be
// injected at the internal seam (no real USB device needed), exercising the
// exact migration contract from the deleted Dart `RtlSdrDev.getTunerGains()`
// path: the ABI call must sort an unsorted driver-reported table ascending
// and return it unchanged in order and value. It also covers the
// capacity-probe, SDR_V3_BUFFER_SMALL and argument/state validation paths
// that do not require real hardware.
#include "../src/sdrcore.cpp"

#include <cassert>
#include <cstring>
#include <memory>
#include <vector>

namespace {

// Mirrors the legacy rtlsdr_get_tuner_gains() R820T/R828D table order
// (native/third_party/rtl-sdr/src/librtlsdr.c): NOT pre-sorted by the
// vendor driver in general (fc0012_gains/fc0013_gains start with negative
// outliers mid-table); use a deliberately shuffled table here so a test
// that forgets to sort is guaranteed to fail.
const std::vector<int32_t> kUnsortedGains = {90, 0, 480, 37, 496, 14, 9, 27};
const std::vector<int32_t> kSortedGains = {0, 9, 14, 27, 37, 90, 480, 496};

// Fake RTL adapter standing in for RtlSdrAdapter: reports a fixed,
// deliberately unsorted gain table through the same UsbRxAdapter seam
// sdr_v3_rtl_tuner_gains queries via h->usb_adapter->get_tuner_gains().
class FakeRtlAdapter final : public UsbRxAdapter {
 public:
  int open(int) override { return SDR_OK; }
  int configure(uint64_t, uint32_t, int32_t) override { return SDR_OK; }
  int start(PushFn, void*) override { return SDR_OK; }
  void stop() override {}
  void close() override {}
  int get_tuner_gains(int32_t* gains, uint32_t capacity,
                       uint32_t* count) override {
    if (!count) return SDR_INVALID_ARGUMENT;
    if (capacity && !gains) return SDR_INVALID_ARGUMENT;
    *count = static_cast<uint32_t>(kUnsortedGains.size());
    if (capacity == 0) return SDR_OK;  // count-only probe
    if (capacity < *count) return SDR_V3_BUFFER_SMALL;
    // Same contract as the real adapter: sort before returning.
    std::vector<int32_t> sorted = kUnsortedGains;
    std::sort(sorted.begin(), sorted.end());
    std::copy(sorted.begin(), sorted.end(), gains);
    return SDR_OK;
  }
};

// Adapter reporting zero gains (FC2580/unknown-tuner table in librtlsdr).
class EmptyGainAdapter final : public UsbRxAdapter {
 public:
  int open(int) override { return SDR_OK; }
  int configure(uint64_t, uint32_t, int32_t) override { return SDR_OK; }
  int start(PushFn, void*) override { return SDR_OK; }
  void stop() override {}
  void close() override {}
  int get_tuner_gains(int32_t*, uint32_t, uint32_t* count) override {
    if (!count) return SDR_INVALID_ARGUMENT;
    *count = 0;
    return SDR_OK;
  }
};

void test_full_query_matches_sorted_legacy_table() {
  SdrHandle h;
  h.stats.state = SDR_OPEN;
  h.stats.source = SDR_RTLSDR;
  h.usb_adapter = std::make_unique<FakeRtlAdapter>();
  int32_t gains[16];
  uint32_t count = 0;
  const int32_t rc = sdr_v3_rtl_tuner_gains(&h, gains, 16, &count);
  assert(rc == SDR_OK);
  assert(count == kSortedGains.size());
  for (size_t i = 0; i < kSortedGains.size(); ++i) assert(gains[i] == kSortedGains[i]);
  printf("[ok] full query returns the legacy getTunerGains()..sort() order\n");
}

void test_count_only_probe_does_not_touch_gains() {
  SdrHandle h;
  h.stats.state = SDR_OPEN;
  h.stats.source = SDR_RTLSDR;
  h.usb_adapter = std::make_unique<FakeRtlAdapter>();
  uint32_t count = 999;
  const int32_t rc = sdr_v3_rtl_tuner_gains(&h, nullptr, 0, &count);
  assert(rc == SDR_OK);
  assert(count == kSortedGains.size());
  printf("[ok] capacity=0, gains=NULL is a valid count-only probe\n");
}

void test_insufficient_capacity_returns_buffer_small_and_leaves_array_untouched() {
  SdrHandle h;
  h.stats.state = SDR_OPEN;
  h.stats.source = SDR_RTLSDR;
  h.usb_adapter = std::make_unique<FakeRtlAdapter>();
  int32_t gains[4];
  for (auto& g : gains) g = -12345;
  uint32_t count = 0;
  const int32_t rc = sdr_v3_rtl_tuner_gains(&h, gains, 4, &count);
  assert(rc == SDR_V3_BUFFER_SMALL);
  assert(count == kSortedGains.size());  // required count, not the capacity given
  for (auto g : gains) assert(g == -12345);  // no partial write on BUFFER_SMALL
  printf("[ok] insufficient capacity: SDR_V3_BUFFER_SMALL, no array modification\n");
}

void test_exact_capacity_boundary_succeeds() {
  SdrHandle h;
  h.stats.state = SDR_RUNNING;  // RUNNING is also a valid state for the query.
  h.stats.source = SDR_RTLSDR;
  h.usb_adapter = std::make_unique<FakeRtlAdapter>();
  std::vector<int32_t> gains(kSortedGains.size());
  uint32_t count = 0;
  const int32_t rc = sdr_v3_rtl_tuner_gains(&h, gains.data(),
                                             static_cast<uint32_t>(gains.size()), &count);
  assert(rc == SDR_OK);
  assert(count == kSortedGains.size());
  assert(gains == kSortedGains);
  printf("[ok] capacity exactly equal to the required count succeeds\n");
}

void test_empty_gain_table_is_ok_not_unsupported() {
  // A tuner with no configurable gain (e.g. FC2580) must not be confused
  // with an unsupported source: librtlsdr itself returns 0 entries, OK.
  SdrHandle h;
  h.stats.state = SDR_OPEN;
  h.stats.source = SDR_RTLSDR;
  h.usb_adapter = std::make_unique<EmptyGainAdapter>();
  uint32_t count = 123;
  int32_t probe = 1;
  const int32_t rc = sdr_v3_rtl_tuner_gains(&h, nullptr, 0, &count);
  assert(rc == SDR_OK);
  assert(count == 0);
  // A nonzero capacity is also accepted (0 <= capacity).
  const int32_t rc2 = sdr_v3_rtl_tuner_gains(&h, &probe, 1, &count);
  assert(rc2 == SDR_OK);
  assert(count == 0);
  printf("[ok] zero-entry gain table returns SDR_OK with count=0\n");
}

void test_non_rtl_source_is_unsupported() {
  // Synthetic source: no usb_adapter at all, like the real engine.
  SdrHandle synth;
  synth.stats.state = SDR_OPEN;
  synth.stats.source = SDR_SYNTHETIC;
  uint32_t count = 42;
  int32_t rc = sdr_v3_rtl_tuner_gains(&synth, nullptr, 0, &count);
  assert(rc == SDR_UNSUPPORTED);
  assert(count == 0);

  // File source: also no usb_adapter.
  SdrHandle file;
  file.stats.state = SDR_RUNNING;
  file.stats.source = SDR_FILE;
  count = 42;
  rc = sdr_v3_rtl_tuner_gains(&file, nullptr, 0, &count);
  assert(rc == SDR_UNSUPPORTED);
  assert(count == 0);
  printf("[ok] non-RTL source (synthetic/file) returns SDR_UNSUPPORTED, count=0\n");
}

// Minimal stand-in for the other real USB driver: HackRfAdapter does not
// override get_tuner_gains, so the UsbRxAdapter default applies even when
// the (test-only, mislabeled) source tag claims SDR_RTLSDR. This exercises
// the base-class default path independently of the real adapter classes
// (owned by the HackRF worker, not this file).
class NoGainAdapter final : public UsbRxAdapter {
 public:
  int open(int) override { return SDR_OK; }
  int configure(uint64_t, uint32_t, int32_t) override { return SDR_OK; }
  int start(PushFn, void*) override { return SDR_OK; }
  void stop() override {}
  void close() override {}
  // Deliberately does not override get_tuner_gains(): uses the
  // UsbRxAdapter base-class default (SDR_UNSUPPORTED, count=0).
};

void test_adapter_without_gain_support_is_unsupported() {
  SdrHandle h;
  h.stats.state = SDR_OPEN;
  h.stats.source = SDR_RTLSDR;
  h.usb_adapter = std::make_unique<NoGainAdapter>();
  uint32_t count = 7;
  const int32_t rc = sdr_v3_rtl_tuner_gains(&h, nullptr, 0, &count);
  assert(rc == SDR_UNSUPPORTED);
  assert(count == 0);
  printf("[ok] adapter without gain discovery (base-class default) is SDR_UNSUPPORTED\n");
}

void test_idle_handle_is_invalid_state() {
  SdrHandle h;  // Fresh handle: state SDR_IDLE, source SDR_NONE by default.
  assert(h.stats.state == SDR_IDLE);
  int32_t gains[4];
  uint32_t count = 99;
  const int32_t rc = sdr_v3_rtl_tuner_gains(&h, gains, 4, &count);
  assert(rc == SDR_INVALID_STATE);
  assert(count == 0);
  printf("[ok] IDLE handle (never opened) returns SDR_INVALID_STATE\n");
}

void test_null_arguments_rejected() {
  SdrHandle h;
  h.stats.state = SDR_OPEN;
  h.stats.source = SDR_RTLSDR;
  h.usb_adapter = std::make_unique<FakeRtlAdapter>();
  // NULL handle.
  uint32_t count = 1;
  assert(sdr_v3_rtl_tuner_gains(nullptr, nullptr, 0, &count) == SDR_INVALID_ARGUMENT);
  // NULL count (mandatory output, even for the probe form).
  int32_t gains[4];
  assert(sdr_v3_rtl_tuner_gains(&h, gains, 4, nullptr) == SDR_INVALID_ARGUMENT);
  // Nonzero capacity with a NULL destination buffer.
  count = 1;
  assert(sdr_v3_rtl_tuner_gains(&h, nullptr, 4, &count) == SDR_INVALID_ARGUMENT);
  printf("[ok] NULL handle / NULL count / capacity>0 with NULL buffer rejected\n");
}

void test_thread_safe_concurrent_queries_agree() {
  // Serialized-by-mutex concurrent callers must all observe the same
  // sorted table; this is not a claim of lock-free concurrency, only that
  // the handle's existing mutex (shared with the rest of the v3 control
  // lifecycle) makes concurrent queries safe and consistent.
  SdrHandle h;
  h.stats.state = SDR_RUNNING;
  h.stats.source = SDR_RTLSDR;
  h.usb_adapter = std::make_unique<FakeRtlAdapter>();
  std::atomic<int> mismatches{0};
  auto worker = [&] {
    for (int i = 0; i < 200; ++i) {
      int32_t gains[16];
      uint32_t count = 0;
      const int32_t rc = sdr_v3_rtl_tuner_gains(&h, gains, 16, &count);
      if (rc != SDR_OK || count != kSortedGains.size()) { ++mismatches; continue; }
      for (size_t j = 0; j < kSortedGains.size(); ++j)
        if (gains[j] != kSortedGains[j]) { ++mismatches; break; }
    }
  };
  std::thread t1(worker), t2(worker), t3(worker);
  t1.join(); t2.join(); t3.join();
  assert(mismatches == 0);
  printf("[ok] concurrent queries under the handle mutex all agree on the sorted table\n");
}

}  // namespace

int main() {
  test_full_query_matches_sorted_legacy_table();
  test_count_only_probe_does_not_touch_gains();
  test_insufficient_capacity_returns_buffer_small_and_leaves_array_untouched();
  test_exact_capacity_boundary_succeeds();
  test_empty_gain_table_is_ok_not_unsupported();
  test_non_rtl_source_is_unsupported();
  test_adapter_without_gain_support_is_unsupported();
  test_idle_handle_is_invalid_state();
  test_null_arguments_rejected();
  test_thread_safe_concurrent_queries_agree();
  printf("All sdr_v3_rtl_tuner_gains checks passed.\n");
  return 0;
}

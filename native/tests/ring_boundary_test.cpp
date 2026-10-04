// SPDX-License-Identifier: GPL-3.0-or-later
// White-box ring boundary test: upstream USB callbacks can exceed one slot.
// Include the implementation so we can exercise push() without any real USB
// device or a public IQ-copying API. This is not a hardware reception test.
#include "../src/sdrcore.cpp"

#include <cassert>
#include <atomic>
#include <chrono>
#include <memory>
#include <thread>
#include <vector>

// White-box injection at the internal adapter seam. The ABI still starts,
// stops, and closes the stream; no fake fd is claimed as a real USB device.
class CallbackAdapter final : public UsbRxAdapter {
 public:
  explicit CallbackAdapter(std::atomic<int>& calls) : calls_(calls) {}
  int open(int) override { return SDR_OK; }
  int configure(uint64_t, uint32_t, int32_t) override { return SDR_OK; }
  int start(PushFn push, void* ctx) override {
    const uint8_t iq[] = {0, 255, 1, 254};
    while (!stopped_.load()) {
      push(ctx, iq, sizeof(iq));
      ++calls_;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return SDR_OK;
  }
  void stop() override { stopped_ = true; }
  void close() override { stopped_ = true; }
 private:
  std::atomic<int>& calls_;
  std::atomic<bool> stopped_{false};
};

int main() {
  SdrHandle h;
  // One callback larger than the whole ring (independent of kSlots).
  std::vector<uint8_t> transfer((kSlots + 24) * kBytes);
  for (size_t i = 0; i < transfer.size(); ++i) transfer[i] = i & 0xff;
  h.stats.source = SDR_RTLSDR;
  h.push(transfer.data(), transfer.size());
  assert(h.stats.input_samples == transfer.size() / 2);
  assert(h.queued == kSlots);
  assert(h.stats.dropped_samples == (transfer.size() - kSlots * kBytes) / 2);
  h.producer_done = true;
  h.consume_loop();
  assert(h.stats.processed_samples == kSlots * kBytes / 2);
  uint64_t expected = kFnvOffset;
  for (size_t i = 0; i < kSlots * kBytes; ++i)
    expected = (expected ^ transfer[i]) * kFnvPrime;
  assert(h.stats.checksum == expected);

  SdrHandle hackrf;
  hackrf.stats.source = SDR_HACKRF;
  const uint8_t signed_iq[] = {0x80, 0x7f, 0xff, 0x00};
  hackrf.push(signed_iq, sizeof(signed_iq));
  assert(hackrf.queued == 1);
  assert(hackrf.ring[0][0] == 0 && hackrf.ring[0][1] == 255);
  assert(hackrf.ring[0][2] == 127 && hackrf.ring[0][3] == 128);
  hackrf.producer_done = true;
  hackrf.consume_loop();
  assert(hackrf.stats.processed_samples == 2);

  SdrHandle callback_handle;
  std::atomic<int> calls{0};
  callback_handle.usb_adapter = std::make_unique<CallbackAdapter>(calls);
  callback_handle.stats.state = SDR_OPEN;
  callback_handle.stats.source = SDR_RTLSDR;
  callback_handle.stats.sample_rate = 2400000;
  assert(sdr_v2_start(&callback_handle) == SDR_OK);
  for (int i = 0; i < 100 && calls == 0; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  assert(calls > 0);
  assert(sdr_v2_stop(&callback_handle) == SDR_OK);
  const int after_stop = calls;
  const SdrStats stopped = callback_handle.stats;
  assert(stopped.input_samples == stopped.processed_samples +
                                    stopped.dropped_samples);
  assert(stopped.processed_samples > 0);
  assert(sdr_v2_close(&callback_handle) == SDR_OK);
  std::this_thread::sleep_for(std::chrono::milliseconds(5));
  assert(calls == after_stop);  // No callback retains the released handle.
  return 0;
}

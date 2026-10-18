// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_RTL_TCP_ADAPTER_H
#define SDRCORE_RTL_TCP_ADAPTER_H

#include "usb_adapter.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <memory>

namespace rtltcp { class Client; }

// One rtl_tcp connection per start(). The endpoint is copied at construction;
// configure() is local until the socket connects, then updates the server.
// stop() interrupts DNS waiting, connect, handshake, and IQ reads. The caller
// joins the producer after stop(), before reconfiguring/restarting the stream.
class RtlTcpAdapter final : public UsbRxAdapter {
 public:
  RtlTcpAdapter(std::string host, uint16_t port);
  ~RtlTcpAdapter() override;

  int open(int fd) override;  // Network sources have no USB descriptor.
  int configure(uint64_t frequency_hz, uint32_t sample_rate,
                int32_t gain_tenths_db) override;
  int start(PushFn push, void* ctx) override;
  void stop() override;
  void close() override;
  // Called only by the core on an OPEN handle before spawning a new producer.
  // A prior stop after an already-failed producer must not cancel this start.
  void prepare_start();
  bool connected() const;
  bool supports_live_tuning() const override { return true; }
  int set_frequency(uint64_t frequency_hz) override;
  int set_gain(int32_t gain_tenths_db) override;
  // Allow for TCP/kernel/server buffers and samples already queued in the core.
  size_t retune_settle_bytes() const override { return 256 * 1024; }

 private:
  int send_bytes(const uint8_t* bytes, size_t count);
  int receive_bytes(uint8_t* bytes, size_t capacity);
  void release_socket();

  const std::string host_;
  const uint16_t port_;
  std::atomic<bool> stopped_{false};
  mutable std::mutex state_mutex_;
  std::condition_variable finished_;
  std::mutex command_mutex_;
  std::unique_ptr<rtltcp::Client> client_;
  // The producer alone closes socket_; stop() only shutdown()s it while
  // holding state_mutex_, preventing descriptor-number reuse in that race.
  int socket_ = -1;
  bool active_ = false;
  bool linked_ = false;
  bool configured_ = false;
  uint32_t frequency_ = 0;
  uint32_t rate_ = 0;
  int32_t gain_ = 0;
};

#endif  // SDRCORE_RTL_TCP_ADAPTER_H

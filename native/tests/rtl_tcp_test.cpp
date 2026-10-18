// SPDX-License-Identifier: GPL-3.0-or-later
// In-process rtl_tcp server: exercise the public v3 ABI, not transport internals.
#include "sdrcore_v3.h"

#include <arpa/inet.h>
#include <cerrno>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <exception>
#include <functional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
constexpr auto kDeadline = 4s;
constexpr char kHost[] = "127.0.0.1";
// rtl_tcp's twelve-byte RTL0 greeting: magic, tuner type, gain count.
constexpr std::array<uint8_t, 12> kHeader{
    'R', 'T', 'L', '0', 0, 0, 0, 5, 0, 0, 0, 1};

void require(bool ok, const char* what) {
  if (!ok) throw std::runtime_error(what);
}

struct Fd {
  int fd = -1;
  explicit Fd(int value = -1) : fd(value) {}
  ~Fd() { if (fd >= 0) ::close(fd); }
  Fd(const Fd&) = delete;
  Fd& operator=(const Fd&) = delete;
};

void ready(int fd, short events) {
  pollfd p{fd, events, 0};
  int rc;
  do { rc = ::poll(&p, 1, 4000); } while (rc < 0 && errno == EINTR);
  require(rc > 0 && !(p.revents & POLLNVAL), "socket poll timed out/failed");
  require((p.revents & (events | POLLERR | POLLHUP)) != 0, "unexpected poll event");
}

void send_bytes(int fd, const uint8_t* bytes, size_t count) {
  while (count) {
    ready(fd, POLLOUT);
    const ssize_t n = ::send(fd, bytes, count, MSG_NOSIGNAL);
    require(n > 0, "socket send failed");
    bytes += n;
    count -= static_cast<size_t>(n);
  }
}

template <size_t N>
void send_bytes(int fd, const std::array<uint8_t, N>& bytes) {
  send_bytes(fd, bytes.data(), bytes.size());
}

void read_bytes(int fd, uint8_t* bytes, size_t count) {
  while (count) {
    ready(fd, POLLIN);
    const ssize_t n = ::recv(fd, bytes, count, 0);
    require(n > 0, "socket closed before expected commands");
    bytes += n;
    count -= static_cast<size_t>(n);
  }
}

void expect_command(int fd, uint8_t opcode, uint32_t value) {
  std::array<uint8_t, 5> actual{};
  read_bytes(fd, actual.data(), actual.size());
  const std::array<uint8_t, 5> expected{
      opcode, static_cast<uint8_t>(value >> 24),
      static_cast<uint8_t>(value >> 16), static_cast<uint8_t>(value >> 8),
      static_cast<uint8_t>(value)};
  require(actual == expected, "wrong rtl_tcp command/order/big-endian payload");
}

void expect_startup(int fd, uint32_t freq, uint32_t rate, uint32_t gain) {
  expect_command(fd, 0x01, freq);
  expect_command(fd, 0x02, rate);
  expect_command(fd, 0x03, 1);  // manual gain, not tuner AGC
  expect_command(fd, 0x04, gain);
}

void expect_closed(int fd) {
  uint8_t byte = 0;
  ready(fd, POLLIN);
  require(::recv(fd, &byte, 1, 0) == 0, "stop did not close TCP peer");
}

void await_phase(const std::atomic<int>& phase, int target) {
  const auto end = Clock::now() + kDeadline;
  while (phase.load() < target && Clock::now() < end)
    std::this_thread::sleep_for(1ms);
  require(phase.load() >= target, "server/client phase timed out");
}

// Worker exceptions are rethrown by join(), rather than terminating the process.
class Server {
 public:
  explicit Server(std::function<void(int)> session) : session_(std::move(session)) {
    listener_.fd = ::socket(AF_INET, SOCK_STREAM, 0);
    require(listener_.fd >= 0, "socket failed");
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    require(::bind(listener_.fd, reinterpret_cast<sockaddr*>(&address),
                   sizeof(address)) == 0, "bind failed");
    socklen_t size = sizeof(address);
    require(::getsockname(listener_.fd, reinterpret_cast<sockaddr*>(&address),
                          &size) == 0, "getsockname failed");
    port_ = ntohs(address.sin_port);
    require(::listen(listener_.fd, 4) == 0, "listen failed");
    worker_ = std::thread([this] {
      try { session_(listener_.fd); }
      catch (...) { failure_ = std::current_exception(); }
    });
  }
  ~Server() { if (worker_.joinable()) worker_.join(); }
  uint16_t port() const { return port_; }
  void join() {
    if (worker_.joinable()) worker_.join();
    if (failure_) std::rethrow_exception(failure_);
  }
  Server(const Server&) = delete;
  Server& operator=(const Server&) = delete;

 private:
  Fd listener_;
  uint16_t port_ = 0;
  std::function<void(int)> session_;
  std::thread worker_;
  std::exception_ptr failure_;
};

Fd accept_client(int listener) {
  ready(listener, POLLIN);
  Fd client(::accept(listener, nullptr, nullptr));
  require(client.fd >= 0, "accept failed");
  return Fd(std::exchange(client.fd, -1));
}

SdrV3Controls controls(uint64_t freq = 100000000, uint32_t rate = 1024000,
                       int gain = 280) {
  SdrV3Controls c{};
  c.size = sizeof(c);
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = freq;
  c.sample_rate = rate;
  c.mode = SDR_V3_WFM;
  c.bandwidth_hz = 200000;
  c.gain_tenths_db = gain;
  c.squelch_level_db = -50;
  c.volume = 1;
  c.muted = 1;
  return c;
}

SdrV3Snapshot snapshot(SdrHandle* h) {
  SdrV3Snapshot s{};
  s.size = sizeof(s);
  s.revision = SDR_V3_REVISION;
  require(sdr_v3_snapshot(h, &s) == SDR_OK, "snapshot failed");
  return s;
}

template <typename Predicate>
SdrV3Snapshot until(SdrHandle* h, Predicate predicate) {
  const auto end = Clock::now() + kDeadline;
  SdrV3Snapshot s = snapshot(h);
  while (!predicate(s) && Clock::now() < end) {
    std::this_thread::sleep_for(2ms);
    s = snapshot(h);
  }
  require(predicate(s), "snapshot condition timed out");
  return s;
}

void wait_link(SdrHandle* h) {
  const auto end = Clock::now() + kDeadline;
  while (Clock::now() < end) {
    const int link = sdr_v3_rtl_tcp_link(h);
    require(link >= 0, "link query rejected active handle");
    if (link == 1) return;
    std::this_thread::sleep_for(2ms);
  }
  require(false, "rtl_tcp header validation timed out");
}

SdrHandle* open(uint16_t port) {
  SdrHandle* h = sdr_create();
  require(h != nullptr, "create failed");
  require(sdr_v3_open_rtl_tcp(h, kHost, sizeof(kHost) - 1, port) == SDR_OK,
          "open_rtl_tcp failed");
  const auto s = snapshot(h);
  require(s.state == SDR_OPEN && s.source == SDR_RTL_TCP,
          "open did not set OPEN/RTL_TCP");
  require(sdr_v3_rtl_tcp_link(h) == 0, "open must not connect");
  return h;
}

void test_endpoint_validation_and_refused() {
  SdrHandle* h = sdr_create();
  require(h != nullptr, "create failed");
  require(sdr_v3_open_rtl_tcp(h, nullptr, 1, 1234) == SDR_INVALID_ARGUMENT,
          "null host accepted");
  require(sdr_v3_open_rtl_tcp(h, kHost, 0, 1234) == SDR_INVALID_ARGUMENT,
          "empty host accepted");
  require(sdr_v3_open_rtl_tcp(h, kHost, sizeof(kHost) - 1, 0) ==
              SDR_INVALID_ARGUMENT, "zero port accepted");
  require(snapshot(h).state == SDR_IDLE, "invalid endpoint changed state");
  require(sdr_v3_rtl_tcp_link(h) == SDR_INVALID_STATE,
          "idle link query accepted");
  // Reserve a loopback port, then close the listener: TCP connect must be
  // refused asynchronously, not while open_rtl_tcp is called.
  uint16_t port = 0;
  {
    Fd socket(::socket(AF_INET, SOCK_STREAM, 0));
    require(socket.fd >= 0, "socket failed");
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    require(::bind(socket.fd, reinterpret_cast<sockaddr*>(&address),
                   sizeof(address)) == 0, "bind failed");
    socklen_t size = sizeof(address);
    require(::getsockname(socket.fd, reinterpret_cast<sockaddr*>(&address),
                          &size) == 0, "getsockname failed");
    port = ntohs(address.sin_port);
  }
  require(sdr_v3_open_rtl_tcp(h, kHost, sizeof(kHost) - 1, port) == SDR_OK,
          "open to closed port must succeed");
  auto c = controls();
  auto bad = c;
  bad.sample_rate = 300001;
  require(sdr_v3_set_controls(h, &bad) != SDR_OK, "RTL rate gap accepted");
  bad = c;
  bad.agc = 1;
  require(sdr_v3_set_controls(h, &bad) != SDR_OK, "RTL AGC accepted");
  require(sdr_v3_set_controls(h, &c) == SDR_OK, "valid controls failed");
  require(sdr_v3_start(h) == SDR_OK, "start failed");
  const auto s = until(h, [](const auto& x) { return x.state == SDR_ERROR; });
  require(s.last_error == SDR_V3_TCP_REFUSED && s.error_sequence > 0,
          "refused connection not reported as TCP_REFUSED");
  require(sdr_v3_stop(h) == SDR_OK, "stop after refusal failed");
  sdr_destroy(h);
  std::puts("[ok] endpoint validation, deferred connect and refused port");
}

void test_fragmented_header_odd_iq_and_fft() {
  std::atomic<int> phase{0};
  Server server([&](int listener) {
    auto client = accept_client(listener);
    send_bytes(client.fd, kHeader.data(), 3);
    phase = 1;
    await_phase(phase, 2);
    send_bytes(client.fd, kHeader.data() + 3, kHeader.size() - 3);
    expect_startup(client.fd, 101000000, 1024000, 280);
    // First odd byte is not a complete IQ pair. Then send 262144 pairs
    // split at odd boundaries; count must not drop or double-count a pair.
    const uint8_t first = 255;
    send_bytes(client.fd, &first, 1);
    phase = 3;
    await_phase(phase, 4);
    std::vector<uint8_t> iq(524287);
    const uint8_t pattern[8] = {255, 128, 128, 255, 0, 128, 128, 0};
    for (size_t i = 0; i < iq.size(); ++i) iq[i] = pattern[(i + 1) % 8];
    send_bytes(client.fd, iq.data(), 13);
    send_bytes(client.fd, iq.data() + 13, iq.size() - 13);
    phase = 4;
    expect_closed(client.fd);
  });
  SdrHandle* h = open(server.port());
  auto c = controls();
  require(sdr_v3_set_controls(h, &c) == SDR_OK, "controls failed");
  SdrV3Display display{};
  display.size = sizeof(display);
  display.revision = SDR_V3_REVISION;
  display.view_bandwidth_hz = 1024000;
  display.width = 128;
  require(sdr_v3_set_display(h, &display) == SDR_OK, "display failed");
  require(sdr_v3_start(h) == SDR_OK, "start failed");
  await_phase(phase, 1);
  require(phase == 1, "server did not send first header fragment");
  require(sdr_v3_rtl_tcp_link(h) == 0, "partial RTL0 header activated link");
  c.center_frequency_hz = 101000000;
  require(sdr_v3_set_controls(h, &c) == SDR_OK, "tune during connect rejected");
  until(h, [](const auto& x) { return x.center_frequency_hz == 101000000; });
  phase = 2;
  wait_link(h);
  await_phase(phase, 3);
  require(phase == 3 && snapshot(h).input_samples == 0,
          "odd single byte counted as an IQ pair");
  phase = 4;
  const auto s = until(h, [](const auto& x) { return x.input_samples == 262144; });
  require(s.state == SDR_RUNNING && s.source == SDR_RTL_TCP,
          "IQ did not keep stream running");
  const auto end_fft = Clock::now() + kDeadline;
  SdrV3Fft fft{};
  std::array<float, 128> bins{};
  int rc = SDR_V3_NO_DATA;
  while (rc == SDR_V3_NO_DATA && Clock::now() < end_fft) {
    fft = {};
    fft.size = sizeof(fft);
    fft.revision = SDR_V3_REVISION;
    rc = sdr_v3_read_fft(h, 0, &fft, bins.data(), bins.size());
    if (rc == SDR_V3_NO_DATA) std::this_thread::sleep_for(2ms);
  }
  require(rc == SDR_OK && fft.width == bins.size() && fft.sequence > 0 &&
              fft.stream_generation == s.stream_generation &&
              fft.low_hz < 101000000 && fft.high_hz > 101000000 &&
              std::all_of(bins.begin(), bins.end(), [](float x) { return std::isfinite(x); }),
          "no coherent FFT row from loopback IQ");
  require(sdr_v3_stop(h) == SDR_OK, "stop failed");
  require(snapshot(h).input_samples == 262144, "IQ pair count changed after stop");
  sdr_destroy(h);
  server.join();
  std::puts("[ok] fragmented RTL0, exact odd-byte IQ count and FFT");
}

void test_bad_header_and_eof() {
  for (int malformed = 0; malformed < 2; ++malformed) {
    Server server([=](int listener) {
      auto client = accept_client(listener);
      if (malformed) {
        auto header = kHeader;
        header[3] = 'X';
        send_bytes(client.fd, header);
      } else {
        send_bytes(client.fd, kHeader);
        expect_startup(client.fd, 100000000, 1024000, 280);
        // No IQ: clean EOF after a valid greeting is an asynchronous failure.
      }
    });
    SdrHandle* h = open(server.port());
    auto c = controls();
    require(sdr_v3_set_controls(h, &c) == SDR_OK, "controls failed");
    require(sdr_v3_start(h) == SDR_OK, "start failed");
    const auto s = until(h, [](const auto& x) { return x.state == SDR_ERROR; });
    require(s.last_error == (malformed ? SDR_V3_TCP_PROTOCOL : SDR_DEVICE_GONE),
            "bad greeting/EOF not reported correctly");
    require(sdr_v3_stop(h) == SDR_OK, "stop after failure failed");
    require(snapshot(h).last_error == s.last_error, "async error not sticky");
    sdr_destroy(h);
    server.join();
  }
  std::puts("[ok] malformed greeting and clean EOF surface distinct errors");
}

void test_header_timeout_and_retry() {
  std::atomic<int> phase{0};
  Server server([&](int listener) {
    {
      auto client = accept_client(listener);
      send_bytes(client.fd, kHeader.data(), 4);
      phase = 1;
      expect_closed(client.fd);  // header never finishes; finite deadline
    }
    {
      auto client = accept_client(listener);
      send_bytes(client.fd, kHeader);
      expect_startup(client.fd, 100000000, 1024000, 280);
      phase = 2;
      expect_closed(client.fd);
    }
  });
  SdrHandle* h = open(server.port());
  auto c = controls();
  require(sdr_v3_set_controls(h, &c) == SDR_OK, "controls failed");
  require(sdr_v3_start(h) == SDR_OK, "start failed");
  await_phase(phase, 1);
  const auto expired = until(h, [](const auto& x) { return x.state == SDR_ERROR; });
  require(expired.last_error == SDR_V3_TCP_TIMEOUT, "incomplete header did not time out");
  require(sdr_v3_stop(h) == SDR_OK, "stop after timeout failed");
  require(sdr_v3_start(h) == SDR_OK, "retry after timeout failed");
  wait_link(h);
  require(sdr_v3_stop(h) == SDR_OK, "stop after retry failed");
  sdr_destroy(h);
  server.join();
  require(phase == 2, "retry did not reach server");
  std::puts("[ok] incomplete header times out and explicit retry works");
}

void test_stop_waiting_and_restart() {
  std::atomic<int> phase{0};
  Server server([&](int listener) {
    {
      auto client = accept_client(listener);
      send_bytes(client.fd, kHeader.data(), 2);
      phase = 1;
      expect_closed(client.fd);  // stop while recv waits for rest of header
    }
    {
      auto client = accept_client(listener);
      send_bytes(client.fd, kHeader);
      expect_startup(client.fd, 100000000, 1024000, 280);
      phase = 2;
      expect_closed(client.fd);  // stop while blocked reading IQ
    }
    {
      auto client = accept_client(listener);
      send_bytes(client.fd, kHeader);
      expect_startup(client.fd, 100000000, 1024000, 280);
      phase = 3;
      expect_closed(client.fd);
    }
  });
  SdrHandle* h = open(server.port());
  auto c = controls();
  require(sdr_v3_set_controls(h, &c) == SDR_OK, "controls failed");
  require(sdr_v3_start(h) == SDR_OK, "start failed");
  await_phase(phase, 1);
  require(phase == 1 && sdr_v3_rtl_tcp_link(h) == 0, "partial handshake linked");
  const auto before = Clock::now();
  require(sdr_v3_stop(h) == SDR_OK && Clock::now() - before < 2s,
          "stop did not cancel pending handshake promptly");
  require(snapshot(h).state == SDR_OPEN && sdr_v3_rtl_tcp_link(h) == 0,
          "stop left link active");
  require(sdr_v3_start(h) == SDR_OK, "restart after handshake stop failed");
  wait_link(h);
  await_phase(phase, 2);
  require(phase == 2, "second session did not start");
  const auto reading = Clock::now();
  require(sdr_v3_stop(h) == SDR_OK && Clock::now() - reading < 2s,
          "stop did not cancel idle IQ read promptly");
  require(sdr_v3_start(h) == SDR_OK, "restart after read stop failed");
  wait_link(h);
  require(snapshot(h).stream_generation == 3, "restart did not advance generation");
  require(sdr_v3_stop(h) == SDR_OK, "third stop failed");
  sdr_destroy(h);
  server.join();
  std::puts("[ok] stop cancels handshake/read and restart reapplies commands");
}

void test_tune_gain_rate_changes() {
  std::atomic<int> phase{0};
  Server server([&](int listener) {
    {
      auto client = accept_client(listener);
      send_bytes(client.fd, kHeader);
      expect_startup(client.fd, 100000000, 1024000, 280);
      phase = 1;
      expect_command(client.fd, 0x01, 101000000);
      phase = 2;
      expect_command(client.fd, 0x04, 310);
      phase = 3;
      expect_closed(client.fd);  // changing sample rate reconnects
    }
    {
      auto client = accept_client(listener);
      send_bytes(client.fd, kHeader);
      expect_startup(client.fd, 101000000, 1200000, 310);
      phase = 4;
      expect_closed(client.fd);
    }
  });
  SdrHandle* h = open(server.port());
  auto c = controls();
  require(sdr_v3_set_controls(h, &c) == SDR_OK, "controls failed");
  require(sdr_v3_start(h) == SDR_OK, "start failed");
  wait_link(h);
  const auto generation = snapshot(h).stream_generation;
  c.center_frequency_hz = 101000000;
  require(sdr_v3_set_controls(h, &c) == SDR_OK, "live tune rejected");
  until(h, [](const auto& x) { return x.center_frequency_hz == 101000000; });
  c.gain_tenths_db = 310;
  require(sdr_v3_set_controls(h, &c) == SDR_OK, "live gain rejected");
  until(h, [](const auto& x) { return x.gain_tenths_db == 310; });
  require(snapshot(h).stream_generation == generation, "tune/gain restarted stream");
  c.sample_rate = 1200000;
  require(sdr_v3_set_controls(h, &c) == SDR_OK, "sample rate change rejected");
  wait_link(h);
  until(h, [](const auto& x) { return x.sample_rate == 1200000; });
  require(snapshot(h).stream_generation > generation, "rate change did not restart");
  require(sdr_v3_stop(h) == SDR_OK, "stop failed");
  sdr_destroy(h);
  server.join();
  require(phase == 4, "command sequence incomplete");
  std::puts("[ok] live tune/gain commands and rate-change reconnection");
}

void test_restart_after_peer_disconnect() {
  std::atomic<int> phase{0};
  Server server([&](int listener) {
    {
      auto client = accept_client(listener);
      send_bytes(client.fd, kHeader);
      expect_startup(client.fd, 100000000, 1024000, 280);
      phase = 1;
    }
    {
      auto client = accept_client(listener);
      send_bytes(client.fd, kHeader);
      expect_startup(client.fd, 100000000, 1024000, 280);
      phase = 2;
      expect_closed(client.fd);
    }
  });
  SdrHandle* h = open(server.port());
  auto c = controls();
  require(sdr_v3_set_controls(h, &c) == SDR_OK, "controls failed");
  require(sdr_v3_start(h) == SDR_OK, "first start failed");
  until(h, [](const auto& x) { return x.state == SDR_ERROR; });
  require(sdr_v3_stop(h) == SDR_OK, "stop after EOF failed");
  require(sdr_v3_start(h) == SDR_OK, "restart after EOF failed");
  wait_link(h);
  await_phase(phase, 2);
  require(snapshot(h).state == SDR_RUNNING, "stale cancellation killed restart");
  require(sdr_v3_stop(h) == SDR_OK, "final stop failed");
  sdr_destroy(h);
  server.join();
  std::puts("[ok] reconnect after EOF reapplies settings without stale stop");
}
}  // namespace

int main() {
  try {
    require(sdr_version() == SDR_V3_REVISION, "v3 ABI unavailable");
    test_endpoint_validation_and_refused();
    test_fragmented_header_odd_iq_and_fft();
    test_bad_header_and_eof();
    test_header_timeout_and_retry();
    test_stop_waiting_and_restart();
    test_tune_gain_rate_changes();
    test_restart_after_peer_disconnect();
    std::puts("rtl_tcp_test: all passed");
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "rtl_tcp_test: %s\n", e.what());
    return 1;
  }
}

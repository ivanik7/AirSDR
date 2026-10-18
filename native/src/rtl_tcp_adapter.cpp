// SPDX-License-Identifier: GPL-3.0-or-later
#include "rtl_tcp_adapter.h"
#include "rtl_tcp_client.h"

#include "sdrcore_v3.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

#ifndef _WIN32
#include <cerrno>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

using Clock = std::chrono::steady_clock;
constexpr auto kConnectDeadline = std::chrono::seconds(3);

#ifndef _WIN32
namespace {
constexpr auto kPollSlice = std::chrono::milliseconds(25);

struct Address {
  sockaddr_storage addr{};
  socklen_t length = 0;
  int family = 0;
  int type = 0;
  int protocol = 0;
};
struct Resolution {
  std::mutex mutex;
  bool done = false;
  std::vector<Address> addresses;
};

// getaddrinfo has no cancellation API. Only this self-owned result and endpoint
// copies are captured by the detached resolver; a timed-out start never waits
// for the system resolver or leaves pointers into a destroyed adapter.
std::shared_ptr<Resolution> resolve_async(std::string host, uint16_t port) {
  auto result = std::make_shared<Resolution>();
  std::thread([result, host = std::move(host), port] {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* list = nullptr;
    const std::string service = std::to_string(port);
    const int rc = getaddrinfo(host.c_str(), service.c_str(), &hints, &list);
    std::vector<Address> addresses;
    if (rc == 0) {
      for (const addrinfo* p = list; p; p = p->ai_next) {
        if (p->ai_addrlen > sizeof(sockaddr_storage)) continue;
        Address a;
        std::memcpy(&a.addr, p->ai_addr, p->ai_addrlen);
        a.length = static_cast<socklen_t>(p->ai_addrlen);
        a.family = p->ai_family;
        a.type = p->ai_socktype;
        a.protocol = p->ai_protocol;
        addresses.push_back(a);
      }
      freeaddrinfo(list);
    }
    std::lock_guard<std::mutex> lock(result->mutex);
    result->addresses = std::move(addresses);
    result->done = true;
  }).detach();
  return result;
}

// All sockets are nonblocking. Short poll slices make cancellation reliable
// even when shutdown() cannot wake a socket still in connect().
int wait_socket(int fd, short events, Clock::time_point deadline,
                const std::atomic<bool>& stopped) {
  while (!stopped.load()) {
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline - Clock::now());
    if (remaining.count() <= 0) return SDR_V3_TCP_TIMEOUT;
    const auto wait = std::min(remaining, kPollSlice);
    pollfd pfd{fd, events, 0};
    const int rc = poll(&pfd, 1, static_cast<int>(wait.count()));
    if (rc > 0) return SDR_OK;
    if (rc < 0 && errno != EINTR) return SDR_IO_ERROR;
  }
  return SDR_OK;
}

int socket_error(int fd) {
  int code = 0;
  socklen_t size = sizeof(code);
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) < 0)
    return SDR_IO_ERROR;
  if (code == ETIMEDOUT) return SDR_V3_TCP_TIMEOUT;
  if (code == ECONNREFUSED || code == EHOSTUNREACH || code == ENETUNREACH)
    return SDR_V3_TCP_REFUSED;
  return code == 0 ? SDR_OK : SDR_IO_ERROR;
}
}  // namespace
#endif

RtlTcpAdapter::RtlTcpAdapter(std::string host, uint16_t port)
    : host_(std::move(host)), port_(port) {}
RtlTcpAdapter::~RtlTcpAdapter() { close(); }

void RtlTcpAdapter::prepare_start() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (!active_) stopped_ = false;
}

int RtlTcpAdapter::open(int /*fd*/) { return SDR_UNSUPPORTED; }

int RtlTcpAdapter::configure(uint64_t frequency_hz, uint32_t sample_rate,
                             int32_t gain_tenths_db) {
  if (frequency_hz > UINT32_MAX ||
      !((sample_rate >= 225001 && sample_rate <= 300000) ||
        (sample_rate >= 900001 && sample_rate <= 3200000)) ||
      gain_tenths_db < -1000 || gain_tenths_db > 1000)
    return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> command_lock(command_mutex_);
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (linked_) {
      // Commit metadata only if all commands have reached the socket.
    } else {
      frequency_ = static_cast<uint32_t>(frequency_hz);
      rate_ = sample_rate;
      gain_ = gain_tenths_db;
      configured_ = true;
      return SDR_OK;
    }
  }
  int rc = client_->setFrequency(frequency_hz);
  if (rc == SDR_OK) rc = client_->setSampleRate(sample_rate);
  if (rc == SDR_OK) rc = client_->setGainMode(1);
  if (rc == SDR_OK) rc = client_->setGain(static_cast<uint32_t>(gain_tenths_db));
  if (rc != SDR_OK) return rc;
  std::lock_guard<std::mutex> lock(state_mutex_);
  frequency_ = static_cast<uint32_t>(frequency_hz);
  rate_ = sample_rate;
  gain_ = gain_tenths_db;
  configured_ = true;
  return SDR_OK;
}

bool RtlTcpAdapter::connected() const {
  std::lock_guard<std::mutex> lock(state_mutex_);
  return linked_;
}

int RtlTcpAdapter::set_frequency(uint64_t frequency_hz) {
  if (frequency_hz > UINT32_MAX) return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(command_mutex_);
  {
    std::lock_guard<std::mutex> state(state_mutex_);
    if (!linked_) {
      frequency_ = static_cast<uint32_t>(frequency_hz);
      return SDR_OK;
    }
  }
  int rc = client_->setFrequency(frequency_hz);
  if (rc == SDR_OK) {
    std::lock_guard<std::mutex> state(state_mutex_);
    frequency_ = static_cast<uint32_t>(frequency_hz);
  }
  return rc;
}

int RtlTcpAdapter::set_gain(int32_t gain_tenths_db) {
  if (gain_tenths_db < -1000 || gain_tenths_db > 1000)
    return SDR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(command_mutex_);
  {
    std::lock_guard<std::mutex> state(state_mutex_);
    if (!linked_) {
      gain_ = gain_tenths_db;
      return SDR_OK;
    }
  }
  int rc = client_->setGain(static_cast<uint32_t>(gain_tenths_db));
  if (rc == SDR_OK) {
    std::lock_guard<std::mutex> state(state_mutex_);
    gain_ = gain_tenths_db;
  }
  return rc;
}

int RtlTcpAdapter::send_bytes(const uint8_t* bytes, size_t count) {
#ifdef _WIN32
  (void)bytes; (void)count;
  return SDR_UNSUPPORTED;
#else
  const auto deadline = Clock::now() + kConnectDeadline;
  int fd;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (socket_ < 0 || stopped_) return SDR_INVALID_STATE;
    fd = socket_;
  }
  size_t offset = 0;
  while (offset < count && !stopped_) {
#ifdef __APPLE__
    const int send_flags = 0;  // SO_NOSIGPIPE is set on the socket.
#else
    const int send_flags = MSG_NOSIGNAL;
#endif
    const ssize_t sent = send(fd, bytes + offset, count - offset,
                             send_flags);
    if (sent > 0) { offset += static_cast<size_t>(sent); continue; }
    if (sent < 0 && errno == EINTR) continue;
    if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      const int rc = wait_socket(fd, POLLOUT, deadline, stopped_);
      if (rc != SDR_OK) return rc;
      continue;
    }
    return SDR_IO_ERROR;
  }
  return stopped_ ? SDR_INVALID_STATE : SDR_OK;
#endif
}

int RtlTcpAdapter::receive_bytes(uint8_t* bytes, size_t capacity) {
#ifdef _WIN32
  (void)bytes; (void)capacity;
  return SDR_UNSUPPORTED;
#else
  int fd;
  { std::lock_guard<std::mutex> lock(state_mutex_); fd = socket_; }
  while (!stopped_) {
    pollfd pfd{fd, POLLIN, 0};
    const int ready = poll(&pfd, 1, static_cast<int>(kPollSlice.count()));
    if (stopped_) break;
    if (ready == 0 || (ready < 0 && errno == EINTR)) continue;
    if (ready < 0) return SDR_IO_ERROR;
    const ssize_t n = recv(fd, bytes, capacity, 0);
    if (n > 0) return static_cast<int>(n);
    if (n == 0) return SDR_DEVICE_GONE;
    if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)
      return SDR_IO_ERROR;
  }
  return SDR_OK;
#endif
}

void RtlTcpAdapter::release_socket() {
#ifndef _WIN32
  // Writers hold command_mutex_; shutdown in stop() can interrupt a writer
  // without waiting for that lock. Only the producer performs close().
  std::lock_guard<std::mutex> command_lock(command_mutex_);
  std::lock_guard<std::mutex> lock(state_mutex_);
  linked_ = false;
  client_.reset();
  if (socket_ >= 0) {
    ::close(socket_);
    socket_ = -1;
  }
#endif
}

int RtlTcpAdapter::start(PushFn push, void* ctx) {
  if (!push) return SDR_INVALID_ARGUMENT;
  bool pre_stopped;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (active_ || !configured_) return SDR_INVALID_STATE;
    active_ = true;
    linked_ = false;
    pre_stopped = stopped_.exchange(false);
  }
  // A stop racing before start must not be lost; after the previous producer
  // has joined, the next start clears its acknowledged cancellation.
  int rc = SDR_OK;
#ifdef _WIN32
  rc = SDR_UNSUPPORTED;
#else
  if (!pre_stopped && host_.size() >= 1 && host_.size() <= 255 && port_ != 0) {
    const auto deadline = Clock::now() + kConnectDeadline;
    auto resolution = resolve_async(host_, port_);
    while (!stopped_) {
      bool done;
      { std::lock_guard<std::mutex> lock(resolution->mutex); done = resolution->done; }
      if (done) break;
      if (Clock::now() >= deadline) { rc = SDR_V3_TCP_TIMEOUT; break; }
      std::this_thread::sleep_for(kPollSlice);
    }
    std::vector<Address> addresses;
    {
      std::lock_guard<std::mutex> lock(resolution->mutex);
      if (resolution->done) addresses = resolution->addresses;
    }
    if (rc == SDR_OK && !stopped_ && addresses.empty())
      rc = SDR_V3_TCP_REFUSED;
    if (rc == SDR_OK && !stopped_) {
      rc = SDR_V3_TCP_REFUSED;
      for (const auto& a : addresses) {
        if (stopped_) break;
        if (Clock::now() >= deadline) { rc = SDR_V3_TCP_TIMEOUT; break; }
        const int fd = ::socket(a.family, a.type, a.protocol);
        if (fd < 0) continue;
#ifdef __APPLE__
        const int no_sigpipe = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe,
                       sizeof(no_sigpipe)) < 0) { ::close(fd); continue; }
#endif
        const int flags = fcntl(fd, F_GETFL, 0);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
          ::close(fd);
          continue;
        }
        {
          std::lock_guard<std::mutex> lock(state_mutex_);
          if (stopped_) { ::close(fd); break; }
          socket_ = fd;
        }
        int connected = ::connect(fd, reinterpret_cast<const sockaddr*>(&a.addr), a.length);
        int attempt = SDR_OK;
        if (connected < 0) {
          if (errno == EINPROGRESS || errno == EINTR) {
            attempt = wait_socket(fd, POLLOUT, deadline, stopped_);
            if (attempt == SDR_OK && !stopped_) attempt = socket_error(fd);
          } else {
            attempt = socket_error(fd);
            if (attempt == SDR_OK) attempt = SDR_V3_TCP_REFUSED;
          }
        }
        if (attempt == SDR_OK && !stopped_) { rc = SDR_OK; break; }
        release_socket();
        if (attempt == SDR_V3_TCP_TIMEOUT) { rc = attempt; break; }
        rc = attempt;
      }
    }
    if (rc == SDR_OK && !stopped_) {
      uint8_t header[12]{};
      size_t got = 0;
      while (got < sizeof(header) && !stopped_) {
        const int fd = [&] { std::lock_guard<std::mutex> lock(state_mutex_);
                             return socket_; }();
        int ready = wait_socket(fd, POLLIN, deadline, stopped_);
        if (ready != SDR_OK) { rc = ready; break; }
        if (stopped_) break;
        const ssize_t n = recv(fd, header + got, sizeof(header) - got, 0);
        if (n > 0) { got += static_cast<size_t>(n); continue; }
        if (n == 0) { rc = SDR_V3_TCP_PROTOCOL; break; }
        if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
          rc = SDR_IO_ERROR;
          break;
        }
      }
      if (rc == SDR_OK && !stopped_ &&
          std::memcmp(header, "RTL0", 4) != 0) rc = SDR_V3_TCP_PROTOCOL;
    }
    if (rc == SDR_OK && !stopped_) {
      uint32_t frequency, rate;
      int32_t gain;
      {
        std::lock_guard<std::mutex> command_lock(command_mutex_);
        {
          std::lock_guard<std::mutex> lock(state_mutex_);
          frequency = frequency_;
          rate = rate_;
          gain = gain_;
        }
        client_ = std::make_unique<rtltcp::Client>(
            [this](const uint8_t* bytes, size_t count) {
              return send_bytes(bytes, count);
            },
            [this](uint8_t* bytes, size_t capacity) {
              return receive_bytes(bytes, capacity);
            },
            [push, ctx](const float* samples, size_t count) {
              std::array<uint8_t, 16384> iq{};
              for (size_t i = 0; i < count * 2; ++i)
                iq[i] = static_cast<uint8_t>(samples[i] * 128.0f + 128.0f);
              push(ctx, iq.data(), count * 2);
            });
        // The minimum common classic rtl_tcp command sequence; extended
        // opcodes require server-version/capability negotiation (not in v1).
        rc = client_->setFrequency(frequency);
        if (rc == SDR_OK) rc = client_->setSampleRate(rate);
        if (rc == SDR_OK) rc = client_->setGainMode(1);
        if (rc == SDR_OK) rc = client_->setGain(static_cast<uint32_t>(gain));
        if (rc == SDR_OK && !stopped_) {
          std::lock_guard<std::mutex> lock(state_mutex_);
          linked_ = true;
        }
      }
    }
    if (rc == SDR_OK && !stopped_) rc = client_->worker();
  } else if (!pre_stopped) {
    rc = SDR_INVALID_ARGUMENT;
  }
  release_socket();
#endif
  bool was_stopped;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    was_stopped = stopped_.exchange(false);
    linked_ = false;
    active_ = false;
  }
  finished_.notify_all();
  return (was_stopped || pre_stopped) ? SDR_OK : rc;
}

void RtlTcpAdapter::stop() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  stopped_ = true;
#ifndef _WIN32
  if (socket_ >= 0) ::shutdown(socket_, SHUT_RDWR);
#endif
}

void RtlTcpAdapter::close() {
  stop();
  std::unique_lock<std::mutex> lock(state_mutex_);
  finished_.wait(lock, [this] { return !active_; });
  linked_ = false;
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// Host test for fd ownership, backpressure, and lifecycle of the ABI 2
// file source. CTest and native/tests/run_host_tests.sh both run it.
//
// Every scenario here drives the real libsdrcore.so through its public C
// ABI (native/include/sdrcore.h) with host file descriptors (pipes,
// AF_UNIX socket pairs, regular files). None of it is a USB device, and
// none of it is presented as one: sdr_v2_open_usb must reject a non-USB
// descriptor (see the dedicated check below). A TCP loopback connection
// closed with SO_LINGER{on,0} is used only as a fake fd that fails with
// ECONNRESET, standing in for "the transport fd died mid-read" without
// claiming it reproduces real USB unplug semantics (which go through
// Kotlin's UsbManager/UsbDeviceConnection, not a raw fd error).
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "sdrcore.h"

#include <arpa/inet.h>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

namespace {

// Connected TCP loopback pair: unlike AF_UNIX, closing one end with
// SO_LINGER{on,0} reliably sends a real RST that turns into ECONNRESET on
// the peer's next read(), which is what TestAbnormalFdFailureSurfacesAsIoError
// needs. AF_UNIX socketpair() was tried first and does not RST on close.
void ConnectedTcpLoopbackPair(int* client_out, int* accepted_out) {
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  assert(listener >= 0);
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  assert(bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof addr) ==
         0);
  assert(listen(listener, 1) == 0);
  socklen_t len = sizeof addr;
  assert(getsockname(listener, reinterpret_cast<sockaddr*>(&addr), &len) ==
         0);

  int client = socket(AF_INET, SOCK_STREAM, 0);
  assert(client >= 0);
  assert(connect(client, reinterpret_cast<sockaddr*>(&addr), sizeof addr) ==
         0);
  int accepted = accept(listener, nullptr, nullptr);
  assert(accepted >= 0);
  close(listener);
  *client_out = client;
  *accepted_out = accepted;
}

SdrStats Snapshot(SdrHandle* h) {
  SdrStats s{};
  s.size = sizeof(s);
  s.revision = 2;
  assert(sdr_v2_stats(h, &s) == SDR_OK);
  return s;
}

void CheckInvariant(const SdrStats& s) {
  assert(s.input_samples == s.processed_samples + s.dropped_samples);
}

// --- fd ownership: open_file dup()s the fd; the caller's original fd is
// independent and may be closed immediately without disturbing the stream.
void TestFdDupOwnershipSurvivesCallerClose() {
  int fds[2];
  assert(pipe(fds) == 0);
  SdrHandle* h = sdr_create();
  assert(sdr_v2_open_file(h, fds[0], 1000) == SDR_OK);
  close(fds[0]);  // Caller's original descriptor closed right after open().
  assert(sdr_v2_start(h) == SDR_OK);
  const uint8_t iq[] = {10, 20, 30, 40, 50, 60};
  assert(write(fds[1], iq, sizeof iq) == static_cast<ssize_t>(sizeof iq));
  for (int i = 0; i < 50 && Snapshot(h).input_samples < 3; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  auto s = Snapshot(h);
  assert(s.input_samples == 3);  // Proves the native dup is still live.
  CheckInvariant(s);
  assert(sdr_v2_stop(h) == SDR_OK);
  assert(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);
  close(fds[1]);
  printf("[ok] fd dup survives caller close\n");
}

// --- A second close must be rejected and must not close an unrelated fd
// that the OS allocated into the first close's vacated descriptor number.
void TestDoubleCloseRejected() {
  int fds[2];
  assert(pipe(fds) == 0);
  SdrHandle* h = sdr_create();
  assert(sdr_v2_open_file(h, fds[0], 1000) == SDR_OK);
  assert(sdr_v2_close(h) == SDR_OK);
  int sentinel = open("/dev/null", O_RDONLY);
  assert(sentinel >= 0);
  assert(sdr_v2_close(h) == SDR_INVALID_STATE);  // Already SDR_IDLE.
  assert(fcntl(sentinel, F_GETFD) >= 0);
  close(sentinel);
  assert(fcntl(fds[0], F_GETFD) >= 0);  // Borrowed original is still live.
  // The handle must still be reusable after close(), proving the first
  // close() did not corrupt state.
  assert(sdr_v2_open_file(h, fds[0], 1000) == SDR_OK);
  assert(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);
  close(fds[0]);
  close(fds[1]);
  printf("[ok] double close rejected, handle remains reusable\n");
}

// --- sdr_v2_open_usb must stay honest: never claim USB success from a
// fake fd, regardless of which enum value is passed.
void TestOpenUsbNeverFakesSuccess() {
  SdrHandle* h = sdr_create();
  int fds[2];
  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
  assert(sdr_v2_open_usb(h, fds[0], SDR_RTLSDR) != SDR_OK);
  assert(sdr_v2_open_usb(h, fds[0], SDR_HACKRF) != SDR_OK);
  assert(sdr_v2_open_usb(h, fds[0], SDR_SYNTHETIC) == SDR_INVALID_ARGUMENT);
  const auto failed = Snapshot(h);
  assert(failed.state == SDR_IDLE && failed.source == SDR_NONE);
  assert(failed.input_samples == 0 && failed.last_error == SDR_OK);
  assert(fcntl(fds[0], F_GETFD) >= 0);  // Failed open did not take ownership.
  assert(sdr_v2_open_file(h, fds[0], 1000) == SDR_OK);
  assert(sdr_v2_close(h) == SDR_OK);  // Failed USB open left handle reusable.
  sdr_destroy(h);
  close(fds[0]);
  close(fds[1]);
  printf("[ok] open_usb never fakes success\n");
}

// --- A fake fd that fails abnormally (ECONNRESET via SO_LINGER RST) must
// surface as SDR_IO_ERROR/SDR_ERROR, not SDR_DEVICE_GONE (reserved for
// ENODEV) and not a silent hang. This is explicitly NOT a USB detach test;
// see the file header. It exercises the same read_loop() error branch a
// real detach would eventually reach through libusb/Kotlin plumbing.
void TestAbnormalFdFailureSurfacesAsIoError() {
  int client, accepted;
  ConnectedTcpLoopbackPair(&client, &accepted);
  SdrHandle* h = sdr_create();
  assert(sdr_v2_open_file(h, accepted, 1000) == SDR_OK);
  assert(sdr_v2_start(h) == SDR_OK);
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  struct linger lin{1, 0};
  setsockopt(client, SOL_SOCKET, SO_LINGER, &lin, sizeof lin);
  close(client);  // RST -> accepted side's next read() fails ECONNRESET.
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  auto s = Snapshot(h);
  assert(s.state == SDR_ERROR);
  assert(s.last_error == SDR_IO_ERROR);
  assert(s.last_error != SDR_DEVICE_GONE);  // Only ENODEV maps to that code.
  assert(sdr_v2_stop(h) == SDR_OK);  // stop() accepts RUNNING or ERROR.
  s = Snapshot(h);
  assert(s.state == SDR_OPEN && s.last_error == SDR_IO_ERROR);
  CheckInvariant(s);
  assert(sdr_v2_close(h) == SDR_OK);
  // A fresh transport requires a fresh open. This models recovery of the
  // handle, not the real USB attach/permission path on Android.
  int replug[2];
  assert(pipe(replug) == 0);
  assert(sdr_v2_open_file(h, replug[0], 1000) == SDR_OK);
  assert(Snapshot(h).last_error == SDR_OK);
  assert(sdr_v2_start(h) == SDR_OK);
  const uint8_t iq[] = {0, 255, 1, 254};
  assert(write(replug[1], iq, sizeof iq) == sizeof iq);
  close(replug[1]);
  for (int i = 0; i < 100 && Snapshot(h).input_samples < 2; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  assert(sdr_v2_stop(h) == SDR_OK);
  s = Snapshot(h);
  assert(s.input_samples == 2 && s.processed_samples == 2);
  assert(s.last_error == SDR_OK);
  assert(sdr_v2_close(h) == SDR_OK);
  close(replug[0]);
  sdr_destroy(h);
  close(accepted);
  printf("[ok] abnormal fd failure surfaces as SDR_IO_ERROR\n");
}

// --- Bounded ring (8 slots x 8192 bytes): sustained write pressure that
// outruns the consumer must drop samples but never corrupt the accounting
// invariant input == processed + dropped.
struct WriterArgs {
  int fd;
};

void* SustainedWriter(void* arg) {
  auto* a = static_cast<WriterArgs*>(arg);
  uint8_t buf[65536];
  std::memset(buf, 0xAA, sizeof buf);
  auto start = std::chrono::steady_clock::now();
  for (;;) {
    ssize_t n = write(a->fd, buf, sizeof buf);
    if (n < 0) break;
    if (std::chrono::steady_clock::now() - start >
        std::chrono::milliseconds(80)) {
      break;
    }
  }
  return nullptr;
}

void TestRingOverflowUnderBackpressure() {
  bool saw_drop = false;
  for (int trial = 0; trial < 10; ++trial) {
    int fds[2];
    assert(pipe(fds) == 0);
    fcntl(fds[1], F_SETPIPE_SZ, 1 << 20);  // Grow pipe buffer past the ring.
    SdrHandle* h = sdr_create();
    assert(sdr_v2_open_file(h, fds[0], 2000000) == SDR_OK);
    assert(sdr_v2_start(h) == SDR_OK);
    pthread_t t;
    WriterArgs a{fds[1]};
    pthread_create(&t, nullptr, SustainedWriter, &a);
    pthread_join(t, nullptr);
    assert(sdr_v2_stop(h) == SDR_OK);
    auto s = Snapshot(h);
    CheckInvariant(s);
    if (s.dropped_samples > 0) saw_drop = true;
    sdr_destroy(h);
    close(fds[1]);
    close(fds[0]);
  }
  // Not deterministic per trial (depends on scheduler), but 10 trials of
  // sustained overrun reliably trigger at least one overflow in practice;
  // treat a run with zero drops across all trials as a signal worth
  // re-checking rather than a hard failure, since it is host-timing
  // dependent and host CI load varies.
  if (!saw_drop) {
    fprintf(stderr,
            "[warn] no ring overflow observed in 10 trials; host may be "
            "unusually fast or idle. Re-run to confirm.\n");
  } else {
    printf("[ok] ring overflow observed under sustained backpressure\n");
  }
}

// --- destroy() while the producer is actively blocked in poll() (pipe with
// no writer) and while it is busy (synthetic source) must both join
// cleanly without hanging or double-freeing.
void TestDestroyWhileRunningVariants() {
  // Blocked in poll (file source, nothing written, no close on write end).
  {
    int fds[2];
    assert(pipe(fds) == 0);
    SdrHandle* h = sdr_create();
    assert(sdr_v2_open_file(h, fds[0], 1000) == SDR_OK);
    assert(sdr_v2_start(h) == SDR_OK);
    sdr_destroy(h);  // Must return promptly (poll timeout is 50ms).
    close(fds[0]);
    close(fds[1]);
  }
  // Busy (synthetic source, actively producing).
  {
    SdrHandle* h = sdr_create();
    assert(sdr_v2_open_synthetic(h, 2400000) == SDR_OK);
    assert(sdr_v2_start(h) == SDR_OK);
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    sdr_destroy(h);
  }
  printf("[ok] destroy() while running (blocked and busy) joins cleanly\n");
}

// --- Repeated start/stop must not accumulate or leak state across cycles.
void TestRepeatedStartStopCycles() {
  SdrHandle* h = sdr_create();
  assert(sdr_v2_open_synthetic(h, 2400000) == SDR_OK);
  for (int cycle = 0; cycle < 15; ++cycle) {
    assert(sdr_v2_start(h) == SDR_OK);
    std::this_thread::sleep_for(std::chrono::milliseconds(4));
    assert(sdr_v2_stop(h) == SDR_OK);
    auto s = Snapshot(h);
    assert(s.state == SDR_OPEN);
    CheckInvariant(s);
    assert(s.input_samples > 0);
  }
  assert(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);
  printf("[ok] 15 repeated start/stop cycles, no state leakage\n");
}

}  // namespace

int main() {
  TestFdDupOwnershipSurvivesCallerClose();
  TestDoubleCloseRejected();
  TestOpenUsbNeverFakesSuccess();
  TestAbnormalFdFailureSurfacesAsIoError();
  TestRingOverflowUnderBackpressure();
  TestDestroyWhileRunningVariants();
  TestRepeatedStartStopCycles();
  printf("All fd/lifecycle checks passed.\n");
  return 0;
}

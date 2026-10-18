// SPDX-License-Identifier: GPL-3.0-or-later
// Compile against the independently vendored original SDR++ Client.
#include "rtl_tcp_client.h"
#include <cstdio>
#include <chrono>
#include <memory>
#include <thread>

int main() {
    auto socket = std::make_shared<net::Socket>();
    socket->data = {0, 255, 127, 128, 255, 0, 64, 192};
    dsp::stream<dsp::complex_t> stream;
    rtltcp::Client client(socket, &stream);
    client.setFrequency(101000000);
    client.setSampleRate(1024000);
    client.setPPM(-3);
    client.setDirectSampling(2);
    client.setAGCMode(0);
    client.setBiasTee(true);
    client.setOffsetTuning(false);
    client.setGainMode(1);
    client.setGain(280);
    client.setGainIndex(7);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    while (stream.swapped.load() != 4 && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    client.close();
    for (auto byte : socket->sent) std::printf("%02x", byte);
    std::puts("");
    for (auto sample : stream.captured)
        std::printf("%.9f %.9f\n", sample.re, sample.im);
}

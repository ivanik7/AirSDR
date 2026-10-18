// SPDX-License-Identifier: GPL-3.0-or-later
// Same command sequence and IQ bytes as rtltcp_original_trace.cpp.
#include "rtl_tcp_client.h"
#include <array>
#include <cstdio>
#include <vector>

int main() {
    std::vector<uint8_t> sent;
    std::array<uint8_t, 8> data{0, 255, 127, 128, 255, 0, 64, 192};
    size_t offset = 0;
    std::vector<std::array<float, 2>> samples;
    rtltcp::Client client(
        [&](const uint8_t* bytes, size_t size) {
            sent.insert(sent.end(), bytes, bytes + size);
            return 0;
        },
        [&](uint8_t* bytes, size_t capacity) {
            if (offset == data.size()) return -5;
            const size_t n = std::min(capacity, data.size() - offset);
            for (size_t i = 0; i < n; ++i) bytes[i] = data[offset + i];
            offset += n;
            return static_cast<int>(n);
        },
        [&](const float* converted, size_t count) {
            for (size_t i = 0; i < count; ++i)
                samples.push_back({converted[2*i], converted[2*i+1]});
        });
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
    client.worker();
    for (auto byte : sent) std::printf("%02x", byte);
    std::puts("");
    for (auto sample : samples)
        std::printf("%.9f %.9f\n", sample[0], sample[1]);
}

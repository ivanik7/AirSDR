// SPDX-License-Identifier: GPL-3.0-or-later
#include "rtl_tcp_client.h"
#include <algorithm>
#include <array>

namespace rtltcp {
Client::Client(Send send, Receive receive, Samples samples)
    : send_(std::move(send)), receive_(std::move(receive)), samples_(std::move(samples)) {}

int Client::setFrequency(double freq) { return sendCommand(1, freq); }
int Client::setSampleRate(double sr) {
    const int rc = sendCommand(2, sr);
    if (!rc) bufferSize = std::max<size_t>(1, std::min<size_t>(8192, sr / 200.0));
    return rc;
}
int Client::setGainMode(int mode) { return sendCommand(3, mode); }
int Client::setGain(double gain) { return sendCommand(4, gain); }
int Client::setPPM(int ppm) { return sendCommand(5, (uint32_t)ppm); }
int Client::setAGCMode(int mode) { return sendCommand(8, mode); }
int Client::setDirectSampling(int mode) { return sendCommand(9, mode); }
int Client::setOffsetTuning(bool enabled) { return sendCommand(10, enabled); }
int Client::setGainIndex(int index) { return sendCommand(13, index); }
int Client::setBiasTee(bool enabled) { return sendCommand(14, enabled); }

int Client::sendCommand(uint8_t command, uint32_t param) {
    // SDR++: Command cmd = { command, htonl(param) }; sock->send(&cmd, 5).
    const std::array<uint8_t, 5> cmd{command, static_cast<uint8_t>(param >> 24),
        static_cast<uint8_t>(param >> 16), static_cast<uint8_t>(param >> 8),
        static_cast<uint8_t>(param)};
    return send_(cmd.data(), cmd.size());
}

int Client::worker() {
    std::array<uint8_t, 16384> buffer{};
    std::array<float, 16384> converted{};
    size_t carry = 0;
    while (true) {
        // SDR++ reads bufferSize * 2, then maps CU8 to complex float.
        const int count = receive_(buffer.data() + carry,
            std::min(bufferSize * 2, buffer.size() - carry));
        if (count <= 0) return count;
        const size_t total = static_cast<size_t>(count) + carry;
        const size_t scount = total / 2;
        for (size_t i = 0; i < scount; i++) {
            converted[i * 2] = ((double)buffer[i * 2] - 128.0) / 128.0;
            converted[i * 2 + 1] = ((double)buffer[i * 2 + 1] - 128.0) / 128.0;
        }
        if (scount) samples_(converted.data(), scount);
        carry = total % 2;
        if (carry) buffer[0] = buffer[total - 1];
    }
}
}

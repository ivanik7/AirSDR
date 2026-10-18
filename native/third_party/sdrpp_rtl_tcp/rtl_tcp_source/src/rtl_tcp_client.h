// SPDX-License-Identifier: GPL-3.0-or-later
// SDR++ rtl_tcp_client port: dependency substitution only; see PATCHES.md.
#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>

namespace rtltcp {
#pragma pack(push, 1)
struct Command {
    uint8_t cmd;
    uint32_t param;
};
#pragma pack(pop)

// The native adapter owns socket lifecycle, connection deadline and RTL0
// greeting. This class retains SDR++'s command encoding and IQ conversion.
class Client {
public:
    using Send = std::function<int(const uint8_t*, size_t)>;
    using Receive = std::function<int(uint8_t*, size_t)>;
    using Samples = std::function<void(const float*, size_t)>;
    Client(Send send, Receive receive, Samples samples);
    int setFrequency(double freq);
    int setSampleRate(double sr);
    int setGainMode(int mode);
    int setGain(double gain);
    int setPPM(int ppm);
    int setAGCMode(int mode);
    int setDirectSampling(int mode);
    int setOffsetTuning(bool enabled);
    int setGainIndex(int index);
    int setBiasTee(bool enabled);
    // A blocking worker, called from the existing native producer thread.
    // Returns negative on EOF/transport failure; stop is owned by the adapter.
    int worker();
private:
    int sendCommand(uint8_t command, uint32_t param);
    Send send_;
    Receive receive_;
    Samples samples_;
    size_t bufferSize = 2400000 / 200;
};
}

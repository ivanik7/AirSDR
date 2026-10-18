#pragma once
#include <arpa/inet.h>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace net {
class Socket {
public:
    std::vector<uint8_t> sent;
    std::vector<uint8_t> data;
    std::atomic<bool> open{true};
    std::mutex mutex;
    bool isOpen() { return open; }
    void close() { open = false; }
    void send(uint8_t* bytes, size_t size) {
        std::lock_guard<std::mutex> guard(mutex);
        sent.insert(sent.end(), bytes, bytes + size);
    }
    int recv(uint8_t* bytes, size_t capacity, bool) {
        if (!open || data.empty()) return 0;
        const size_t size = std::min(capacity, data.size());
        std::memcpy(bytes, data.data(), size);
        data.erase(data.begin(), data.begin() + size);
        return static_cast<int>(size);
    }
};
inline std::shared_ptr<Socket> connect(std::string, int) {
    return std::make_shared<Socket>();
}
}

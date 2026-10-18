#pragma once
#include <dsp/types.h>
#include <array>
#include <atomic>
#include <vector>
#define STREAM_BUFFER_SIZE 16384
namespace dsp {
namespace buffer {
template <typename T> T* alloc(size_t n) { return new T[n]; }
template <typename T> void free(T* value) { delete[] value; }
}
template <typename T> struct stream {
    std::array<T, STREAM_BUFFER_SIZE> writeBuf{};
    std::vector<T> captured;
    std::atomic<bool> stopped{false};
    std::atomic<size_t> swapped{0};
    bool swap(size_t n) {
        captured.insert(captured.end(), writeBuf.begin(), writeBuf.begin() + n);
        swapped += n;
        return !stopped;
    }
    void stopWriter() { stopped = true; }
    void clearWriteStop() { stopped = false; }
};
}

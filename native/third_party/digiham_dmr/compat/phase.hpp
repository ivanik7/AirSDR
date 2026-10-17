// Thin in-memory transport for the unmodified digiham DMR framing phase.
#pragma once
#include "meta.hpp"
#include <cstddef>

namespace Csdr {
template <typename T> class Reader {
public:
    explicit Reader(const T* p) : ptr_(p) {}
    T* getReadPointer() { return const_cast<T*>(ptr_); }
    void advance(std::size_t n) { ptr_ += n; offset_ += n; }
    std::size_t offset() const { return offset_; }
private:
    const T* ptr_;
    std::size_t offset_ = 0;
};
template <typename T> class Writer {
public:
    explicit Writer(T* p) : ptr_(p) {}
    T* getWritePointer() { return ptr_; }
    void advance(std::size_t n) { offset_ += n; }
    std::size_t offset() const { return offset_; }
private:
    T* ptr_;
    std::size_t offset_ = 0;
};
}

namespace Digiham {
class Phase {
public:
    virtual ~Phase() = default;
    virtual int getRequiredData() = 0;
    virtual Phase* process(Csdr::Reader<unsigned char>*, Csdr::Writer<unsigned char>*) = 0;
    void setMetaCollector(MetaCollector* collector) { meta = collector; }
protected:
    MetaCollector* meta = nullptr;
};
}

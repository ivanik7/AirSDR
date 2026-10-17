// SPDX-License-Identifier: GPL-3.0-or-later
#include "source.hpp"
#include <cassert>

class Buffer final : public Csdr::Writer<unsigned char> {
public:
    size_t writeable() override { return 1; }
    unsigned char* getWritePointer() override { return &sample; }
    void advance(size_t count) override { written += count; }
    unsigned char sample = 0;
    size_t written = 0;
};

int main() {
    Csdr::Source<unsigned char> source;
    assert(!source.hasWriter());
    assert(source.getWriter() == nullptr);
    Buffer buffer;
    source.setWriter(&buffer);
    assert(source.hasWriter());
    assert(source.getWriter() == &buffer);
    *source.getWriter()->getWritePointer() = 42;
    source.getWriter()->advance(1);
    assert(buffer.sample == 42 && buffer.written == 1);
    source.setWriter(nullptr);
    assert(!source.hasWriter());
}

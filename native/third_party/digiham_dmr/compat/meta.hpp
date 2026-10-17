// Native callback adapter for digiham's per-slot dirty metadata collector.
#pragma once
#include <map>
#include <string>
#include <utility>

namespace Digiham {
class MetaWriter {
public:
    virtual ~MetaWriter() = default;
    virtual void sendMetaData(std::map<std::string, std::string> metadata) = 0;
};
class MetaCollector {
public:
    virtual ~MetaCollector() = default;
    void setWriter(MetaWriter* writer) { writer_ = writer; }
protected:
    virtual std::string getProtocol() = 0;
    virtual void sendMetaData() = 0;
    std::map<std::string, std::string> collect() { return {{"protocol", getProtocol()}}; }
    void sendMetaData(std::map<std::string, std::string> data) {
        if (writer_) writer_->sendMetaData(std::move(data));
    }
private:
    MetaWriter* writer_ = nullptr; // Owned by the in-process framing adapter.
};
}

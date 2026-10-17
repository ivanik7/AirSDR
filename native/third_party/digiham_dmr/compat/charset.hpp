// ICU-free ISO-8859-1 to UTF-8 conversion for DMR talker aliases.
#pragma once
#include <string>
namespace Digiham {
class Converter {
public:
    static std::string convertToUtf8(const char* input, size_t length) {
        std::string result;
        result.reserve(length * 2);
        for (size_t i = 0; i < length; ++i) {
            const auto c = static_cast<unsigned char>(input[i]);
            if (c < 0x80) result += static_cast<char>(c);
            else {
                result += static_cast<char>(0xc0 | (c >> 6));
                result += static_cast<char>(0x80 | (c & 0x3f));
            }
        }
        return result;
    }
};
}

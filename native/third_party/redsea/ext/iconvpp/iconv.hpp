/*
Copyright (c) 2011, Yuya Unno
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the Yuya Unno nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#pragma once

#if defined(__ANDROID__) || defined(_WIN32) || defined(__APPLE__)
#include <cstdint>
#include <stdexcept>
#include <string>

// Android Bionic and the Windows CRT have no iconv, and macOS would need an
// extra -liconv. Keep UCS-2 enhanced-RDS conversion; external TMC location
// tables (with arbitrary encodings) are not loaded in this app.
namespace iconvpp {
class converter {
 public:
  converter(const std::string& out, const std::string& in,
            bool = false, size_t = 1024) : encoding_(in) {
    if (out != "UTF-8" || (in != "UCS-2" && in != "UTF-8" && in != "ISO-8859-1"))
      throw std::runtime_error("unsupported character encoding");
  }
  void convert(const std::string& input, std::string& output) const {
    output.clear();
    if (encoding_ == "UTF-8") { output = input; return; }
    auto append = [&output](uint32_t code) {
      if (code < 0x80) output.push_back(static_cast<char>(code));
      else if (code < 0x800) {
        output.push_back(static_cast<char>(0xc0 | (code >> 6)));
        output.push_back(static_cast<char>(0x80 | (code & 0x3f)));
      } else {
        output.push_back(static_cast<char>(0xe0 | (code >> 12)));
        output.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (code & 0x3f)));
      }
    };
    if (encoding_ == "ISO-8859-1") {
      for (unsigned char byte : input) append(byte);
      return;
    }
    if (input.size() & 1) throw std::runtime_error("invalid UCS-2 length");
    for (size_t i = 0; i < input.size(); i += 2) {
      // iconv's UCS-2 uses host byte order; every target here is little-endian.
      const uint32_t code = static_cast<uint8_t>(input[i]) |
                            (static_cast<uint32_t>(static_cast<uint8_t>(input[i + 1])) << 8);
      if (code >= 0xd800 && code <= 0xdfff)
        throw std::runtime_error("invalid UCS-2 surrogate");
      append(code);
    }
  }
 private:
  std::string encoding_;
};
}  // namespace iconvpp
#else
#include <errno.h>
#include <iconv.h>

#include <stdexcept>
#include <string>
#include <vector>

namespace iconvpp {

class converter {
 public:
  converter(const std::string& out_encode,
            const std::string& in_encode,
            bool ignore_error = false,
            size_t buf_size = 1024)
      : ignore_error_(ignore_error),
        buf_size_(buf_size) {
    if (buf_size == 0) {
      throw std::runtime_error("buffer size must be greater than zero");
    }

    iconv_t conv = ::iconv_open(out_encode.c_str(), in_encode.c_str());
    if (conv == (iconv_t)-1) {
      if (errno == EINVAL)
        throw std::runtime_error(
            "not supported from " + in_encode + " to " + out_encode);
      else
        throw std::runtime_error("unknown error");
    }
    iconv_ = conv;
  }

  ~converter() {
    iconv_close(iconv_);
  }

  void convert(const std::string& input, std::string& output) const {
    // copy the string to a buffer as iconv function requires a non-const char
    // pointer.
    std::vector<char> in_buf(input.begin(), input.end());
    char* src_ptr = &in_buf[0];
    size_t src_size = input.size();

    std::vector<char> buf(buf_size_);
    std::string dst;
    while (0 < src_size) {
      char* dst_ptr = &buf[0];
      size_t dst_size = buf.size();
      size_t res = ::iconv(iconv_, &src_ptr, &src_size, &dst_ptr, &dst_size);
      if (res == (size_t)-1) {
        if (errno == E2BIG)  {
          // ignore this error
        } else if (ignore_error_) {
          // skip character
          ++src_ptr;
          --src_size;
        } else {
          check_convert_error();
        }
      }
      dst.append(&buf[0], buf.size() - dst_size);
    }
    dst.swap(output);
  }

 private:
  void check_convert_error() const {
    switch (errno) {
      case EILSEQ:
        throw std::runtime_error("invalid multibyte chars");
      case EINVAL:
        throw std::runtime_error("invalid multibyte chars");
      default:
        throw std::runtime_error("unknown error");
    }
  }

  iconv_t iconv_;
  bool ignore_error_;
  const size_t buf_size_;
};

}  // namespace iconvpp
#endif  // __ANDROID__

// SPDX-License-Identifier: GPL-3.0-or-later
// COMPILE SHIM, oracle only (tool/dmr_voice_oracle). Stands in for
// codecserver's include/session.hpp + generated proto headers so that the
// PRISTINE codecserver-softmbe 66397fcf src/softmbesession.cpp compiles
// without protobuf. Only the members softmbesession.cpp touches exist.
// Nothing here is linked into the app.
#pragma once

#include <unistd.h>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <map>
#include <string>
#include <vector>

namespace CodecServer {
namespace proto {

class FramingHint {
 public:
  void set_channelbits(int v) { channelbits = v; }
  void set_channelbytes(int v) { channelbytes = v; }
  void set_audiosamples(int v) { audiosamples = v; }
  void set_audiobytes(int v) { audiobytes = v; }
  int channelbits = 0, channelbytes = 0, audiosamples = 0, audiobytes = 0;
};

enum Settings_Direction { Settings_Direction_ENCODE = 0, Settings_Direction_DECODE = 1 };

class Settings {
 public:
  const std::map<std::string, std::string>& args() const { return args_; }
  const std::vector<int>& directions() const { return directions_; }
  std::map<std::string, std::string> args_;
  std::vector<int> directions_;
};

class Request {};

}  // namespace proto

class Session {
 public:
  virtual ~Session() = default;
  virtual void start() {}
  virtual void decode(char* input, size_t size) = 0;
  virtual void encode(char* input, size_t size) = 0;
  virtual size_t read(char* output) = 0;
  virtual void end() {}
  virtual proto::FramingHint* getFraming() { return nullptr; }
  virtual void renegotiate(proto::Settings settings) {}
};

}  // namespace CodecServer

using namespace CodecServer::proto;

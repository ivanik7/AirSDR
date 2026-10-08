// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace sdrcore::rds {

// MPX-only adapter around redsea 1.3.1. Owned exclusively by the DSP worker;
// no tuner, file descriptor, CLI, audio output, or Dart sample path.
class Sink {
 public:
  Sink();
  ~Sink();
  Sink(const Sink&) = delete;
  Sink& operator=(const Sink&) = delete;
  void configure(uint32_t input_rate_hz, bool rbds);
  void reset();
  void process(const float* mpx, size_t count);
  bool take_group(std::string& json);
  bool synced() const;
 private:
  struct State;
  std::unique_ptr<State> state_;
};

}  // namespace sdrcore::rds

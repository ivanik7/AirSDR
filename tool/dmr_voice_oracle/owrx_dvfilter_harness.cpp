// SPDX-License-Identifier: GPL-3.0-or-later
// Oracle harness: PRISTINE digiham-plus beec7822 DigitalVoiceFilter over an
// int16 stream (stdin -> stdout), in 160-sample blocks as MbeSynthesizer
// delivers them. Equivalent to digiham's `digitalvoice_filter` CLI without
// its CLI/ringbuffer glue.
#include "digitalvoice_filter.hpp"

#include <cstdio>

int main() {
  Digiham::DigitalVoice::DigitalVoiceFilter filter;
  short in[160], out[160];
  size_t n;
  while ((n = std::fread(in, sizeof(short), 160, stdin)) > 0) {
    filter.process(in, out, n);
    std::fwrite(out, sizeof(short), n, stdout);
  }
  return 0;
}

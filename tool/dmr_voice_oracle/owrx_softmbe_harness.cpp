// SPDX-License-Identifier: GPL-3.0-or-later
// Oracle harness: runs PRISTINE codecserver-softmbe 66397fcf softmbeSession
// (DMR = renegotiate index 33 -> AMBE_3600x2450) on 9-byte frames from stdin
// and writes the 160-sample int16 blocks to stdout, exactly what codecserver
// would return to digiham's MbeSynthesizer. Usage: owrx_softmbe_harness SEED
// (srand(SEED) first: mbelib's unvoiced synthesis uses rand()).
#include "softmbesession.hpp"

#include <cstdio>
#include <cstdlib>
#include <iostream>

int main(int argc, char** argv) {
  // softmbe logs ("renegotiating: ...") on std::cout; keep stdout pure PCM.
  std::cout.rdbuf(std::cerr.rdbuf());
  std::srand(argc > 1 ? static_cast<unsigned>(std::atoi(argv[1])) : 1u);
  softmbe::softmbeSession session;
  CodecServer::proto::Settings settings;
  settings.args_["index"] = "33";
  settings.directions_.push_back(Settings_Direction_DECODE);
  session.renegotiate(settings);
  char frame[9];
  char pcm[320];
  while (std::fread(frame, 1, 9, stdin) == 9) {
    session.decode(frame, 9);
    const size_t n = session.read(pcm);
    std::fwrite(pcm, 1, n, stdout);
  }
  return 0;
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Replays an interleaved complex-f32 IQ file through the embedded lorarx
// (lorarx_embed_*) with an exact upstream argv, writing every JSON line to
// stdout. Used by tests/lorarx_parity.sh to compare against the unmodified
// vendored oracle on the same file; the oracle discards a trailing partial
// 4096-frame block (inreform() needs a full block), so this tool does too.
//
// Usage: sdrcore_lorarx_replay <iq.f32> <lorarx args...>
//        sdrcore_lorarx_replay --restart <iq.f32> <lorarx args...>
//   --restart runs start/feed/clear twice in one process and requires both
//   passes to produce identical output (global state is fully reset).
#include "lorarx_embed.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static std::string g_out;

extern "C" void lorarx_embed_emit(const char* json, size_t length) {
  g_out.append(json, length);
}

static bool run(const char* path, int argc, char** argv) {
  g_out.clear();
  if (!lorarx_embed_start(argc, argv)) {
    std::fprintf(stderr, "lorarx_embed_start failed\n");
    return false;
  }
  FILE* f = std::fopen(path, "rb");
  if (!f) {
    std::perror(path);
    return false;
  }
  std::vector<float> block(2 * LORARX_EMBED_BLOCK_FRAMES);
  while (std::fread(block.data(), sizeof(float), block.size(), f) == block.size()) {
    if (!lorarx_embed_block(block.data(), LORARX_EMBED_BLOCK_FRAMES)) {
      std::fprintf(stderr, "lorarx_embed_block failed\n");
      std::fclose(f);
      return false;
    }
  }
  std::fclose(f);
  lorarx_embed_clear();
  return true;
}

int main(int argc, char** argv) {
  bool restart = false;
  int first = 1;
  if (argc > 1 && std::strcmp(argv[1], "--restart") == 0) {
    restart = true;
    first = 2;
  }
  if (argc < first + 2) {
    std::fprintf(stderr, "usage: %s [--restart] <iq.f32> <lorarx args...>\n", argv[0]);
    return 2;
  }
  const char* path = argv[first];
  // Upstream argv[0] is the program name; pass "lorarx" followed by the args.
  std::vector<std::string> args{"lorarx"};
  for (int n = first + 1; n < argc; ++n) args.emplace_back(argv[n]);
  auto argv_of = [&args]() {
    std::vector<char*> out;
    for (auto& a : args) out.push_back(a.data());
    out.push_back(nullptr);
    return out;
  };
  auto a1 = argv_of();
  if (!run(path, static_cast<int>(args.size()), a1.data())) return 1;
  const std::string first_pass = g_out;
  if (restart) {
    auto a2 = argv_of();
    if (!run(path, static_cast<int>(args.size()), a2.data())) return 1;
    if (g_out != first_pass) {
      std::fprintf(stderr, "restart: second pass differs from first\n");
      return 1;
    }
  }
  std::fwrite(first_pass.data(), 1, first_pass.size(), stdout);
  return 0;
}

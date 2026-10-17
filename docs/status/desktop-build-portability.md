# Desktop build portability fixes

## Changes

- Exclude the unused upstream csdr SSTV mirrored ringbuffer from all builds.
  It calls Linux-only `mremap`; the SSTV adapter supplies its own reader and
  writer buffers. No decoder, receiver, ABI or upstream source changes.
- Use an absolute checkout-root toolchain path in the Windows CI job.
  CMake resolves relative toolchain paths against its build and source
  directories, not the shell working directory. Keep the existing Ninja
  installation step. Update the documented commands as well.
- Add two regression checks to `test/native/desktop_portability_test.dart`.

## Verification (macOS arm64, 2026-10-17)

CMake executable: `/Users/ivan/Library/Android/sdk/cmake/3.22.1/bin/cmake`.
The adjacent `ctest` executable was used.

| Command | Result |
| --- | --- |
| `flutter test test/native/desktop_portability_test.dart` before fixes | Both new tests fail (RED). |
| `flutter build apk --debug` | Pass; all three native ABIs compiled. |
| `flutter analyze` | No issues. |
| `flutter test --concurrency=1` | 510 passed, 17 skipped; includes both new regression checks (GREEN). |
| `cmake -S native -B build/native-macos -DCMAKE_BUILD_TYPE=Release` | Pass. |
| `cmake --build build/native-macos --target sdrcore -j4` | Pass; links `libsdrcore.dylib`. |
| `cmake --build build/native-macos -j4` | Pass. |
| `ctest --test-dir build/native-macos --output-on-failure -j4` | 8/8 passed. |
| `cmake -S native -B build/windows-toolchain-probe -DCMAKE_TOOLCHAIN_FILE="$PWD/native/cmake/llvm-mingw-x86_64.cmake"` | Toolchain is found and loaded; configuration then stops because llvm-mingw compilers are not installed on this host. |

Full Windows cross-compilation, macOS x86_64/universal packaging, Linux
hardware reception, Android emulator behavior and audible audio are unverified.
No device-visible receiver or UI behavior was changed. The vendored files and
license notices remain intact; no dependency was added.

## Integration

Task branch: `feat/desktop-build-portability`, worktree
`.worktrees/desktop-build-portability`.

The main checkout has unrelated modifications in
`linux/flutter/generated_plugins.cmake` and
`windows/flutter/generated_plugins.cmake`. Per AGENTS.md, it must be clean
before merging. No merge or push was performed; master remains at `fe50097`.

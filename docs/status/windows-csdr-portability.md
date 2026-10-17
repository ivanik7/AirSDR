# Windows embedded decoder portability

## Changes

- Both vendored CSDR copies exclude the unused POSIX TCP source on Windows.
  In-process Source/Writer behavior and decoder algorithms are unchanged;
  Linux, Android and macOS retain the upstream TCP implementation.
- dump1090 selects Winsock headers on Windows instead of sys/ioctl.h. The
  existing WSADATA field is retained; no network backend or stub is added.
- SSTV UTC timestamps use the Windows gmtime_s signature on Windows and
  retain gmtime_r elsewhere. Timestamp format is unchanged.
- Two portable CTest executables exercise Source writer assignment, sample
  delivery and detachment, separately for the DMR and SSTV vendor copies.
- Upstream licenses are preserved. Exact vendor diffs and rationale are
  recorded in windows-source.patch / windows-header.patch and provenance.

The lead implemented CSDR, timestamps, regression tests and integration.
A delegated agent implemented the dump1090 header/provenance patch in a
separate file ownership boundary. No public ABI or UI contract changed.

## Verification (macOS arm64 host, 2026-10-18)

CMake/CTest/Ninja come from Android SDK CMake 3.22.1. The Windows toolchain
is the official llvm-mingw 20261006 UCRT macOS universal release, extracted
under /private/tmp/llvm-mingw-20261006-ucrt-macos-universal.

| Command/check | Result |
| --- | --- |
| Cross-compile tests/csdr_source_test.cpp against each original Source header | RED: both fail with missing arpa/inet.h. |
| Initial full Windows cross-build after CSDR patch | RED: dump1090 sys/ioctl.h; subsequent core-object compilation exposes gmtime_r. |
| `cmake -S native -B build/native-windows -G Ninja -DCMAKE_MAKE_PROGRAM=/Users/ivan/Library/Android/sdk/cmake/3.22.1/bin/ninja -DCMAKE_TOOLCHAIN_FILE="$PWD/native/cmake/llvm-mingw-x86_64.cmake" -DLLVM_MINGW_ROOT=/private/tmp/llvm-mingw-20261006-ucrt-macos-universal -DCMAKE_BUILD_TYPE=Release` | Pass. |
| `cmake --build build/native-windows -j4` | GREEN: full build, sdrcore.dll and test EXEs, including both Source regression tests. |
| `llvm-objdump -f` on both Source test EXEs | Windows x86_64 COFF confirmed; not executed. |
| `llvm-objdump -p build/native-windows/sdrcore.dll` | Imports only KERNEL32 and UCRT system DLLs; no extra compiler runtime DLL required. |
| `cmake -S native -B build/native-macos -DCMAKE_BUILD_TYPE=Release` | Pass. |
| `cmake --build build/native-macos -j4` | Pass after all fixes. |
| `ctest --test-dir build/native-macos --output-on-failure -j4` | 10/10 pass after all fixes. |
| `flutter build apk --debug` | Pass after all fixes; native core built for all three Android ABIs. |
| `flutter analyze` | No issues. |
| `flutter test --concurrency=1` | 510 pass, 17 skipped. |

No Windows runtime, Flutter Windows packaging, Linux USB receiver or Android
emulator QA was performed. No UI or device-visible receiver behavior changed;
audible audio is unverified. Windows compilation is now verified rather
than inferred from individual header fixes.

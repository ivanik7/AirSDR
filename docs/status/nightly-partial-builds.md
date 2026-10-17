# Nightly releases with partial platform builds

## Changes

- Nightly requires successful shared tests and at least one successful platform
  build. Failed Android/Linux/macOS/Windows builds and Linux install checks no
  longer prevent publishing available artifacts. Cancellation still prevents
  publication. Tagged-release build gates are unchanged.
- Both release jobs stage version-free packages in a fresh temporary directory,
  rather than the repository's existing assets directory. This prevents
  assets/fonts from being passed to gh release create as an attachment.
- The previous nightly is not deleted if no recognized packages were downloaded.
- Add executable regression coverage to the CI test job.

## Verification (2026-10-18)

`python3 test/ci/release_workflow_test.py`: RED before the workflow changes
(Android/install-check failures blocked publication; both release shell steps
attempted to upload assets/fonts). GREEN after changes: 5 tests pass.

The tests evaluate the workflow's actual nightly condition and run its actual
release shell steps with fixture artifacts and a recording gh replacement.
They cover platform failures, dependent skipped Linux checks, cancellation,
non-master events, no successful builds, empty downloads, and a partial APK
artifact set alongside the repository-style fonts directory.

`git diff --check`: pass.

No live GitHub release was created during local testing. App/native code is
unchanged by this task; its preceding Windows portability commit passed full
Windows cross-compilation, 10 macOS native tests, debug APK generation,
flutter analyze and 510 Flutter tests (17 skipped). The post-merge master
Flutter checks also passed before this CI-only change.

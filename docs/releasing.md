# Versions and releases

## Single source of truth

`version: X.Y.Z` in `pubspec.yaml` is the only place the version is written
by hand. It names the release the current commit belongs to: after `1.2.0`
is released, master keeps saying `1.2.0` until the next release bumps it.

`tool/version.sh` derives everything else from it and from git:

| Key | Release (HEAD tagged `vX.Y.Z`) | Any other commit |
|---|---|---|
| `FULL_VERSION` | `1.2.0` | `1.2.0+git263.g2d91fce7` |
| `ARCH_VERSION` | `1.2.0` | `1.2.0.r263.g2d91fce7` |
| `BUILD_NUMBER` | commit count | commit count |

`263` is the commit count of HEAD and `2d91fce7` its short id. Dev versions
sort after the release they are based on (`1.2.0 < 1.2.0+git263...`) in
dpkg, rpm and pacman, so upgrading from a release to a master build and then
to the next release works.

Where the values go (CI, `.github/workflows/ci.yml`):

- Android: `--build-name FULL_VERSION` (versionName) and
  `--build-number BUILD_NUMBER` (versionCode). The commit count only grows on
  master, so every CI APK can be installed over an older one, provided both
  are signed with the same key (see ci.md, Signing).
- Linux: deb, rpm and tar.gz use `FULL_VERSION`, the Arch package uses
  `ARCH_VERSION` (pkgver allows no `+`), see linux-packages.md.
- Artifact names: `AirSDR-<FULL_VERSION>-...`.

`tool/version.sh` fails if HEAD has a `v*` tag that differs from pubspec.yaml,
and in a shallow clone (CI checks out with `fetch-depth: 0`).

## Cutting a release

From the main checkout on a clean master that matches origin/master:

    tool/release.sh 1.2.0          # bump, check, merge, tag locally
    git push origin master && git push origin v1.2.0

or `tool/release.sh 1.2.0 --push` to push both. The script:

1. refuses a version lower than pubspec.yaml or an existing tag;
2. commits `Release 1.2.0` (only the pubspec.yaml bump) on
   `feat/release-1-2-0` in `.worktrees/release-1-2-0`, after
   `flutter analyze` and `flutter test` pass there;
3. fast-forward merges that branch into master and removes the worktree;
4. creates the annotated tag `v1.2.0` on master.

If pubspec.yaml already says the requested version (for example the first
release), it only tags master.

Pushing the tag runs CI for the tag. When the test, Android and Linux jobs
pass, the `release` job checks the tag against pubspec.yaml and publishes a
GitHub release `AirSDR v1.2.0` with notes generated from the commits since
the previous tag. Its files have version-free names, so
`releases/latest/download/<file>` links keep working (docs/ci.md). Every
push to master also refreshes the `nightly` pre-release the same way.

Version numbers follow semantic versioning: patch for fixes, minor for new
features, major for incompatible changes to saved data or settings.

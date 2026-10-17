#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prints the version of the checked-out commit as KEY=value lines, for CI
# ($GITHUB_OUTPUT) and packaging scripts. See docs/releasing.md.
#
#   VERSION       X.Y.Z from pubspec.yaml (the release this commit belongs to)
#   BUILD_NUMBER  commit count of HEAD; Android versionCode, always increasing
#   COMMIT        8-character commit id
#   RELEASE       true when HEAD carries the tag vX.Y.Z, else false
#   FULL_VERSION  X.Y.Z for a release, X.Y.Z+git<N>.g<sha> otherwise
#                 (APK versionName, deb/rpm/tar.gz versions, artifact names)
#   ARCH_VERSION  X.Y.Z for a release, X.Y.Z.r<N>.g<sha> otherwise (Arch
#                 pkgver allows no '+')
#
# Needs the full git history (actions/checkout with fetch-depth: 0).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml)"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "pubspec.yaml version '$version' is not X.Y.Z" >&2
  exit 1
fi

if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  echo "shallow clone: BUILD_NUMBER needs the full history (fetch-depth: 0)" >&2
  exit 1
fi

count="$(git rev-list --count HEAD)"
sha="$(git rev-parse --short=8 HEAD)"

release=false
for tag in $(git tag --points-at HEAD --list 'v*'); do
  if [ "$tag" = "v$version" ]; then
    release=true
  else
    echo "HEAD is tagged $tag but pubspec.yaml says $version" >&2
    exit 1
  fi
done

if [ "$release" = true ]; then
  full="$version"
  arch="$version"
else
  full="$version+git$count.g$sha"
  arch="$version.r$count.g$sha"
fi

cat <<EOF
VERSION=$version
BUILD_NUMBER=$count
COMMIT=$sha
RELEASE=$release
FULL_VERSION=$full
ARCH_VERSION=$arch
EOF

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Cuts release X.Y.Z. See docs/releasing.md.
#
# Usage: tool/release.sh X.Y.Z [--push]
#
# Run from the main checkout on a clean, up-to-date master. Following the
# AGENTS.md git rules, the version bump is committed on feat/release-X-Y-Z in
# .worktrees/release-X-Y-Z, checked with `flutter analyze` and `flutter test`,
# and fast-forward merged into master. master then gets the annotated tag
# vX.Y.Z. With --push, master and the tag are pushed to origin; the tag starts
# the CI release job. Without --push the script prints the push commands.
set -euo pipefail

usage() { echo "usage: $0 X.Y.Z [--push]" >&2; exit 2; }
die() { echo "release: $*" >&2; exit 1; }

[ $# -ge 1 ] || usage
new="$1"
push=false
[ "${2:-}" = --push ] && push=true
[ $# -le 2 ] || usage
[[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$new' is not X.Y.Z"

root="$(git rev-parse --show-toplevel)"
cd "$root"
[ "$(git rev-parse --git-common-dir)" = .git ] || die "run from the main checkout, not a worktree"
[ "$(git branch --show-current)" = master ] || die "master is not checked out"
[ -z "$(git status --porcelain)" ] || die "the main checkout is not clean"

tag="v$new"
git fetch --quiet --tags origin master
[ "$(git rev-parse master)" = "$(git rev-parse origin/master)" ] ||
  die "master differs from origin/master; pull or push first"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag $tag already exists"

current="$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml)"
lowest="$(printf '%s\n%s\n' "$current" "$new" | sort -V | head -n1)"
[ "$lowest" = "$current" ] || die "$new is lower than the current version $current"

if [ "$new" != "$current" ]; then
  name="release-${new//./-}"
  branch="feat/$name"
  wt="$root/.worktrees/$name"
  git rev-parse -q --verify "refs/heads/$branch" >/dev/null && die "branch $branch already exists"

  git worktree add -q "$wt" -b "$branch" master
  sed -i.bak "s/^version: .*/version: $new/" "$wt/pubspec.yaml"
  rm "$wt/pubspec.yaml.bak"
  grep -q "^version: $new$" "$wt/pubspec.yaml" || die "could not update pubspec.yaml"

  echo "== Checking $branch"
  (cd "$wt" && flutter pub get >/dev/null && flutter analyze && flutter test)

  git -C "$wt" commit -q -am "Release $new"
  git merge -q --ff-only "$branch"
  git worktree remove "$wt"
else
  echo "pubspec.yaml already says $new; tagging master as is"
fi

git tag -a "$tag" -m "AirSDR $new"
tool/version.sh

if [ "$push" = true ]; then
  git push origin master
  git push origin "$tag"
  echo "Pushed $tag; the CI release job publishes the GitHub release."
else
  echo
  echo "Tagged $tag locally. Publish with:"
  echo "  git push origin master && git push origin $tag"
fi

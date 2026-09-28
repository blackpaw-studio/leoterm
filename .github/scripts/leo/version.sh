#!/usr/bin/env bash
# Compute Leo version metadata for the checked-out commit and append it to
# $GITHUB_OUTPUT (or stdout).
#
# Outputs:
#   version        Full descriptive version: the release tag's X.Y.Z, or
#                   <last release X.Y.Z or 0.0.0>-dev.<shortsha> otherwise.
#                   Feeds zig's -Dversion-string and the artifact/DMG name;
#                   unique per commit so dev builds never collide.
#   short_version  Strictly numeric X.Y.Z (Apple's CFBundleShortVersionString
#                   format). Always the release tag's version, or the last
#                   release's version for dev builds -- never a "-dev.sha"
#                   suffix. Dev/commit identity belongs in GhosttyCommit
#                   (see build-app.sh), not in this field.
#   build          `git rev-list --count HEAD`. Monotonically increasing
#                   ONLY on main: it is the count of commits reachable from
#                   HEAD, so a branch that has diverged from main (extra
#                   commits, or commits main doesn't have) can produce a
#                   build number lower than, equal to, or out of order with
#                   another branch's. Fine for CFBundleVersion on release
#                   builds (which are tagged commits on main) and adequate
#                   for one-off dev builds, but never assume it orders two
#                   arbitrary builds.
#   commit         `git rev-parse --short=9 HEAD`.
#   commit_long    `git rev-parse HEAD`.
#
# A release tag (leo-vX.Y.Z) in $RELEASE_TAG must point at the checked-out
# commit, and that commit must be an ancestor of origin/main -- releases only
# ship commits that have landed on main.
set -euo pipefail

out="${GITHUB_OUTPUT:-/dev/stdout}"
tag="${RELEASE_TAG:-}"
commit_long="$(git rev-parse HEAD)"
commit="$(git rev-parse --short=9 HEAD)"
build="$(git rev-list --count HEAD)"

# The highest leo-v* tag by semver, not `git describe` (which picks the
# nearest tag by commit-graph distance, not the highest version).
last_release="$(git tag --list 'leo-v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
last_release="${last_release#leo-v}"

if [[ -n "$tag" ]]; then
  if [[ ! "$tag" =~ ^leo-v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo "::error::Release tag must look like leo-vX.Y.Z" >&2
    exit 1
  fi
  version="${BASH_REMATCH[1]}"
  short_version="$version"
  if [[ "$(git rev-parse "refs/tags/${tag}^{commit}")" != "$commit_long" ]]; then
    echo "::error::Tag ${tag} does not point at the checked-out commit" >&2
    exit 1
  fi
  git fetch --quiet --no-tags origin main >/dev/null 2>&1 || true
  if ! git merge-base --is-ancestor "$commit_long" origin/main 2>/dev/null; then
    echo "::error::Tag ${tag} (${commit_long}) is not an ancestor of origin/main; releases must point at a commit that has landed on main" >&2
    exit 1
  fi
else
  short_version="${last_release:-0.0.0}"
  # Semver forbids numeric prerelease identifiers with leading zeros, which
  # an all-digit short SHA can produce; prefix those with "g" like git describe.
  suffix="$commit"
  [[ "$suffix" =~ ^[0-9]+$ ]] && suffix="g${suffix}"
  version="${short_version}-dev.${suffix}"
fi

{
  echo "version=${version}"
  echo "short_version=${short_version}"
  echo "build=${build}"
  echo "commit=${commit}"
  echo "commit_long=${commit_long}"
} >> "$out"

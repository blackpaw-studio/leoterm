#!/usr/bin/env bash
# Compute Leo version metadata for the checked-out commit and append it to
# $GITHUB_OUTPUT (or stdout). A release tag (leo-vX.Y.Z) in $RELEASE_TAG sets
# the version; otherwise it is <latest leo-v tag or 0.0.0>-dev.<shortsha>.
# The build number is the commit count, which increases monotonically on main.
set -euo pipefail

out="${GITHUB_OUTPUT:-/dev/stdout}"
tag="${RELEASE_TAG:-}"
commit_long="$(git rev-parse HEAD)"
commit="$(git rev-parse --short=9 HEAD)"
build="$(git rev-list --count HEAD)"

if [[ -n "$tag" ]]; then
  if [[ ! "$tag" =~ ^leo-v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo "::error::Release tag must look like leo-vX.Y.Z" >&2
    exit 1
  fi
  version="${BASH_REMATCH[1]}"
  if [[ "$(git rev-parse "refs/tags/${tag}^{commit}")" != "$commit_long" ]]; then
    echo "::error::Tag ${tag} does not point at the checked-out commit" >&2
    exit 1
  fi
else
  base="$(git describe --tags --abbrev=0 --match 'leo-v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
  base="${base#leo-v}"
  # Semver forbids numeric prerelease identifiers with leading zeros, which
  # an all-digit short SHA can produce; prefix those with "g" like git describe.
  suffix="$commit"
  [[ "$suffix" =~ ^[0-9]+$ ]] && suffix="g${suffix}"
  version="${base:-0.0.0}-dev.${suffix}"
fi

{
  echo "version=${version}"
  echo "build=${build}"
  echo "commit=${commit}"
  echo "commit_long=${commit_long}"
} >> "$out"

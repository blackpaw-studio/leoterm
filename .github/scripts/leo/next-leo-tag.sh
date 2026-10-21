#!/usr/bin/env bash
# Print the next patch release tag (leo-vX.Y.Z) for a commit, or nothing if
# that commit is already released.
# Usage: next-leo-tag.sh [COMMIT]     (default HEAD; run inside the git repo,
#                                      with tags fetched)
# The next tag is the highest existing strict leo-vX.Y.Z tag by semver, patch
# + 1. Suffixed tags (leo-v1.0.0-rc1) and other prefixes are not release tags.
# Exit 0 with a tag on stdout, or exit 0 with empty stdout when a release tag
# already points at COMMIT. Exit 1 when there is no release tag to count from,
# COMMIT is not a commit, or COMMIT is not a descendant of the latest release
# (tagging it would roll the version back).
set -euo pipefail

commit_arg="${1:-HEAD}"
[[ "$commit_arg" != -* ]] || { echo "next-leo-tag: refusing option-like argument '$commit_arg'" >&2; exit 1; }
commit="$(git rev-parse --verify --quiet "$commit_arg^{commit}")" \
  || { echo "next-leo-tag: '$commit_arg' is not a commit" >&2; exit 1; }

readonly tag_re='^leo-v([0-9]+)\.([0-9]+)\.([0-9]+)$'

# Every release tag, newest semver first.
tags=()
while IFS= read -r t; do
  [[ "$t" =~ $tag_re ]] && tags+=("$t")
done < <(git tag --list 'leo-v*' --sort=-v:refname)

[[ "${#tags[@]}" -gt 0 ]] \
  || { echo "next-leo-tag: no leo-vX.Y.Z tag to count from; create the first release by hand" >&2; exit 1; }

for t in "${tags[@]}"; do
  if [[ "$(git rev-parse "$t^{commit}")" == "$commit" ]]; then
    echo "next-leo-tag: $t already points at $commit; nothing to tag" >&2
    exit 0
  fi
done

# Never tag behind the newest release: retrying an older failed run after a
# newer release would hand an older commit a higher version.
latest_commit="$(git rev-parse "${tags[0]}^{commit}")"
git merge-base --is-ancestor "$latest_commit" "$commit" \
  || { echo "next-leo-tag: $commit is not a descendant of ${tags[0]} ($latest_commit); refusing to tag behind the latest release" >&2; exit 1; }

[[ "${tags[0]}" =~ $tag_re ]]
echo "leo-v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((10#${BASH_REMATCH[3]} + 1))"

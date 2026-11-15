#!/usr/bin/env bash
# Close the open bundled-leo bump PRs that a newer bump supersedes.
# Usage: close-superseded-bumps.sh NEW_PR NEW_VERSION
#   NEW_PR       number of the bump PR that was just opened or updated
#   NEW_VERSION  bare X.Y.Z that PR bumps to
# Env:
#   GH           gh command (default: gh); a test seam. GH_TOKEN / GH_REPO
#                are read by gh itself.
#
# Closes every other open PR whose head branch is bump/leo-<X.Y.Z> in this
# repository and whose version is lower than NEW_VERSION, with the comment
# "Superseded by #NEW_PR". Everything else is left alone: higher or equal
# versions, non-bump PRs, bump branches whose version is not strict X.Y.Z, and
# PRs from forks. Branches are never deleted.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: close-superseded-bumps.sh NEW_PR NEW_VERSION" >&2; exit 2; }
new_pr="$1"
new_version="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gh_cmd="${GH:-gh}"
readonly branch_prefix=bump/leo-

[[ "$new_pr" =~ ^[0-9]+$ ]] || { echo "close-superseded-bumps: '$new_pr' is not a PR number" >&2; exit 2; }
# semver-gt.sh exits 2 only for input that is not strict X.Y.Z.
semver_rc=0
"$here/semver-gt.sh" "$new_version" 0.0.0 > /dev/null 2>&1 || semver_rc=$?
[[ "$semver_rc" -ne 2 ]] || { echo "close-superseded-bumps: '$new_version' is not X.Y.Z" >&2; exit 2; }

prs="$("$gh_cmd" pr list --state open --limit 200 --json number,headRefName,isCrossRepository)"

# One "<number> <version>" per same-repo bump PR other than the new one. The
# strict X.Y.Z match here also keeps anything odd out of the loop below.
candidates="$(jq -r --argjson new "$new_pr" --arg prefix "$branch_prefix" '
  .[]
  | select(.isCrossRepository == false and .number != $new)
  | select(.headRefName | startswith($prefix))
  | (.headRefName | ltrimstr($prefix)) as $version
  | select($version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
  | "\(.number) \($version)"' <<< "$prs")"

while read -r number version; do
  [[ -n "$number" ]] || continue
  if "$here/semver-gt.sh" "$new_version" "$version"; then
    echo "close-superseded-bumps: closing #$number (leo $version < $new_version)"
    "$gh_cmd" pr close "$number" --comment "Superseded by #$new_pr"
  fi
done <<< "$candidates"

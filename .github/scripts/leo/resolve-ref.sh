#!/usr/bin/env bash
# Validate a user-supplied build ref and print the git ref to check out.
#   ""          -> $DEFAULT_SHA (the triggering commit)
#   "123"       -> refs/pull/123/head, but only if PR #123's head repo is
#                  this repo -- a fork PR is refused, never built.
#   <hex sha>   -> the sha
#   <branch>    -> refs/heads/<branch>
#   leo-vX.Y.Z  -> refs/tags/leo-vX.Y.Z
# The ref arrives via $REF_INPUT (never interpolated into the script).
# Env: GITHUB_REPOSITORY, GH_TOKEN/GH_HOST as needed by `gh api` (only used
# for the PR-number form).
set -euo pipefail

ref="${REF_INPUT:-}"

if [[ -z "$ref" ]]; then
  echo "${DEFAULT_SHA:?DEFAULT_SHA is required when REF_INPUT is empty}"
elif [[ "$ref" =~ ^[0-9]{1,7}$ ]]; then
  : "${GITHUB_REPOSITORY:?}"
  head_repo="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${ref}" --jq '.head.repo.full_name // ""' 2>/dev/null || true)"
  if [[ -z "$head_repo" ]]; then
    echo "::error::Could not look up PR #${ref} in ${GITHUB_REPOSITORY}" >&2
    exit 1
  fi
  if [[ "$head_repo" != "$GITHUB_REPOSITORY" ]]; then
    echo "::error::PR #${ref}'s head repo ($head_repo) is not $GITHUB_REPOSITORY; refusing to build a fork PR" >&2
    exit 1
  fi
  echo "refs/pull/${ref}/head"
elif [[ "$ref" == refs/pull/* || "$ref" == pull/* ]]; then
  echo "::error::Raw pull refs are not accepted; pass the PR number instead" >&2
  exit 1
elif [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
  echo "$ref"
elif [[ "$ref" =~ ^leo-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "refs/tags/${ref}"
elif [[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$ ]] \
  && [[ "$ref" != *..* && "$ref" != *//* && "$ref" != */ && "$ref" != *.lock ]]; then
  echo "refs/heads/${ref}"
else
  echo "::error::Invalid ref '${ref//[^A-Za-z0-9._\/-]/?}': expected a SHA, branch, tag, or PR number" >&2
  exit 1
fi

#!/usr/bin/env bash
# Validate a user-supplied build ref and print the git ref to check out.
#   ""          -> $DEFAULT_SHA (the triggering commit)
#   "123"       -> refs/pull/123/head
#   <hex sha>   -> the sha
#   <branch>    -> refs/heads/<branch>
#   leo-vX.Y.Z  -> refs/tags/leo-vX.Y.Z
# The ref arrives via $REF_INPUT (never interpolated into the script).
set -euo pipefail

ref="${REF_INPUT:-}"

if [[ -z "$ref" ]]; then
  echo "${DEFAULT_SHA:?DEFAULT_SHA is required when REF_INPUT is empty}"
elif [[ "$ref" =~ ^[0-9]{1,7}$ ]]; then
  echo "refs/pull/${ref}/head"
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

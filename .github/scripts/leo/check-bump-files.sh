#!/usr/bin/env bash
# Is this PR a pure leo pin bump? Reads the PR's complete file list on stdin,
# one `<status>\t<filename>` per line, and exits 0 only if it is exactly one
# line: `modified` macos/Bundled/LEO_VERSION. Anything else (an extra file, an
# empty list, an add/remove/rename of the pin) exits 1 and lists what it saw.
# Produce the input from the API, not from a git diff, so every commit of a
# rebase-merged PR counts:
#   gh api repos/$REPO/pulls/$N/files --paginate --jq '.[] | [.status, .filename] | @tsv'
set -euo pipefail

readonly expected=$'modified\tmacos/Bundled/LEO_VERSION'

# Drop blank lines (a missing or doubled trailing newline), keep the rest.
files="$(grep -v '^$' || true)"

if [[ "$files" == "$expected" ]]; then
  exit 0
fi
echo "check-bump-files: not a pure pin bump; the PR's files were:" >&2
printf '%s\n' "${files:-(none)}" >&2
exit 1

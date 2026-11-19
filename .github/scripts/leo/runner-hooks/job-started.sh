#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_STARTED: clear leftovers of earlier jobs on this
# runner. Scoped to this runner's work dir (the parent of $RUNNER_TEMP); it
# never touches processes or files outside it. Best-effort; never fails the job.
set -uo pipefail

temp="${RUNNER_TEMP:-}"
[[ -n "$temp" && -d "$temp" ]] || exit 0
work="$(dirname "$temp")" # .../_work
[[ "$(basename "$work")" == _work ]] || exit 0

# Stray builds and test hosts started from this work dir (args contain its path).
pkill -f "xcodebuild.*$work" || true
pkill -f "$work/.*\.app/Contents/MacOS/" || true

# CI DerivedData older than 3 days. Only inside $RUNNER_TEMP, never ~/Library.
find "$temp" -mindepth 1 -maxdepth 1 -name 'DerivedData-*' -mtime +3 \
  -exec rm -rf {} + 2>/dev/null || true
exit 0

#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED: stop what the job left running. Scoped to
# this runner's work dir (the parent of $RUNNER_TEMP); no global kills, no
# file deletion. Best-effort; never fails the job.
set -uo pipefail

temp="${RUNNER_TEMP:-}"
[[ -n "$temp" ]] || exit 0
work="$(dirname "$temp")"
[[ "$(basename "$work")" == _work ]] || exit 0

pkill -f "xcodebuild.*$work" || true
pkill -f "$work/.*\.app/Contents/MacOS/" || true
exit 0

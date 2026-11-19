#!/usr/bin/env bash
# Runner job hook (ACTIONS_RUNNER_HOOK_JOB_STARTED / _COMPLETED): stop stray
# builds and test hosts and prune old DerivedData on a reused self-hosted
# runner. Best-effort; never fails the job.
set -uo pipefail

pkill -f 'xcodebuild' || true
pkill -f 'Build/Products/Debug/(Ghostty|Leo)\.app' || true
pkill -x Ghostty || true
pkill -x Leo || true

find "$HOME/Library/Developer/Xcode/DerivedData" -mindepth 1 -maxdepth 1 -mtime +3 \
  -exec rm -rf {} + 2>/dev/null || true
exit 0

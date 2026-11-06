#!/usr/bin/env bash
# Sourced by sign-package.sh: helpers for GitHub-hosted runners.

# retry <attempts> <cmd...>: rerun a flaky command (hdiutil create fails
# intermittently with "Resource busy" on hosted runners). Backoff is
# RETRY_BACKOFF seconds times the attempt number (default 5).
retry() {
  local attempts="$1" n=1
  shift
  until "$@"; do
    if [[ "$n" -ge "$attempts" ]]; then
      echo "retry: '$*' failed after $attempts attempts" >&2
      return 1
    fi
    echo "retry: '$*' failed (attempt $n/$attempts), retrying" >&2
    sleep $((n * ${RETRY_BACKOFF:-5}))
    n=$((n + 1))
  done
}

# Hosted images may ship with Gatekeeper assessments off, which would make
# `spctl --assess` pass without checking anything. Turn them on, and fail
# if they stay off. (--global-enable is the macOS 15+ spelling of
# --master-enable.)
ensure_assessments_enabled() {
  local spctl="${SPCTL_BIN:-spctl}" sudo="${SUDO_BIN:-sudo}"
  if "$spctl" --status 2>&1 | grep -q "assessments enabled"; then
    return 0
  fi
  echo "Gatekeeper assessments are disabled; enabling"
  "$sudo" "$spctl" --global-enable || true
  if ! "$spctl" --status 2>&1 | grep -q "assessments enabled"; then
    echo "::error::Gatekeeper assessments are disabled and could not be enabled; spctl --assess would be meaningless" >&2
    return 1
  fi
}

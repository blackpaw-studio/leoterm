#!/usr/bin/env bash
# Ends a test run that has stopped printing: usage watch-stall.sh LOG PID HANG_OUT.
# When LOG has not grown for STALL_SECONDS, writes capture-hang.sh's report to
# HANG_OUT and kills PID's process tree (the run then fails like a timeout).
set -uo pipefail

log="${1:?usage: watch-stall.sh LOG PID HANG_OUT}"
pid="${2:?usage: watch-stall.sh LOG PID HANG_OUT}"
out="${3:?usage: watch-stall.sh LOG PID HANG_OUT}"
readonly STALL_SECONDS="${STALL_SECONDS:-240}"
readonly POLL_SECONDS=10
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

last_size=-1
idle=0
while kill -0 "$pid" 2>/dev/null; do
  sleep "$POLL_SECONDS"
  size="$(stat -f %z "$log" 2>/dev/null || echo 0)"
  if [[ "$size" == "$last_size" ]]; then idle=$((idle + POLL_SECONDS)); else idle=0; fi
  last_size="$size"
  if (( idle >= STALL_SECONDS )); then
    # PID is the `timeout` wrapper; the test host is the app it runs.
    app_pid="$(pgrep -f 'Contents/MacOS/Leo -XCTest' | head -1 || true)"
    "$script_dir/capture-hang.sh" "${app_pid:-$pid}" "$out"
    kill -TERM "${app_pid:-$pid}" 2>/dev/null
    exit 0
  fi
done

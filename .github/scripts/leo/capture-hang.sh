#!/usr/bin/env bash
# Records why the test host stopped making progress: usage capture-hang.sh PID OUT.
# Samples the host and every WebContent/Networking child of it, then notes
# memory and process state. Best effort: a missing tool never fails the run.
set -uo pipefail

pid="${1:?usage: capture-hang.sh PID OUT}"
out="${2:?usage: capture-hang.sh PID OUT}"

{
  echo "== date"; date -u
  echo "== vm_stat"; vm_stat
  echo "== memory_pressure"; memory_pressure 2>&1 | tail -5
  echo "== processes"; ps -axo pid,ppid,state,%cpu,rss,etime,command | grep -E 'Leo|WebKit|xctest' | grep -v grep
} >"$out" 2>&1

for target in "$pid" $(pgrep -f 'com.apple.WebKit' || true); do
  {
    echo "== sample $target"
    sample "$target" 3 -file /dev/stdout 2>&1 | head -400
  } >>"$out" 2>&1
done

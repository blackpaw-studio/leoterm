#!/usr/bin/env bash
# Plain-sh tests for macos/scripts/leo-terminfo.sh, which compiles the
# tmux-256color entry Leo.app ships for its bundled tmux (A2b). Run directly:
#   ./test_terminfo.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly script=../../../../macos/scripts/leo-terminfo.sh
readonly source=../../../../macos/Bundled/terminfo/tmux-256color.terminfo
pass=0
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

result() {
  local ok="$1" desc="$2" detail="${3:-}"
  if [[ "$ok" == yes ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc${detail:+ ($detail)}"
    fail=$((fail + 1))
  fi
}

out="$work/Resources/terminfo"
bash "$script" "$source" "$out" > "$work/run.log" 2>&1 && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && ok=yes || ok=no
result "$ok" "the committed source compiles" "rc=$rc: $(cat "$work/run.log")"

entry="$out/74/tmux-256color"
[[ -f "$entry" ]] && ok=yes || ok=no
result "$ok" "the entry lands at terminfo/74/tmux-256color (macOS's hex layout)"

# 0432 (bytes 1a 01) is the legacy format macOS's ncurses 6.0 reads; 01036
# (1e 02) is the extended-number format a newer tic writes, which it can't.
magic="$(xxd -p -l 2 "$entry" 2>/dev/null || true)"
[[ "$magic" == 1a01 ]] && ok=yes || ok=no
result "$ok" "the compiled entry uses the legacy format macOS's libncurses reads" "magic=$magic"

# Stock macOS may ship its own (older) tmux-256color, so check that the
# lookup really resolved to ours: infocmp names the file it read.
desc="$(env -u TERMINFO TERMINFO_DIRS="$out" /usr/bin/infocmp -x tmux-256color 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$(head -1 <<<"$desc")" == *"$out"* ]] && ok=yes || ok=no
result "$ok" "TERMINFO_DIRS=<terminfo dir> resolves tmux-256color to the bundled entry" "$(head -1 <<<"$desc")"
grep -q 'colors#256' <<<"$desc" && grep -q 'Smulx=' <<<"$desc" && ok=yes || ok=no
result "$ok" "the entry carries 256 colours and ncurses 6.6's extended caps"

bash "$script" "$work/missing.terminfo" "$work/x" > /dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && ok=yes || ok=no
result "$ok" "a missing source fails"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

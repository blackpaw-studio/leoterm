#!/usr/bin/env bash
# Plain-sh tests for macos/scripts/leo-launch-agent-plist.sh, the generator of
# the SMAppService LaunchAgent plist Leo.app carries in
# Contents/Library/LaunchAgents/ (A4). Run directly:
#   ./test_launch-agent-plist.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly script=../../../../macos/scripts/leo-launch-agent-plist.sh
readonly label=studio.blackpaw.leo.daemon
readonly bundle_id=studio.blackpaw.leo.macos
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

plist="$work/LaunchAgents/$label.plist"
bash "$script" "$label" "$bundle_id" "$plist" > "$work/run.log" 2>&1 && rc=0 || rc=$?
[[ "$rc" -eq 0 && -f "$plist" ]] && ok=yes || ok=no
result "$ok" "it writes the plist, creating the parent dir" "rc=$rc: $(cat "$work/run.log")"

lint="$(plutil -lint "$plist" 2>&1)" && ok=yes || ok=no
result "$ok" "plutil -lint accepts it" "$lint"

# get KEYPATH TYPE -> the value as plutil -extract prints it (raw), or "".
get() { plutil -extract "$1" raw -expect "$2" -o - "$plist" 2>/dev/null || true; }
expect() {
  local keypath="$1" type="$2" want="$3" got
  got="$(get "$keypath" "$type")"
  [[ "$got" == "$want" ]] && ok=yes || ok=no
  result "$ok" "$keypath is $type '$want'" "got '$got'"
}

expect Label string "$label"
expect BundleProgram string Contents/Helpers/leo
expect ProgramArguments.0 string leo
expect ProgramArguments.1 string service
expect ProgramArguments.2 string --supervised
expect AssociatedBundleIdentifiers.0 string "$bundle_id"
expect RunAtLoad bool true
expect KeepAlive bool true
expect EnvironmentVariables.PATH string /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

count() { plutil -extract "$1" raw -o - "$plist" 2>/dev/null || echo "?"; }
[[ "$(count ProgramArguments)" == 3 ]] && ok=yes || ok=no
result "$ok" "ProgramArguments has exactly 3 items (no --config)" "count=$(count ProgramArguments)"
[[ "$(count AssociatedBundleIdentifiers)" == 1 ]] && ok=yes || ok=no
result "$ok" "AssociatedBundleIdentifiers has exactly the app's bundle id"
env_keys="$(plutil -extract EnvironmentVariables raw -o - "$plist" 2>/dev/null || true)"
[[ "$env_keys" == PATH ]] && ok=yes || ok=no
result "$ok" "EnvironmentVariables holds only PATH (the rest comes from managed.json env)" "keys: $env_keys"

keys="$(plutil -convert json -o - "$plist" 2>/dev/null \
  | /usr/bin/ruby -rjson -e 'puts JSON.parse(STDIN.read).keys.sort.join(" ")' 2>/dev/null)" || keys=""
want_keys="AssociatedBundleIdentifiers BundleProgram EnvironmentVariables KeepAlive Label ProgramArguments RunAtLoad"
[[ "$keys" == "$want_keys" ]] && ok=yes || ok=no
result "$ok" "only the intended keys: no ProcessType, ThrottleInterval, Standard*Path or WorkingDirectory" "keys: $keys"

grep -q '~' "$plist" && ok=no || ok=yes
result "$ok" "no ~ anywhere (launchd never expands it)"

# Bad input is refused, and refused before anything is written.
for bad in "" "studio.blackpaw/leo" "studio blackpaw" "~/x"; do
  bash "$script" "$bad" "$bundle_id" "$work/bad.plist" > /dev/null 2>&1 && rc=0 || rc=$?
  [[ "$rc" -ne 0 && ! -e "$work/bad.plist" ]] && ok=yes || ok=no
  result "$ok" "label '$bad' is refused"
done
bash "$script" "$label" "bad id!" "$work/bad.plist" > /dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -ne 0 && ! -e "$work/bad.plist" ]] && ok=yes || ok=no
result "$ok" "a malformed bundle id is refused"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

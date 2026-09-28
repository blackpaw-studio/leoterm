#!/usr/bin/env bash
# Tests that keychain.sh cleanup deletes the keychain and removes the temp
# dir even when restoring the keychain search list fails. Uses a fake
# `security` binary on PATH so no real keychain is touched.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
script="$(cd .. && pwd)/keychain.sh"

pass=0
fail=0

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

runner_temp="$workdir/runner-temp"
mkdir -p "$runner_temp"
jobdir="$(mktemp -d "$runner_temp/leo-signing.XXXXXX")"
keychain="$jobdir/leo-signing.keychain-db"
touch "$keychain"
echo '"/some/other.keychain-db"' > "$jobdir/leo-keychain-search-list"

fakebin="$workdir/bin"
mkdir -p "$fakebin"
calls="$workdir/calls.log"
: > "$calls"
cat > "$fakebin/security" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALLS_LOG"
if [[ "$1" == "list-keychains" && "$*" == *" -s "* ]]; then
  # Simulate a failure restoring the search list.
  exit 1
fi
exit 0
EOF
chmod +x "$fakebin/security"

CALLS_LOG="$calls" PATH="$fakebin:$PATH" RUNNER_TEMP="$runner_temp" LEO_KEYCHAIN="$keychain" \
  "$script" cleanup >/dev/null 2>&1
rc=$?

if [[ $rc -eq 0 ]]; then
  echo "PASS: cleanup exits 0 even when restoring the search list fails"
  pass=$((pass + 1))
else
  echo "FAIL: cleanup exited $rc"
  fail=$((fail + 1))
fi

if grep -qF "delete-keychain $keychain" "$calls"; then
  echo "PASS: cleanup still deletes the keychain after the search-list restore fails"
  pass=$((pass + 1))
else
  echo "FAIL: delete-keychain was never called (calls: $(cat "$calls"))"
  fail=$((fail + 1))
fi

if [[ ! -d "$jobdir" ]]; then
  echo "PASS: cleanup still removes the per-job temp dir after the search-list restore fails"
  pass=$((pass + 1))
else
  echo "FAIL: $jobdir still exists"
  fail=$((fail + 1))
fi

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

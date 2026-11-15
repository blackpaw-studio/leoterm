#!/usr/bin/env bash
# Plain-sh tests for check-helper.sh, the gate every bundled helper (leo,
# tmux) passes before it goes into Leo.app. Run directly:
#   ./test_check-helper.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/stub-binary.sh

readonly script=../check-helper.sh
pass=0
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# check DESC WANT_STATUS [ENV...] -- ARGS...: runs the script, matching only
# whether it succeeded (0) or failed (1 = any non-zero).
check() {
  local desc="$1" want="$2"
  shift 2
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  local out rc
  out="$(env ${envs[@]+"${envs[@]}"} bash "$script" "$@" 2>&1)" && rc=0 || rc=1
  if [[ "$rc" -eq "$want" ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (status $rc, want $want; output: $out)"
    fail=$((fail + 1))
  fi
  LAST_OUT="$out"
}

mkdir -p "$work/bin" "$work/thin" "$work/new"
make_stub "$work/bin/tmux" -V "tmux 3.8"
make_stub "$work/bin/leo" version "leo 0.56.0"
make_stub "$work/thin/tmux" -V "tmux 3.8" arm64
# The later -mmacosx-version-min wins; clang warns about the override.
make_stub "$work/new/tmux" -V "tmux 3.8" arm64 x86_64 -- -mmacosx-version-min=26.0 2>/dev/null

check "universal tmux with system-only libraries and the pinned version passes" 0 \
  -- "$work/bin/tmux" "tmux 3.8"
check "leo is asked for 'version', not -V" 0 \
  -- "$work/bin/leo" "leo 0.56.0"
check "explicit version arguments override the name-based default" 0 \
  -- "$work/bin/tmux" "tmux 3.8" -V

check "a version line that differs from the pin fails" 1 \
  -- "$work/bin/tmux" "tmux 3.6a"
grep -q "tmux 3.6a" <<<"$LAST_OUT" && grep -q "tmux 3.8" <<<"$LAST_OUT" \
  && { echo "PASS: the mismatch names expected and actual"; pass=$((pass + 1)); } \
  || { echo "FAIL: mismatch message lacks expected/actual: $LAST_OUT"; fail=$((fail + 1)); }

check "a thin (arm64-only) binary fails" 1 \
  -- "$work/thin/tmux" "tmux 3.8"
check "a binary that needs a newer macOS than the app's floor fails" 1 \
  -- "$work/new/tmux" "tmux 3.8"
check "a missing binary fails" 1 \
  -- "$work/bin/nope" "tmux 3.8"
check "an unknown helper name without explicit version arguments fails" 1 \
  -- /bin/cat "cat"

# A fake otool on PATH reports a Homebrew dylib dependency: a helper like
# that would crash on any Mac without Homebrew, so it must be rejected.
mkdir -p "$work/fakebin"
cat > "$work/fakebin/otool" <<'EOF'
#!/usr/bin/env bash
echo "$3:"
echo "	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)"
echo "	/opt/homebrew/opt/libevent/lib/libevent_core-2.1.7.dylib (compatibility version 8.0.0, current version 8.0.0)"
EOF
chmod +x "$work/fakebin/otool"
check "a non-system dylib dependency (fake otool lists /opt/homebrew) fails" 1 \
  PATH="$work/fakebin:$PATH" -- "$work/bin/tmux" "tmux 3.8"
grep -q /opt/homebrew <<<"$LAST_OUT" \
  && { echo "PASS: the offending library is named"; pass=$((pass + 1)); } \
  || { echo "FAIL: offending library not named: $LAST_OUT"; fail=$((fail + 1)); }

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

#!/usr/bin/env bash
# retry() and ensure_assessments_enabled() from hosted-helpers.sh, which
# sign-package.sh uses on GitHub-hosted runners (flaky hdiutil, Gatekeeper
# assessments possibly off). Stubs only; no real hdiutil/spctl/sudo.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0; fail=0
result() { if [[ "$1" == yes ]]; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: $2${3:+ ($3)}"; fail=$((fail+1)); fi; }

# shellcheck source=../hosted-helpers.sh
source ../hosted-helpers.sh
export RETRY_BACKOFF=0

# A command that fails N times, then succeeds.
flaky="$work/flaky.sh"
cat > "$flaky" <<'S'
#!/usr/bin/env bash
n=$(cat "$COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNT"
[[ "$n" -gt "$FAILS" ]]
S
chmod +x "$flaky"

export COUNT="$work/count"
rm -f "$COUNT"; FAILS=2 retry 3 "$flaky" && [[ "$(cat "$COUNT")" == 3 ]] \
  && result yes "retry succeeds when the last allowed attempt passes" || result no "retry succeeds on attempt 3"
rm -f "$COUNT"; if FAILS=5 retry 3 "$flaky"; then rc=0; else rc=$?; fi
[[ "$rc" -ne 0 && "$(cat "$COUNT")" == 3 ]] \
  && result yes "retry gives up after N attempts with non-zero status" || result no "retry gives up" "rc=$rc count=$(cat "$COUNT")"
rm -f "$COUNT"; FAILS=0 retry 3 "$flaky" && [[ "$(cat "$COUNT")" == 1 ]] \
  && result yes "retry runs a passing command once" || result no "retry runs once"

# spctl/sudo stubs: SPCTL_STATE file holds "enabled" or "disabled"; sudo
# spctl --global-enable flips it unless STUCK=1.
cat > "$work/spctl" <<'S'
#!/usr/bin/env bash
case "$1" in
  --status) echo "assessments $(cat "$SPCTL_STATE")" ;;
  --global-enable) echo "$*" >> "$CALLS"; [[ "${STUCK:-}" == 1 ]] || echo enabled > "$SPCTL_STATE" ;;
esac
S
printf '#!/usr/bin/env bash\necho "sudo $*" >> "$CALLS"\nexec "$@"\n' > "$work/sudo"
chmod +x "$work/spctl" "$work/sudo"
export SPCTL_BIN="$work/spctl" SUDO_BIN="$work/sudo" SPCTL_STATE="$work/state" CALLS="$work/calls"

echo enabled > "$SPCTL_STATE"; : > "$CALLS"
ensure_assessments_enabled >/dev/null && [[ ! -s "$CALLS" ]] \
  && result yes "enabled assessments are left alone" || result no "enabled left alone" "$(cat "$CALLS")"

echo disabled > "$SPCTL_STATE"; : > "$CALLS"
ensure_assessments_enabled >/dev/null && grep -q -- "--global-enable" "$CALLS" && [[ "$(cat "$SPCTL_STATE")" == enabled ]] \
  && result yes "disabled assessments are enabled via sudo spctl" || result no "disabled gets enabled" "$(cat "$CALLS")"

echo disabled > "$SPCTL_STATE"; : > "$CALLS"
if STUCK=1 ensure_assessments_enabled >/dev/null 2>&1; then rc=0; else rc=$?; fi
[[ "$rc" -ne 0 ]] && result yes "fails hard when assessments cannot be enabled" || result no "fails hard when stuck"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

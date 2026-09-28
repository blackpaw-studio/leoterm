#!/usr/bin/env bash
# keychain.sh create must register its cleanup handle (LEO_KEYCHAIN, via
# GITHUB_ENV) before doing anything that can fail, so a partway failure
# (decode, create-keychain, import, the search-list swap) still leaves the
# always-run cleanup step able to find and remove what got created. Uses a
# fake `security` binary that fails on `import`. Run directly:
#   ./test_keychain_create_registers_cleanup.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
script="$(cd .. && pwd)/keychain.sh"

pass=0
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

runner_temp="$work/runner-temp"
mkdir -p "$runner_temp"

fakebin="$work/bin"
mkdir -p "$fakebin"
cat > "$fakebin/security" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "import" ]]; then
  echo "fake import failure" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$fakebin/security"

github_env="$work/github_env"
: > "$github_env"

set +e
PATH="$fakebin:$PATH" RUNNER_TEMP="$runner_temp" GITHUB_ENV="$github_env" \
  MACOS_CERTIFICATE="ZmFrZQo=" MACOS_CERTIFICATE_PWD="x" MACOS_CI_KEYCHAIN_PWD="y" \
  "$script" create >/dev/null 2>&1
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "PASS: create exits non-zero when import fails"
  pass=$((pass + 1))
else
  echo "FAIL: create should have failed when import failed"
  fail=$((fail + 1))
fi

if grep -q '^LEO_KEYCHAIN=' "$github_env"; then
  echo "PASS: LEO_KEYCHAIN is registered in GITHUB_ENV even though create failed partway through"
  pass=$((pass + 1))
else
  echo "FAIL: LEO_KEYCHAIN was never written to GITHUB_ENV (cleanup would have nothing to clean up)"
  fail=$((fail + 1))
fi

keychain_path="$(grep '^LEO_KEYCHAIN=' "$github_env" | cut -d= -f2-)"
if [[ -n "$keychain_path" && -d "$(dirname "$keychain_path")" ]]; then
  echo "PASS: the registered keychain's temp dir exists (was actually created, just not fully set up)"
  pass=$((pass + 1))
else
  echo "FAIL: registered keychain path '$keychain_path' has no temp dir"
  fail=$((fail + 1))
fi

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

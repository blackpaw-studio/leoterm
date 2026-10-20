#!/usr/bin/env bash
# Gate for a signed Leo.app, run by sign-package.sh before notarization.
# Usage: check-bundle.sh APP
# Env: EXPECTED_TEAM_ID (default 52M9C6892K)
#
# Always: codesign --verify --deep --strict. For an app that carries the
# bundled daemon (Info.plist LeoDaemonLabel), also requires:
#   - Contents/Helpers/{leo,tmux}, each signed with the hardened runtime and
#     by EXPECTED_TEAM_ID (skipped for an ad-hoc signature: local builds);
#   - Contents/Resources/terminfo/74/tmux-256color (the bundled tmux's TERM);
#   - Contents/Library/LaunchAgents/<LeoDaemonLabel>.plist, whose
#     BundleProgram is Contents/Helpers/leo.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: check-bundle.sh APP" >&2; exit 2; }
app="${1%/}"
team="${EXPECTED_TEAM_ID:-52M9C6892K}"
failures=0

fail() { echo "::error::check-bundle: $*" >&2; failures=$((failures + 1)); }

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app" || fail "$app fails codesign --verify --deep --strict"

label="$(plutil -extract LeoDaemonLabel raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$label" ]]; then
  echo "::notice::check-bundle: $app has no LeoDaemonLabel (predates the bundled daemon); signature checked only"
  [[ "$failures" -eq 0 ]]
  exit
fi

# check_helper PATH: signed, hardened runtime, and our team unless ad-hoc.
check_helper() {
  local bin="$1" info flags
  [[ -f "$bin" ]] || { fail "missing $bin"; return; }
  info="$(/usr/bin/codesign -d --verbose=4 "$bin" 2>&1)" || { fail "$bin is not signed: $info"; return; }
  flags="$(sed -nE 's/.*flags=0x[0-9a-f]+\(([^)]*)\).*/\1/p' <<<"$info" | head -1)"
  [[ ",$flags," == *",runtime,"* ]] || fail "$bin lacks the hardened runtime (flags: ${flags:-none})"
  if grep -qx 'Signature=adhoc' <<<"$info"; then
    echo "check-bundle: $bin is ad-hoc signed; TeamIdentifier check skipped"
  else
    grep -qx "TeamIdentifier=$team" <<<"$info" \
      || fail "$bin TeamIdentifier is '$(sed -n 's/^TeamIdentifier=//p' <<<"$info")', expected $team"
  fi
}
check_helper "$app/Contents/Helpers/leo"
check_helper "$app/Contents/Helpers/tmux"

terminfo="$app/Contents/Resources/terminfo/74/tmux-256color"
[[ -f "$terminfo" ]] || fail "missing $terminfo"

agent="$app/Contents/Library/LaunchAgents/$label.plist"
if [[ -f "$agent" ]]; then
  program="$(plutil -extract BundleProgram raw -o - "$agent" 2>/dev/null || true)"
  [[ "$program" == Contents/Helpers/leo ]] || fail "$agent BundleProgram is '$program', expected Contents/Helpers/leo"
else
  fail "missing $agent"
fi

[[ "$failures" -eq 0 ]] || exit 1
echo "check-bundle: $app ok (label $label)"

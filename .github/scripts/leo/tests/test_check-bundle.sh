#!/usr/bin/env bash
# Plain-sh tests for check-bundle.sh (the signed-bundle gate sign-package.sh
# runs) and nested-code-paths.sh (the inside-out signing order), against an
# ad-hoc-signed fake Leo.app (A5). Run directly:
#   ./test_check-bundle.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/stub-binary.sh

readonly check="$PWD/../check-bundle.sh"
readonly order="$PWD/../nested-code-paths.sh"
readonly macos="$PWD/../../../../macos"
readonly label=studio.blackpaw.leo.daemon
readonly host_entitlements="$macos/LeoPluginHost/LeoPluginHost.entitlements"
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

mkdir -p "$work/stubs"
make_stub "$work/stubs/Leo" --never "never"
make_stub "$work/stubs/leo" version "leo 0.56.0"
make_stub "$work/stubs/tmux" -V "tmux 3.6b"
make_stub "$work/stubs/LeoPluginHost" --never "never"

adhoc() { codesign --force --sign - "$@" > /dev/null 2>&1; }

# fake_app NAME [legacy]: an unsigned Leo.app laid out like the real one;
# "legacy" builds one from before the bundled daemon (no LeoDaemonLabel,
# no helpers).
fake_app() {
  local app="$work/$1/Leo.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$work/stubs/Leo" "$app/Contents/MacOS/Leo"
  local plist="$app/Contents/Info.plist"
  plutil -create xml1 "$plist"
  plutil -insert CFBundleExecutable -string Leo "$plist"
  plutil -insert CFBundleIdentifier -string studio.blackpaw.leo.macos "$plist"
  plutil -insert CFBundlePackageType -string APPL "$plist"
  if [[ "${2:-}" != legacy ]]; then
    plutil -insert LeoDaemonLabel -string "$label" "$plist"
    mkdir -p "$app/Contents/Helpers"
    install -m 0755 "$work/stubs/leo" "$work/stubs/tmux" "$work/stubs/LeoPluginHost" "$app/Contents/Helpers/"
    bash "$macos/scripts/leo-terminfo.sh" "$macos/Bundled/terminfo/tmux-256color.terminfo" \
      "$app/Contents/Resources/terminfo"
    bash "$macos/scripts/leo-launch-agent-plist.sh" "$label" studio.blackpaw.leo.macos \
      "$app/Contents/Library/LaunchAgents/$label.plist"
  fi
  echo "$app"
}
# sign_inside_out APP [HELPER_FLAGS...]: ad-hoc, helpers first, then the app.
# LeoPluginHost gets its real entitlements, as sign-package.sh passes them.
sign_inside_out() {
  local app="$1"
  shift
  local helper
  for helper in "$app"/Contents/Helpers/*; do
    [[ -e "$helper" ]] || continue
    if [[ "${helper##*/}" == LeoPluginHost ]]; then
      adhoc "$@" --entitlements "$host_entitlements" "$helper"
    else
      adhoc "$@" "$helper"
    fi
  done
  adhoc --options runtime "$app"
}
run() { OUT="$(bash "$check" "$1" 2>&1)" && RC=0 || RC=$?; }

# -- check-bundle -----------------------------------------------------------------

app="$(fake_app good)"
sign_inside_out "$app" --options runtime
run "$app"
[[ "$RC" -eq 0 ]] && ok=yes || ok=no
result "$ok" "an ad-hoc tree signed inside-out with runtime passes (TeamID check skipped for ad-hoc)" "rc=$RC: $OUT"

app="$(fake_app unsigned)"
adhoc --options runtime "$app/Contents/Helpers/tmux"
codesign --force --sign - --options runtime "$app" > /dev/null 2>&1 || true
run "$app"
[[ "$RC" -ne 0 ]] && ok=yes || ok=no
result "$ok" "an unsigned helper fails" "rc=$RC: $OUT"

app="$(fake_app noruntime)"
sign_inside_out "$app"
run "$app"
[[ "$RC" -ne 0 && "$OUT" == *runtime* ]] && ok=yes || ok=no
result "$ok" "a helper signed without the hardened runtime fails" "rc=$RC: $OUT"

app="$(fake_app tampered)"
sign_inside_out "$app" --options runtime
cp "$work/stubs/tmux" "$app/Contents/Helpers/leo"
run "$app"
[[ "$RC" -ne 0 ]] && ok=yes || ok=no
result "$ok" "a helper changed after signing fails the deep verify" "rc=$RC"

app="$(fake_app noterminfo)"
rm -rf "$app/Contents/Resources/terminfo"
sign_inside_out "$app" --options runtime
run "$app"
[[ "$RC" -ne 0 && "$OUT" == *tmux-256color* ]] && ok=yes || ok=no
result "$ok" "a missing tmux-256color terminfo entry fails" "rc=$RC: $OUT"

app="$(fake_app noagent)"
rm -rf "$app/Contents/Library"
sign_inside_out "$app" --options runtime
run "$app"
[[ "$RC" -ne 0 && "$OUT" == *"$label.plist"* ]] && ok=yes || ok=no
result "$ok" "a missing LaunchAgent plist fails" "rc=$RC: $OUT"

app="$(fake_app nohelper)"
rm "$app/Contents/Helpers/leo"
sign_inside_out "$app" --options runtime
run "$app"
[[ "$RC" -ne 0 && "$OUT" == *Helpers/leo* ]] && ok=yes || ok=no
result "$ok" "a missing helper fails" "rc=$RC: $OUT"

app="$(fake_app hostunsigned)"
for helper in tmux leo; do adhoc --options runtime "$app/Contents/Helpers/$helper"; done
# codesign itself refuses to seal an app over an unsigned helper (the CI error); the gate must too.
adhoc --options runtime "$app" || true
run "$app"
[[ "$RC" -ne 0 && "$OUT" == *LeoPluginHost* ]] && ok=yes || ok=no
result "$ok" "an unsigned LeoPluginHost fails, naming it" "rc=$RC: $OUT"

app="$(fake_app hostnoruntime)"
for helper in tmux leo; do adhoc --options runtime "$app/Contents/Helpers/$helper"; done
adhoc --entitlements "$host_entitlements" "$app/Contents/Helpers/LeoPluginHost"
adhoc --options runtime "$app"
run "$app"
[[ "$RC" -ne 0 && "$OUT" == *LeoPluginHost*runtime* ]] && ok=yes || ok=no
result "$ok" "a LeoPluginHost signed without the hardened runtime fails" "rc=$RC: $OUT"

app="$(fake_app hostnosandbox)"
for helper in tmux leo LeoPluginHost; do adhoc --options runtime "$app/Contents/Helpers/$helper"; done
adhoc --options runtime "$app"
run "$app"
[[ "$RC" -ne 0 && "$OUT" == *app-sandbox* ]] && ok=yes || ok=no
result "$ok" "a LeoPluginHost re-signed without its sandbox entitlement fails" "rc=$RC: $OUT"

app="$(fake_app hostmissing)"
rm "$app/Contents/Helpers/LeoPluginHost"
sign_inside_out "$app" --options runtime
run "$app"
[[ "$RC" -ne 0 && "$OUT" == *LeoPluginHost* ]] && ok=yes || ok=no
result "$ok" "a missing LeoPluginHost fails by default (a current release must not ship without it)" "rc=$RC: $OUT"
OUT="$(PLUGIN_HOST_REQUIRED=no bash "$check" "$app" 2>&1)" && RC=0 || RC=$?
[[ "$RC" -eq 0 ]] && ok=yes || ok=no
result "$ok" "a missing LeoPluginHost passes only on the explicit legacy path" "rc=$RC: $OUT"

app="$(fake_app hostlink)"
rm "$app/Contents/Helpers/LeoPluginHost"
ln -s "$work/stubs/LeoPluginHost" "$app/Contents/Helpers/LeoPluginHost"
sign_inside_out "$app" --options runtime
run "$app"
[[ "$RC" -ne 0 && "$OUT" == *symlink* ]] && ok=yes || ok=no
result "$ok" "a symlinked helper fails the bundle gate" "rc=$RC: $OUT"

app="$(fake_app legacy legacy)"
adhoc --options runtime "$app"
run "$app"
[[ "$RC" -eq 0 && "$OUT" == *"::notice::"* ]] && ok=yes || ok=no
result "$ok" "an app from before the bundled daemon only gets the signature check" "rc=$RC: $OUT"

# -- nested-code-paths ---------------------------------------------------------------

app="$(fake_app order)"
paths="$(bash "$order" "$app" 2>&1)" && rc=0 || rc=$?
line_of() { grep -nxF "$1" <<<"$paths" | head -1 | cut -d: -f1 || true; }
[[ "$rc" -eq 0 && "$(tail -1 <<<"$paths")" == "$app" ]] && ok=yes || ok=no
result "$ok" "the app itself is signed last" "rc=$rc: $paths"
for helper in tmux leo LeoPluginHost; do
  n="$(line_of "$app/Contents/Helpers/$helper")"
  [[ -n "$n" && "$n" -lt "$(line_of "$app")" ]] && ok=yes || ok=no
  result "$ok" "Helpers/$helper is signed before the app"
done
sparkle="$app/Contents/Frameworks/Sparkle.framework"
updater="$(line_of "$sparkle/Versions/B/Updater.app")"
[[ -n "$updater" && "$updater" -lt "$(line_of "$sparkle")" ]] && ok=yes || ok=no
result "$ok" "Sparkle's nested code is signed before the framework"

app="$(fake_app orderextra)"
install -m 0755 "$work/stubs/tmux" "$app/Contents/Helpers/SomeFutureHelper"
paths="$(bash "$order" "$app" 2>&1)" || true
n="$(line_of "$app/Contents/Helpers/SomeFutureHelper")"
[[ -n "$n" && "$n" -lt "$(line_of "$app")" ]] && ok=yes || ok=no
result "$ok" "any file in Contents/Helpers is listed, so a new helper cannot ship unsigned"

app="$(fake_app orderlink)"
ln -s "$work/stubs/tmux" "$app/Contents/Helpers/Linked"
paths="$(bash "$order" "$app" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 && "$paths" == *Linked* && "$paths" != *"$app" ]] && ok=yes || ok=no
result "$ok" "a symlinked helper is rejected before anything is listed (the signer would follow it out of the bundle)" "rc=$rc: $paths"

app="$(fake_app orderdir)"
mkdir "$app/Contents/Helpers/Nested"
paths="$(bash "$order" "$app" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 && "$paths" == *Nested* ]] && ok=yes || ok=no
result "$ok" "a non-regular helper is rejected" "rc=$rc: $paths"

# -- plugin-host-expected ------------------------------------------------------------

expected="$PWD/../plugin-host-expected.sh"
printf 'LeoPluginHost\n' > "$work/with.pbxproj"
printf 'Ghostty\n' > "$work/without.pbxproj"
[[ "$(bash "$expected" "$work/with.pbxproj")" == yes ]] && ok=yes || ok=no
result "$ok" "a project that builds LeoPluginHost requires it"
[[ "$(bash "$expected" "$work/without.pbxproj")" == no ]] && ok=yes || ok=no
result "$ok" "a project from before LeoPluginHost is the legacy path"
[[ "$(bash "$expected" "$work/missing.pbxproj")" == yes ]] && ok=yes || ok=no
result "$ok" "an unreadable project fails closed (required)"
[[ "$(bash "$expected" "$macos/Ghostty.xcodeproj/project.pbxproj")" == yes ]] && ok=yes || ok=no
result "$ok" "this repo's Xcode project requires LeoPluginHost (guards a rename silently disabling the check)"

app="$(fake_app orderlegacy legacy)"
paths="$(bash "$order" "$app" 2>&1)" || true
grep -q Helpers <<<"$paths" && ok=no || ok=yes
result "$ok" "an app without helpers lists none (older refs still sign)"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

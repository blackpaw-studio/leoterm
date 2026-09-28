#!/usr/bin/env bash
# Confirms the hdiutil-based DMG (sign-package.sh's "create DMG" group)
# contains the app and an /Applications symlink, without touching signing
# or notarization. Run directly: ./test_dmg-layout.sh
set -euo pipefail

work="$(mktemp -d)"
trap 'hdiutil detach "$mount" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

app="$work/Leo.app"
mkdir -p "$app/Contents/MacOS"
echo fake > "$app/Contents/MacOS/Leo"
dmg="$work/Leo.dmg"

staging="$(mktemp -d "$work/leo-dmg.XXXXXX")"
ditto "$app" "$staging/Leo.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Leo -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
rm -rf "$staging"

mount="$(hdiutil attach "$dmg" -nobrowse -readonly | tail -1 | awk '{print $NF}')"

fail=0
[[ -d "$mount/Leo.app" ]] || { echo "FAIL: Leo.app missing from mounted DMG"; fail=1; }
[[ -L "$mount/Applications" ]] || { echo "FAIL: /Applications symlink missing"; fail=1; }
if [[ -L "$mount/Applications" ]]; then
  target="$(readlink "$mount/Applications")"
  [[ "$target" == "/Applications" ]] || { echo "FAIL: Applications symlink points at '$target'"; fail=1; }
fi

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: DMG contains Leo.app and an /Applications symlink"
fi
exit "$fail"

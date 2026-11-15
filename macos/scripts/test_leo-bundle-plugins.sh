#!/usr/bin/env bash
# Plain-bash tests for leo-bundle-plugins.sh. Run directly:
#   macos/scripts/test_leo-bundle-plugins.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0 fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

mkdir -p "$work/src/studio.blackpaw.good/dist" "$work/src/studio.blackpaw.nomanifest" "$work/out"
echo '{}' > "$work/src/studio.blackpaw.good/leo-plugin.json"
echo 'x' > "$work/src/studio.blackpaw.good/dist/main.js"
touch "$work/src/.gitkeep" "$work/src/studio.blackpaw.nomanifest/readme"
mkdir -p "$work/out/studio.blackpaw.stale"

"$here/leo-bundle-plugins.sh" "$work/src" "$work/out"

check "copies a plugin with a manifest" "[[ -f $work/out/studio.blackpaw.good/dist/main.js ]]"
check "skips a folder with no manifest" "[[ ! -e $work/out/studio.blackpaw.nomanifest ]]"
check "removes a stale plugin" "[[ ! -e $work/out/studio.blackpaw.stale ]]"
check "an empty source still creates the output dir" \
  "mkdir $work/empty && $here/leo-bundle-plugins.sh $work/empty $work/out2 && [[ -d $work/out2 ]]"

echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]

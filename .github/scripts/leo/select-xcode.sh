#!/usr/bin/env bash
# Pick the installed Xcode whose version starts with $1 (e.g. 26.3) and export
# DEVELOPER_DIR for the rest of the job. A missing version fails the job; it
# never falls back to another Xcode (26.5's SDK breaks Zig linking on the Mac
# app, 27 crashes the iOS code; see docs/leo/ci.md).
# Usage: select-xcode.sh MAJOR.MINOR      (env: XCODE_ROOT, default /Applications)
set -euo pipefail

want="${1:?usage: select-xcode.sh MAJOR.MINOR}"
root="${XCODE_ROOT:-/Applications}"

for app in "$root"/Xcode*.app; do
  [[ -d "$app/Contents/Developer" ]] || continue
  v="$(DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version 2>/dev/null | sed -n 's/^Xcode //p')"
  [[ "$v" == "$want" || "$v" == "$want".* ]] || { echo "skipping $app (Xcode ${v:-unknown})" >&2; continue; }
  echo "DEVELOPER_DIR=$app/Contents/Developer" >> "${GITHUB_ENV:-/dev/stdout}"
  DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version
  exit 0
done

echo "::error::no Xcode $want found under $root" >&2
ls -d "$root"/Xcode*.app >&2 || true
exit 1

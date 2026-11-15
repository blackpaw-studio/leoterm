#!/usr/bin/env bash
# Put the bundled helpers into a built Leo.app and stamp their versions.
# Usage: embed-helpers.sh APP SRC_ROOT
#   APP       the built Leo.app (unsigned; sign-package.sh signs it later)
#   SRC_ROOT  the source tree being built (holds macos/Bundled/*_VERSION)
# Env: LEO_BINARY, TMUX_BINARY, RELEASE_TAG, CURL (see fetch-leo.sh and
#      build-tmux.sh).
#
# Installs Contents/Helpers/leo and Contents/Helpers/tmux (0755) and sets
# Info.plist LeoBundledLeoVersion / LeoBundledTmuxVersion from what the
# helpers themselves report. Both helpers are fetched/built and checked
# before either is installed, so a failure leaves the app untouched.
#
# CI scripts come from the workflow's commit, not the ref being built, so a
# ref from before bundled helpers (no LEO_VERSION pin) is skipped, keeping
# older refs buildable.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: embed-helpers.sh APP SRC_ROOT" >&2; exit 2; }
app="$1" src_root="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "::error::embed-helpers: $*" >&2; exit 1; }

if [[ ! -f "$src_root/macos/Bundled/LEO_VERSION" ]]; then
  echo "::notice::embed-helpers: $src_root has no macos/Bundled/LEO_VERSION (predates bundled helpers); skipping"
  exit 0
fi
plist="$app/Contents/Info.plist"
[[ -f "$plist" ]] || die "$app is not a built app (no Contents/Info.plist)"

stage="$(mktemp -d "${TMPDIR:-/tmp}/embed-helpers.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
SRC_ROOT="$src_root" "$here/fetch-leo.sh" "$stage"
SRC_ROOT="$src_root" "$here/build-tmux.sh" "$stage"

helpers="$app/Contents/Helpers"
install -d -m 0755 "$helpers"
install -m 0755 "$stage/leo" "$helpers/leo"
install -m 0755 "$stage/tmux" "$helpers/tmux"

leo_version="$("$helpers/leo" version)"
tmux_version="$("$helpers/tmux" -V)"
plutil -replace LeoBundledLeoVersion -string "${leo_version#leo }" "$plist"
plutil -replace LeoBundledTmuxVersion -string "${tmux_version#tmux }" "$plist"
echo "embed-helpers: $helpers ($leo_version, $tmux_version)"

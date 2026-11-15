#!/bin/bash
# Xcode "Leo dev helpers" phase: lets a local build carry the bundled daemon
# without CI's fetch/build. Copies the LEO_BINARY / TMUX_BINARY build
# settings (or environment variables) into Contents/Helpers and signs them
# with the build's identity (ad-hoc when there is none), hardened runtime
# on, before Xcode seals the app. Does nothing when neither is set.
#   xcodebuild ... LEO_BINARY=$(command -v leo) TMUX_BINARY=/path/to/tmux
# Release bundles get their helpers from embed-helpers.sh instead.
set -euo pipefail

helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"

embed() {
  local name="$1" src="$2"
  [[ -n "$src" ]] || return 0
  [[ -f "$src" && -x "$src" ]] || { echo "error: $name: $src is not an executable file" >&2; exit 1; }
  install -d -m 0755 "$helpers"
  install -m 0755 "$src" "$helpers/$name"
  /usr/bin/codesign --force --options runtime --timestamp=none --sign "$identity" "$helpers/$name"
  echo "Leo dev helpers: $helpers/$name <- $src"
}

embed leo "${LEO_BINARY:-}"
embed tmux "${TMUX_BINARY:-}"

#!/usr/bin/env bash
# Plain-sh tests for embed-helpers.sh, which puts leo and tmux into a built
# Leo.app (Contents/Helpers/) and stamps their versions into Info.plist (A3).
# Uses a fake .app and the LEO_BINARY / TMUX_BINARY overrides, so nothing is
# downloaded or built. Run directly:
#   ./test_embed-helpers.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/stub-binary.sh

readonly script="$PWD/../embed-helpers.sh"
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

mkdir -p "$work/stubs" "$work/stale"
make_stub "$work/stubs/leo" version "leo 0.56.0"
make_stub "$work/stubs/tmux" -V "tmux 3.6b"
make_stub "$work/stale/tmux" -V "tmux 3.5a"
readonly hex="$(printf 'a%.0s' {1..64})"

# fake_app NAME: a minimal Leo.app with an Info.plist.
fake_app() {
  local app="$work/$1/Leo.app"
  mkdir -p "$app/Contents/MacOS"
  plutil -create xml1 "$app/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string studio.blackpaw.leo.macos "$app/Contents/Info.plist"
  echo "$app"
}
# fake_src NAME [nopin]: a source tree with both pin files (or none).
fake_src() {
  local root="$work/$1/src"
  mkdir -p "$root/macos/Bundled"
  if [[ "${2:-}" != nopin ]]; then
    printf 'version=0.56.0\nsha256=\n' > "$root/macos/Bundled/LEO_VERSION"
    printf 'tmux_version=3.6b\nlibevent_version=2.1.13-stable\nutf8proc_version=2.12.0\n' \
      > "$root/macos/Bundled/TMUX_VERSION"
    printf 'tmux_sha256=%s\nlibevent_sha256=%s\nutf8proc_sha256=%s\n' "$hex" "$hex" "$hex" \
      >> "$root/macos/Bundled/TMUX_VERSION"
  fi
  echo "$root"
}
key() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true; }

# run APP SRC [ENV...]: output in $OUT, status in $RC.
run() {
  local app="$1" src="$2"
  shift 2
  OUT="$(env -u RELEASE_TAG LEO_BINARY="$work/stubs/leo" TMUX_BINARY="$work/stubs/tmux" \
    CURL=false "$@" bash "$script" "$app" "$src" 2>&1)" && RC=0 || RC=$?
}

# -- embedding ---------------------------------------------------------------------

app="$(fake_app ok)"
run "$app" "$(fake_src ok)"
[[ "$RC" -eq 0 ]] && ok=yes || ok=no
result "$ok" "embedding into a built app succeeds" "rc=$RC: $OUT"
for name in leo tmux; do
  bin="$app/Contents/Helpers/$name"
  cmp -s "$work/stubs/$name" "$bin" && ok=yes || ok=no
  result "$ok" "Contents/Helpers/$name is the fetched/built $name"
  [[ "$(stat -f %Lp "$bin" 2>/dev/null)" == 755 ]] && ok=yes || ok=no
  result "$ok" "Contents/Helpers/$name has mode 0755"
done
[[ "$(stat -f %Lp "$app/Contents/Helpers")" == 755 ]] && ok=yes || ok=no
result "$ok" "Contents/Helpers has mode 0755"
[[ ! -e "$app/Contents/MacOS/leo" ]] && ok=yes || ok=no
result "$ok" "nothing lands in Contents/MacOS (MacOS/leo is MacOS/Leo on case-insensitive APFS)"
[[ "$(key "$app" LeoBundledLeoVersion)" == 0.56.0 ]] && ok=yes || ok=no
result "$ok" "Info.plist LeoBundledLeoVersion is the bundled leo's version" "got '$(key "$app" LeoBundledLeoVersion)'"
[[ "$(key "$app" LeoBundledTmuxVersion)" == 3.6b ]] && ok=yes || ok=no
result "$ok" "Info.plist LeoBundledTmuxVersion is the bundled tmux's version" "got '$(key "$app" LeoBundledTmuxVersion)'"
[[ "$(key "$app" CFBundleIdentifier)" == studio.blackpaw.leo.macos ]] && ok=yes || ok=no
result "$ok" "existing Info.plist keys are kept"

run "$app" "$(fake_src ok)"
[[ "$RC" -eq 0 && "$(key "$app" LeoBundledTmuxVersion)" == 3.6b ]] && ok=yes || ok=no
result "$ok" "embedding again over an embedded app succeeds (keys replaced)" "rc=$RC: $OUT"

# -- pre-feature refs ----------------------------------------------------------------

app="$(fake_app old)"
run "$app" "$(fake_src old nopin)"
[[ "$RC" -eq 0 && "$OUT" == *"::notice::"* ]] && ok=yes || ok=no
result "$ok" "a ref without macos/Bundled/LEO_VERSION is skipped with a ::notice::" "rc=$RC: $OUT"
[[ ! -e "$app/Contents/Helpers" && -z "$(key "$app" LeoBundledLeoVersion)" ]] && ok=yes || ok=no
result "$ok" "a skipped ref gets no Helpers dir and no version keys"

# -- failures --------------------------------------------------------------------------

app="$(fake_app stale)"
run "$app" "$(fake_src stale)" TMUX_BINARY="$work/stale/tmux"
[[ "$RC" -ne 0 ]] && ok=yes || ok=no
result "$ok" "a helper that fails its check fails the embed" "rc=$RC"
[[ ! -e "$app/Contents/Helpers" ]] && ok=yes || ok=no
result "$ok" "a failed embed leaves the app without a half-filled Helpers dir"

run "$work/nope/Leo.app" "$(fake_src nope)"
[[ "$RC" -ne 0 ]] && ok=yes || ok=no
result "$ok" "a missing app fails" "rc=$RC"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

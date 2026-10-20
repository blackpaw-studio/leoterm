#!/usr/bin/env bash
# Gate for a helper binary bundled into Leo.app (Contents/Helpers/leo, tmux).
# Usage: check-helper.sh BIN EXPECTED [VERSION_ARG...]
#
# Fails unless BIN:
#   - is universal (arm64 and x86_64 slices);
#   - links only system libraries (/usr/lib/, /System/), so it runs on a
#     stock Mac without Homebrew;
#   - needs no macOS newer than HELPER_MIN_MACOS (default 13.0, the app's
#     deployment target) in any slice;
#   - prints exactly EXPECTED when run with VERSION_ARG. VERSION_ARG defaults
#     by name: tmux -> -V ("tmux 3.8"), leo -> version ("leo 0.56.0").
set -euo pipefail

usage() { echo "usage: check-helper.sh BIN EXPECTED [VERSION_ARG...]" >&2; exit 2; }
[[ $# -ge 2 ]] || usage
bin="$1" expected="$2"
shift 2
min_macos="${HELPER_MIN_MACOS:-13.0}"

die() { echo "::error::check-helper: $bin: $*" >&2; exit 1; }

[[ -f "$bin" && -x "$bin" ]] || die "not an executable file"

version_args=("$@")
if [[ "${#version_args[@]}" -eq 0 ]]; then
  case "$(basename "$bin")" in
    tmux) version_args=(-V) ;;
    leo) version_args=(version) ;;
    *) die "no default version argument for '$(basename "$bin")'; pass one" ;;
  esac
fi

archs="$(lipo -archs "$bin" 2>&1)" || die "lipo failed: $archs"
for want in arm64 x86_64; do
  [[ " $archs " == *" $want "* ]] || die "missing $want slice (has: $archs)"
done

# "1.2" or "1.2.3" -> comparable integer.
version_number() {
  local major minor patch
  IFS=. read -r major minor patch <<<"$1"
  echo $((major * 10000 + ${minor:-0} * 100 + ${patch:-0}))
}

for arch in arm64 x86_64; do
  # The first line names the file; the slice's own install name (dylibs
  # only) never appears for an executable.
  libs="$(otool -arch "$arch" -L "$bin" | tail -n +2 | awk '{print $1}')"
  bad="$(grep -vE '^(/usr/lib/|/System/)' <<<"$libs" || true)"
  [[ -z "$bad" ]] || die "$arch links non-system libraries: $(echo $bad)"

  # LC_BUILD_VERSION ("minos") or the older LC_VERSION_MIN_MACOSX ("version").
  minos="$(vtool -arch "$arch" -show-build "$bin" 2>/dev/null \
    | awk '$1 == "minos" || ($1 == "version" && !seen++) {print $2; exit}')"
  [[ -n "$minos" ]] || die "$arch has no minimum macOS version load command"
  [[ "$(version_number "$minos")" -le "$(version_number "$min_macos")" ]] \
    || die "$arch needs macOS $minos, newer than the app's floor $min_macos"
done

actual="$("$bin" "${version_args[@]}" 2>&1)" || die "'${version_args[*]}' failed: $actual"
[[ "$actual" == "$expected" ]] || die "version mismatch: expected '$expected', got '$actual'"

echo "check-helper: $bin ok ($archs; $actual)"

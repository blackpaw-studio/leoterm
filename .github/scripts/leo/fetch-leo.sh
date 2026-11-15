#!/usr/bin/env bash
# Fetch the leo binary that Leo.app bundles as Contents/Helpers/leo.
# Usage: fetch-leo.sh OUT_DIR      -> OUT_DIR/leo (mode 0755)
# Env:
#   SRC_ROOT     source tree holding macos/Bundled/LEO_VERSION
#                (default: the git toplevel of the current directory)
#   LEO_BINARY   dev override: use this binary instead of the pinned release.
#                Refused when RELEASE_TAG is set, so a release can only ship
#                the pinned, checksummed leo.
#   RELEASE_TAG  set by release builds (leo-vX.Y.Z)
#   CURL         download command (default: curl); a test seam
#
# The pin's sha256 is the release tarball's hash, the same value the
# release's checksums.txt lists. The binary must be universal and report
# exactly `leo <pinned version>`.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: fetch-leo.sh OUT_DIR" >&2; exit 2; }
out_dir="$1"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src_root="${SRC_ROOT:-$(git rev-parse --show-toplevel)}"
pin_file="$src_root/macos/Bundled/LEO_VERSION"
readonly release_base=https://github.com/blackpaw-studio/leo/releases/download

die() { echo "::error::fetch-leo: $*" >&2; exit 1; }

[[ -f "$pin_file" ]] || die "missing pin file $pin_file"
pin_value() { sed -nE "s/^$1=(.*)$/\1/p" "$pin_file" | tail -1; }
version="$(pin_value version)"
sha256="$(pin_value sha256)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "$pin_file: version '$version' is not X.Y.Z (no 'v' prefix: it is added to the tag only)"

mkdir -p "$out_dir"
dest="$out_dir/leo"
work="$(mktemp -d "${TMPDIR:-/tmp}/fetch-leo.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [[ -n "${LEO_BINARY:-}" ]]; then
  [[ -z "${RELEASE_TAG:-}" ]] || die "LEO_BINARY is a dev override; release $RELEASE_TAG must ship the pinned leo $version"
  echo "::warning::fetch-leo: using LEO_BINARY=$LEO_BINARY instead of the pinned leo $version"
  install -m 0755 "$LEO_BINARY" "$work/leo"
  actual="$("$work/leo" version 2>&1 || true)"
  # An override exists to try an unreleased leo, so a different version is
  # expected; check-helper still enforces everything else.
  [[ "$actual" == "leo $version" ]] \
    || echo "::warning::fetch-leo: LEO_BINARY reports '$actual', not the pinned 'leo $version'"
  "$here/check-helper.sh" "$work/leo" "$actual"
else
  [[ -n "$sha256" ]] || die "$pin_file: no sha256 for leo $version yet; set it from that release's checksums.txt"
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || die "$pin_file: sha256 '$sha256' is not 64 lowercase hex chars"
  url="$release_base/v$version/leo_${version}_darwin_universal.tar.gz"
  tarball="$work/leo.tar.gz"
  echo "fetch-leo: downloading $url" >&2
  "${CURL:-curl}" -fsSL --retry 3 -o "$tarball" "$url"
  actual_sha="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
  [[ "$actual_sha" == "$sha256" ]] \
    || die "sha256 mismatch for $url: expected $sha256, got $actual_sha"

  # Untrusted archive: extract into its own new, empty directory and take
  # only a regular file named leo at its root.
  mkdir "$work/x"
  tar -xzf "$tarball" -C "$work/x"
  [[ -f "$work/x/leo" && ! -L "$work/x/leo" ]] || die "$url has no regular file 'leo' at its root"
  install -m 0755 "$work/x/leo" "$work/leo"
  "$here/check-helper.sh" "$work/leo" "leo $version"
fi

mv -f "$work/leo" "$dest"
echo "fetch-leo: $dest"

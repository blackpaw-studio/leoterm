#!/usr/bin/env bash
# Verify a leo release and rewrite the bundled-leo pin to it.
# Usage: bump-leo.sh VERSION SHA256
#   VERSION  bare X.Y.Z (no "v")
#   SHA256   the darwin_universal tarball's hash, 64 lowercase hex chars
# Env:
#   SRC_ROOT       source tree holding macos/Bundled/LEO_VERSION
#                  (default: the git toplevel of the current directory)
#   CURL           download command (default: curl); a test seam
#   GITHUB_OUTPUT  when set, receives bump=true|false, version=X.Y.Z and (when
#                  bumping) the validated sha256=
#
# Both arguments are untrusted (a repository_dispatch payload) and validated
# before anything else happens. The sha is then checked against that
# release's own checksums.txt, so a forged dispatch cannot pin an arbitrary
# binary. A version that is not newer than the pin is a no-op (bump=false);
# the same version with a different sha is an error.
# fetch-leo.sh then downloads the tarball and re-verifies it end to end.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: bump-leo.sh VERSION SHA256" >&2; exit 2; }
version="$1"
sha256="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src_root="${SRC_ROOT:-$(git rev-parse --show-toplevel)}"
pin_file="$src_root/macos/Bundled/LEO_VERSION"
readonly release_base=https://github.com/blackpaw-studio/leo/releases/download

die() { echo "::error::bump-leo: $*" >&2; exit 1; }
output() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1" >> "$GITHUB_OUTPUT"; }

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version is not X.Y.Z (no 'v' prefix)"
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || die "sha256 is not 64 lowercase hex chars"
[[ -f "$pin_file" ]] || die "missing pin file $pin_file"

pin_value() { sed -nE "s/^$1=(.*)$/\1/p" "$pin_file" | tail -1; }
pinned_version="$(pin_value version)"
pinned_sha="$(pin_value sha256)"

if [[ "$version" == "$pinned_version" ]]; then
  [[ "$sha256" == "$pinned_sha" ]] \
    || die "leo $version is already pinned with sha256 $pinned_sha; refusing a different $sha256"
fi
if ! "$here/semver-gt.sh" "$version" "$pinned_version"; then
  echo "bump-leo: leo $version is not newer than the pinned $pinned_version; nothing to do"
  output "bump=false"
  output "version=$version"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/bump-leo.XXXXXX")"
trap 'rm -rf "$work"' EXIT

asset="leo_${version}_darwin_universal.tar.gz"
url="$release_base/v$version/checksums.txt"
echo "bump-leo: downloading $url" >&2
"${CURL:-curl}" -fsSL --retry 3 -o "$work/checksums.txt" "$url" || die "could not download $url"
listed="$(awk -v name="$asset" '$2 == name { print $1 }' "$work/checksums.txt")"
[[ "$listed" == "$sha256" ]] \
  || die "sha256 mismatch for $asset: payload says $sha256, $url lists '${listed:-nothing}'"

# Rewrite only the two pin lines; comments and anything else stay as they are.
awk -v v="$version" -v s="$sha256" '
  /^version=/ { print "version=" v; seen_v = 1; next }
  /^sha256=/  { print "sha256=" s; seen_s = 1; next }
  { print }
  END {
    if (!seen_v) print "version=" v
    if (!seen_s) print "sha256=" s
  }
' "$pin_file" > "$work/pin"
mv -f "$work/pin" "$pin_file"

echo "bump-leo: pinned leo $version ($sha256)"
output "bump=true"
output "version=$version"
output "sha256=$sha256"

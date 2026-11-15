#!/usr/bin/env bash
# Build the tmux that Leo.app bundles as Contents/Helpers/tmux.
# Usage: build-tmux.sh OUT_DIR     -> OUT_DIR/tmux (mode 0755)
# Env:
#   SRC_ROOT         source tree holding macos/Bundled/TMUX_VERSION
#                    (default: the git toplevel of the current directory)
#   TMUX_BINARY      use this already-built tmux (CI's cache, a dev build)
#                    instead of building; it must still pass check-helper.sh
#                    against the pin
#   TMUX_BUILD_DIR   scratch dir to build in (default: a temp dir, removed)
#   CURL             download command (default: curl); a test seam
#
# Static libevent and utf8proc, ncurses from the macOS SDK, each arch built
# with MACOSX_DEPLOYMENT_TARGET=13.0 and joined with lipo. Every source
# tarball is checked against its pinned sha256 before anything is built.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: build-tmux.sh OUT_DIR" >&2; exit 2; }
out_dir="$1"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src_root="${SRC_ROOT:-$(git rev-parse --show-toplevel)}"
pin_file="$src_root/macos/Bundled/TMUX_VERSION"
readonly min_macos=13.0
readonly archs=(arm64 x86_64)

die() { echo "::error::build-tmux: $*" >&2; exit 1; }

[[ -f "$pin_file" ]] || die "missing pin file $pin_file"
pin_value() {
  local v
  v="$(sed -nE "s/^$1=(.*)$/\1/p" "$pin_file" | tail -1)"
  [[ -n "$v" ]] || die "$pin_file: missing $1"
  echo "$v"
}
# pinned NAME PATTERN: the NAME_version value, validated against PATTERN.
pinned() {
  local v
  v="$(pin_value "$1_version")"
  [[ "$v" =~ $2 ]] || die "$pin_file: $1_version '$v' doesn't match $2"
  echo "$v"
}
tmux_v="$(pinned tmux '^[0-9]+\.[0-9]+[a-z]?$')"
libevent_v="$(pinned libevent '^[0-9]+\.[0-9]+\.[0-9]+-stable$')"
utf8proc_v="$(pinned utf8proc '^[0-9]+\.[0-9]+\.[0-9]+$')"
for name in tmux libevent utf8proc; do
  sha="$(pin_value "${name}_sha256")"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "$pin_file: ${name}_sha256 '$sha' is not 64 lowercase hex chars"
done

mkdir -p "$out_dir"
dest="$out_dir/tmux"

if [[ -n "${TMUX_BINARY:-}" ]]; then
  echo "build-tmux: using TMUX_BINARY=$TMUX_BINARY" >&2
  staged="$(mktemp -d "${TMPDIR:-/tmp}/build-tmux.XXXXXX")"
  trap 'rm -rf "$staged"' EXIT
  install -m 0755 "$TMUX_BINARY" "$staged/tmux"
  "$here/check-helper.sh" "$staged/tmux" "tmux $tmux_v"
  mv -f "$staged/tmux" "$dest"
  echo "build-tmux: $dest"
  exit 0
fi

if [[ -n "${TMUX_BUILD_DIR:-}" ]]; then
  work="$TMUX_BUILD_DIR"
  mkdir -p "$work"
else
  work="$(mktemp -d "${TMPDIR:-/tmp}/build-tmux.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
fi

# fetch NAME URL: download into its own new, empty dir and verify.
fetch() {
  local name="$1" url="$2" want got dir="$work/dl-$1"
  want="$(pin_value "${name}_sha256")"
  rm -rf "$dir"
  mkdir -p "$dir"
  echo "build-tmux: downloading $url" >&2
  "${CURL:-curl}" -fsSL --retry 3 -o "$dir/src.tar.gz" "$url"
  got="$(shasum -a 256 "$dir/src.tar.gz" | cut -d' ' -f1)"
  [[ "$got" == "$want" ]] || die "sha256 mismatch for $url: expected $want, got $got"
}
fetch tmux "https://github.com/tmux/tmux/releases/download/$tmux_v/tmux-$tmux_v.tar.gz"
fetch libevent "https://github.com/libevent/libevent/releases/download/release-$libevent_v/libevent-$libevent_v.tar.gz"
fetch utf8proc "https://github.com/JuliaStrings/utf8proc/releases/download/v$utf8proc_v/utf8proc-$utf8proc_v.tar.gz"

# Nothing from Homebrew or the caller's environment may leak into the link:
# pkg-config sees only our prefix, and compiler search-path variables go.
unset CPATH C_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH CFLAGS LDFLAGS CPPFLAGS
export MACOSX_DEPLOYMENT_TARGET="$min_macos"
# The bare clang (not the xcrun shim) finds the SDK only through SDKROOT.
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
jobs="$(sysctl -n hw.ncpu)"
clang="$(xcrun -f clang)"

# unpack NAME DIR: extract NAME's tarball into a new, empty DIR and print
# the single top-level directory it holds.
unpack() {
  local dir="$2"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xzf "$work/dl-$1/src.tar.gz" -C "$dir"
  local top=("$dir"/*)
  [[ "${#top[@]}" -eq 1 && -d "${top[0]}" ]] || die "$1 tarball has no single top-level directory"
  echo "${top[0]}"
}

build_arch() {
  local arch="$1" root="$work/$arch" prefix="$work/$arch/prefix" src
  local host="$arch-apple-darwin" cc="$clang -arch $arch"
  [[ "$arch" == arm64 ]] && host=aarch64-apple-darwin
  local cflags="-O2 -mmacosx-version-min=$min_macos"
  mkdir -p "$prefix/include" "$prefix/lib/pkgconfig"

  echo "::group::utf8proc $utf8proc_v ($arch)" >&2
  src="$(unpack utf8proc "$root/utf8proc")"
  make -C "$src" -j"$jobs" libutf8proc.a CC="$cc" CFLAGS="$cflags" >&2
  cp "$src/utf8proc.h" "$prefix/include/"
  cp "$src/libutf8proc.a" "$prefix/lib/"
  echo "::endgroup::" >&2

  echo "::group::libevent $libevent_v ($arch)" >&2
  src="$(unpack libevent "$root/libevent")"
  (
    cd "$src"
    ./configure --host="$host" --prefix="$prefix" \
      --disable-shared --enable-static --disable-openssl --disable-mbedtls \
      --disable-samples --disable-libevent-regress --disable-debug-mode \
      CC="$cc" CFLAGS="$cflags"
    make -j"$jobs"
    make install
  ) >&2
  echo "::endgroup::" >&2

  echo "::group::tmux $tmux_v ($arch)" >&2
  src="$(unpack tmux "$root/tmux")"
  (
    cd "$src"
    # --with-TERM: configure otherwise probes the build host's terminfo, so
    # the default-terminal would vary by machine and by arch (cross builds
    # fall back to "screen"). Leo.app ships this entry (A2b).
    # --disable-jemalloc: tmux 3.6 only uses it when asked; keep it explicit.
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" ./configure --host="$host" \
      --enable-utf8proc --disable-jemalloc --with-TERM=tmux-256color \
      CC="$cc" CFLAGS="$cflags" \
      LIBEVENT_CORE_CFLAGS="-I$prefix/include" LIBEVENT_CORE_LIBS="$prefix/lib/libevent_core.a" \
      LIBUTF8PROC_CFLAGS="-I$prefix/include" LIBUTF8PROC_LIBS="$prefix/lib/libutf8proc.a"
    make -j"$jobs"
  ) >&2
  cp "$src/tmux" "$root/tmux.bin"
  echo "::endgroup::" >&2
}

slices=()
for arch in "${archs[@]}"; do
  build_arch "$arch"
  slices+=("$work/$arch/tmux.bin")
done
lipo -create "${slices[@]}" -output "$work/tmux"
chmod 0755 "$work/tmux"
"$here/check-helper.sh" "$work/tmux" "tmux $tmux_v"
mv -f "$work/tmux" "$dest"
echo "build-tmux: $dest"

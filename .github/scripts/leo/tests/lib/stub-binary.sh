# Sourced by test_*.sh: builds real Mach-O stand-ins for the bundled helpers
# (leo, tmux) so lipo, otool and vtool see genuine binaries, not scripts.
#
# make_stub OUT VERSION_ARG VERSION_LINE [ARCH...] [-- EXTRA_CFLAGS...]
#   OUT run with exactly VERSION_ARG prints VERSION_LINE and exits 0; any
#   other invocation exits 2. ARCH defaults to "arm64 x86_64".
make_stub() {
  local out="$1" arg="$2" line="$3"
  shift 3
  local archs=() cflags=()
  while [[ $# -gt 0 && "$1" != -- ]]; do
    archs+=(-arch "$1")
    shift
  done
  [[ "${1:-}" == -- ]] && shift && cflags=("$@")
  [[ "${#archs[@]}" -gt 0 ]] || archs=(-arch arm64 -arch x86_64)

  local src
  src="$(mktemp -d)/stub.c"
  cat > "$src" <<EOF
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "$arg") == 0) {
    puts("$line");
    return 0;
  }
  return 2;
}
EOF
  # --sdk macosx: bare `xcrun clang` falls back to the CLT SDK even under DEVELOPER_DIR.
  xcrun --sdk macosx clang "${archs[@]}" -mmacosx-version-min=13.0 "${cflags[@]+"${cflags[@]}"}" -o "$out" "$src"
  rm -rf "$(dirname "$src")"
}

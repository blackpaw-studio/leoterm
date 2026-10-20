#!/usr/bin/env bash
# Plain-sh tests for fetch-leo.sh. The network is a fake CURL that serves a
# fixture tarball built here from a compiled stub, so nothing is downloaded.
# Run directly:
#   ./test_fetch-leo.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/stub-binary.sh

readonly script="$PWD/../fetch-leo.sh"
readonly url_base=https://github.com/blackpaw-studio/leo/releases/download
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

# Fake curl: writes $FAKE_CURL_FIXTURE to the -o path and logs the URL.
mkdir -p "$work/fakebin"
cat > "$work/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url" >> "$FAKE_CURL_LOG"
cp "$FAKE_CURL_FIXTURE" "$out"
EOF
chmod +x "$work/fakebin/curl"

# tarball NAME VERSION_LINE [ARCH...]: a release-shaped archive with `leo`
# at its root.
tarball() {
  local name="$1" line="$2"
  shift 2
  local dir="$work/tar-$name"
  mkdir -p "$dir"
  make_stub "$dir/leo" version "$line" "$@"
  tar -czf "$work/$name.tar.gz" -C "$dir" leo
  echo "$work/$name.tar.gz"
}
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

good="$(tarball good "leo 0.56.0")"
thin="$(tarball thin "leo 0.56.0" arm64)"
stale="$(tarball stale "leo 0.55.1")"
mkdir -p "$work/tar-noroot/sub"
make_stub "$work/tar-noroot/sub/leo" version "leo 0.56.0"
tar -czf "$work/noroot.tar.gz" -C "$work/tar-noroot" sub
noroot="$work/noroot.tar.gz"
override="$work/override-leo"
make_stub "$override" version "leo 0.57.0-dev"
thin_override="$work/thin-override-leo"
make_stub "$thin_override" version "leo 0.57.0-dev" arm64

# src_root NAME PIN_BODY: a fake source tree holding macos/Bundled/LEO_VERSION.
src_root() {
  local root="$work/src-$1"
  mkdir -p "$root/macos/Bundled"
  [[ -n "$2" ]] && printf '%s\n' "$2" > "$root/macos/Bundled/LEO_VERSION"
  echo "$root"
}
pin() { printf '# comment\nversion=%s\nsha256=%s\n' "$1" "$2"; }

# run NAME SRC FIXTURE [ENV...]: runs the script into $work/out-NAME and
# leaves output in $OUT, status in $RC.
run() {
  local name="$1" src="$2" fixture="$3"
  shift 3
  : > "$work/curl-$name.log"
  OUT="$(env -u LEO_BINARY -u RELEASE_TAG PATH="$work/fakebin:$PATH" \
    FAKE_CURL_FIXTURE="$fixture" FAKE_CURL_LOG="$work/curl-$name.log" \
    SRC_ROOT="$src" "$@" bash "$script" "$work/out-$name" 2>&1)" && RC=0 || RC=$?
  CURL_LOG="$(cat "$work/curl-$name.log")"
}

# -- pin ----------------------------------------------------------------------

run missing "$(src_root missing "")" "$good"
[[ "$RC" -ne 0 && "$OUT" == *LEO_VERSION* ]] && ok=yes || ok=no
result "$ok" "a missing pin fails and names the pin file" "rc=$RC: $OUT"

run vpin "$(src_root vpin "$(pin v0.56.0 "$(sha "$good")")")" "$good"
[[ "$RC" -ne 0 && -z "$CURL_LOG" ]] && ok=yes || ok=no
result "$ok" "a v-prefixed pin version is rejected before any download" "rc=$RC: $OUT"

run shortsha "$(src_root shortsha "$(pin 0.56.0 abc123)")" "$good"
[[ "$RC" -ne 0 && -z "$CURL_LOG" ]] && ok=yes || ok=no
result "$ok" "a pin sha256 that isn't 64 hex chars is rejected before any download" "rc=$RC: $OUT"

# -- download -----------------------------------------------------------------

run good "$(src_root good "$(pin 0.56.0 "$(sha "$good")")")" "$good"
[[ "$RC" -eq 0 ]] && ok=yes || ok=no
result "$ok" "a pinned release with a matching sha256 succeeds" "rc=$RC: $OUT"
[[ "$CURL_LOG" == "$url_base/v0.56.0/leo_0.56.0_darwin_universal.tar.gz" ]] && ok=yes || ok=no
result "$ok" "it downloads the documented darwin_universal URL (v in the tag only)" "got: $CURL_LOG"
[[ -x "$work/out-good/leo" && "$(stat -f %Lp "$work/out-good/leo")" == 755 ]] && ok=yes || ok=no
result "$ok" "OUT_DIR/leo is installed with mode 0755"
[[ "$("$work/out-good/leo" version 2>&1)" == "leo 0.56.0" ]] && ok=yes || ok=no
result "$ok" "OUT_DIR/leo is the archive's binary"

bad_sha="$(printf '0%.0s' {1..64})"
run badsha "$(src_root badsha "$(pin 0.56.0 "$bad_sha")")" "$good"
[[ "$RC" -ne 0 && ! -e "$work/out-badsha/leo" ]] && ok=yes || ok=no
result "$ok" "a sha256 mismatch fails and installs nothing" "rc=$RC"
[[ "$OUT" == *"$bad_sha"* && "$OUT" == *"$(sha "$good")"* ]] && ok=yes || ok=no
result "$ok" "the mismatch message names expected and actual" "$OUT"

run thin "$(src_root thin "$(pin 0.56.0 "$(sha "$thin")")")" "$thin"
[[ "$RC" -ne 0 ]] && ok=yes || ok=no
result "$ok" "a thin (arm64-only) binary is refused" "rc=$RC: $OUT"

run stale "$(src_root stale "$(pin 0.56.0 "$(sha "$stale")")")" "$stale"
[[ "$RC" -ne 0 && "$OUT" == *"leo 0.55.1"* ]] && ok=yes || ok=no
result "$ok" "a binary whose 'leo version' differs from the pin is refused" "rc=$RC: $OUT"

run noroot "$(src_root noroot "$(pin 0.56.0 "$(sha "$noroot")")")" "$noroot"
[[ "$RC" -ne 0 ]] && ok=yes || ok=no
result "$ok" "an archive without leo at its root is refused" "rc=$RC: $OUT"

# -- LEO_BINARY override --------------------------------------------------------

pinned_src="$(src_root override "$(pin 0.56.0 "$(sha "$good")")")"
run override "$pinned_src" "$good" LEO_BINARY="$override"
[[ "$RC" -eq 0 && -z "$CURL_LOG" ]] && ok=yes || ok=no
result "$ok" "LEO_BINARY is used instead of downloading" "rc=$RC: $OUT"
cmp -s "$override" "$work/out-override/leo" && ok=yes || ok=no
result "$ok" "OUT_DIR/leo is the override binary"
[[ "$OUT" == *"::warning::"*LEO_BINARY* ]] && ok=yes || ok=no
result "$ok" "the override emits a ::warning:: naming LEO_BINARY" "$OUT"

run nosha "$(src_root nosha "$(pin 0.56.0 "")")" "$good" LEO_BINARY="$override"
[[ "$RC" -eq 0 ]] && ok=yes || ok=no
result "$ok" "LEO_BINARY works while the pin has no sha256 yet (unreleased leo)" "rc=$RC: $OUT"
run nosharel "$(src_root nosharel "$(pin 0.56.0 "")")" "$good"
[[ "$RC" -ne 0 && -z "$CURL_LOG" && "$OUT" == *"no sha256"* ]] && ok=yes || ok=no
result "$ok" "without LEO_BINARY an empty pin sha256 fails before any download" "rc=$RC: $OUT"

run release "$pinned_src" "$good" LEO_BINARY="$override" RELEASE_TAG=leo-v1.2.3
[[ "$RC" -ne 0 && ! -e "$work/out-release/leo" && -z "$CURL_LOG" ]] && ok=yes || ok=no
result "$ok" "a release build (RELEASE_TAG set) refuses LEO_BINARY" "rc=$RC: $OUT"

run thinoverride "$pinned_src" "$good" LEO_BINARY="$thin_override"
[[ "$RC" -ne 0 ]] && ok=yes || ok=no
result "$ok" "a thin LEO_BINARY is refused too" "rc=$RC: $OUT"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

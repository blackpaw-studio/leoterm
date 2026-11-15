#!/usr/bin/env bash
# Plain-sh tests for build-tmux.sh: pin parsing, the TMUX_BINARY override and
# source checksum enforcement. No real build runs here; downloads come from a
# fake CURL. Run directly:
#   ./test_build-tmux.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/stub-binary.sh

readonly script="$PWD/../build-tmux.sh"
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

# Fake curl: serves $FAKE_CURL_FIXTURE for every URL and logs each URL.
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

junk="$work/junk.tar.gz"
echo "not a tarball" > "$junk"
junk_sha="$(shasum -a 256 "$junk" | cut -d' ' -f1)"
other_sha="$(printf 'a%.0s' {1..64})"

stub="$work/stub/tmux"
mkdir -p "$work/stub" "$work/stale"
make_stub "$stub" -V "tmux 3.6b"
make_stub "$work/stale/tmux" -V "tmux 3.5a"

# pin TMUX LIBEVENT UTF8PROC SHA_TMUX SHA_LIBEVENT SHA_UTF8PROC
pin() {
  printf '# comment\ntmux_version=%s\nlibevent_version=%s\nutf8proc_version=%s\n' "$1" "$2" "$3"
  printf 'tmux_sha256=%s\nlibevent_sha256=%s\nutf8proc_sha256=%s\n' "$4" "$5" "$6"
}
src_root() {
  local root="$work/src-$1"
  mkdir -p "$root/macos/Bundled"
  [[ -n "$2" ]] && printf '%s\n' "$2" > "$root/macos/Bundled/TMUX_VERSION"
  echo "$root"
}

# run NAME SRC [ENV...]: output in $OUT, status in $RC, URLs in $CURL_LOG.
run() {
  local name="$1" src="$2"
  shift 2
  : > "$work/curl-$name.log"
  OUT="$(env -u TMUX_BINARY PATH="$work/fakebin:$PATH" \
    FAKE_CURL_FIXTURE="$junk" FAKE_CURL_LOG="$work/curl-$name.log" \
    SRC_ROOT="$src" "$@" bash "$script" "$work/out-$name" 2>&1)" && RC=0 || RC=$?
  CURL_LOG="$(cat "$work/curl-$name.log")"
}

good_pin="$(pin 3.6b 2.1.13-stable 2.12.0 "$junk_sha" "$junk_sha" "$junk_sha")"

# -- pin ----------------------------------------------------------------------

run missing "$(src_root missing "")"
[[ "$RC" -ne 0 && "$OUT" == *TMUX_VERSION* && -z "$CURL_LOG" ]] && ok=yes || ok=no
result "$ok" "a missing pin fails and names the pin file" "rc=$RC: $OUT"

run nosha "$(src_root nosha "$(pin 3.6b 2.1.13-stable 2.12.0 "$junk_sha" "$junk_sha" "")")"
[[ "$RC" -ne 0 && "$OUT" == *utf8proc_sha256* && -z "$CURL_LOG" ]] && ok=yes || ok=no
result "$ok" "a missing component sha256 fails before any download, naming the key" "rc=$RC: $OUT"

run badver "$(src_root badver "$(pin '3.6b;rm' 2.1.13-stable 2.12.0 "$junk_sha" "$junk_sha" "$junk_sha")")"
[[ "$RC" -ne 0 && -z "$CURL_LOG" ]] && ok=yes || ok=no
result "$ok" "a malformed version is rejected before any download" "rc=$RC: $OUT"

run badlibevent "$(src_root badlibevent "$(pin 3.6b 2.1.13 2.12.0 "$junk_sha" "$junk_sha" "$junk_sha")")"
[[ "$RC" -ne 0 && -z "$CURL_LOG" ]] && ok=yes || ok=no
result "$ok" "a libevent version without the -stable suffix is rejected" "rc=$RC: $OUT"

# -- TMUX_BINARY override -------------------------------------------------------

run override "$(src_root override "$good_pin")" TMUX_BINARY="$stub"
[[ "$RC" -eq 0 && -z "$CURL_LOG" ]] && ok=yes || ok=no
result "$ok" "TMUX_BINARY is used instead of building" "rc=$RC: $OUT"
cmp -s "$stub" "$work/out-override/tmux" && [[ "$(stat -f %Lp "$work/out-override/tmux")" == 755 ]] \
  && ok=yes || ok=no
result "$ok" "OUT_DIR/tmux is the override, mode 0755"

run stale "$(src_root stale "$good_pin")" TMUX_BINARY="$work/stale/tmux"
[[ "$RC" -ne 0 && ! -e "$work/out-stale/tmux" ]] && ok=yes || ok=no
result "$ok" "a TMUX_BINARY whose -V differs from the pin is refused (a stale cache)" "rc=$RC: $OUT"

# -- sources ----------------------------------------------------------------------

run mismatch "$(src_root mismatch "$(pin 3.6b 2.1.13-stable 2.12.0 "$other_sha" "$junk_sha" "$junk_sha")")"
[[ "$RC" -ne 0 && ! -e "$work/out-mismatch/tmux" ]] && ok=yes || ok=no
result "$ok" "a source sha256 mismatch fails and builds nothing" "rc=$RC"
[[ "$OUT" == *"$other_sha"* && "$OUT" == *"$junk_sha"* && "$OUT" == *tmux-3.6b.tar.gz* ]] && ok=yes || ok=no
result "$ok" "the mismatch names the tarball, expected and actual" "$OUT"

run urls "$(src_root urls "$good_pin")"
want="https://github.com/tmux/tmux/releases/download/3.6b/tmux-3.6b.tar.gz
https://github.com/libevent/libevent/releases/download/release-2.1.13-stable/libevent-2.1.13-stable.tar.gz
https://github.com/JuliaStrings/utf8proc/releases/download/v2.12.0/utf8proc-2.12.0.tar.gz"
[[ "$CURL_LOG" == "$want" ]] && ok=yes || ok=no
result "$ok" "every pinned source is downloaded and verified before building" "got: $CURL_LOG"
[[ "$RC" -ne 0 ]] && ok=yes || ok=no
result "$ok" "a source that isn't a tarball fails the build" "rc=$RC"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

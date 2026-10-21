#!/usr/bin/env bash
# Plain-sh tests for bump-leo.sh. The network is a fake CURL that serves a
# fixture checksums.txt, so nothing is downloaded. Run directly:
#   ./test_bump-leo.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly script="$PWD/../bump-leo.sh"
readonly url_base=https://github.com/blackpaw-studio/leo/releases/download
readonly sha_old=75909e87e30f27a0842b4ed617aa6527adbddad43d690e612b848a06beabc79c
readonly sha_new=1111111111111111111111111111111111111111111111111111111111111111
readonly sha_other=2222222222222222222222222222222222222222222222222222222222222222
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

# Fake curl: logs the URL, serves $FAKE_CURL_FIXTURE to the -o path, or fails
# when it is unset.
cat > "$work/curl" <<'FAKE'
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
[[ -n "${FAKE_CURL_FIXTURE:-}" ]] || exit 22
cp "$FAKE_CURL_FIXTURE" "$out"
FAKE
chmod +x "$work/curl"

pin_text() {
  cat <<PIN
# header comment
# second comment line
version=$1
sha256=$2
PIN
}

# checksums VERSION SHA: a goreleaser-style checksums.txt.
checksums() {
  cat > "$work/checksums.txt" <<SUMS
$sha_other  leo_$1_linux_amd64.tar.gz
$2  leo_$1_darwin_universal.tar.gz
$sha_other  leo_$1_windows_amd64.zip
SUMS
}

# run VERSION SHA [fixture]: fresh source root pinned at 0.56.1, so each case
# sees the same starting pin. Status in $rc, pin in $root.
run() {
  root="$work/src"
  rm -rf "$root"
  mkdir -p "$root/macos/Bundled"
  pin_text 0.56.1 "$sha_old" > "$root/macos/Bundled/LEO_VERSION"
  : > "$work/curl.log"
  : > "$work/gh.out"
  rc=0
  env SRC_ROOT="$root" CURL="$work/curl" FAKE_CURL_LOG="$work/curl.log" \
    FAKE_CURL_FIXTURE="${3-}" GITHUB_OUTPUT="$work/gh.out" \
    bash "$script" "$1" "$2" > "$work/run.out" 2>&1 || rc=$?
}

pin_unchanged() { [[ "$(cat "$root/macos/Bundled/LEO_VERSION")" == "$(pin_text 0.56.1 "$sha_old")" ]]; }
no_network() { [[ ! -s "$work/curl.log" ]]; }

checksums 0.56.2 "$sha_new"

for v in "1.0.0;rm -rf" v1.0.0 1.0 "1.0.0 " "\$(id).0.0" ""; do
  run "$v" "$sha_new" "$work/checksums.txt"
  [[ "$rc" -ne 0 ]] && pin_unchanged && no_network && ok=yes || ok=no
  result "$ok" "rejects version '$v' before any network or write" "rc=$rc"
done

for s in abc123 "${sha_old^^}" "${sha_new}0" "${sha_new:0:63}" "${sha_new:0:63}g" ""; do
  run 0.56.2 "$s" "$work/checksums.txt"
  [[ "$rc" -ne 0 ]] && pin_unchanged && no_network && ok=yes || ok=no
  result "$ok" "rejects sha256 '${s:0:20}' before any network or write" "rc=$rc"
done

run 0.56.2 "$sha_other" "$work/checksums.txt"
[[ "$rc" -ne 0 ]] && pin_unchanged && grep -q 'mismatch' "$work/run.out" && ok=yes || ok=no
result "$ok" "a sha that differs from checksums.txt is refused" "rc=$rc: $(tail -2 "$work/run.out")"
grep -qx "$url_base/v0.56.2/checksums.txt" "$work/curl.log" && ok=yes || ok=no
result "$ok" "...by checking that release's checksums.txt" "$(cat "$work/curl.log")"

# The sha is listed, but for a different asset: still wrong.
cat > "$work/checksums-wrong-asset.txt" <<SUMS
$sha_new  leo_0.56.2_linux_amd64.tar.gz
SUMS
run 0.56.2 "$sha_new" "$work/checksums-wrong-asset.txt"
[[ "$rc" -ne 0 ]] && pin_unchanged && ok=yes || ok=no
result "$ok" "a sha listed only for another asset is refused" "rc=$rc"

run 0.56.2 "$sha_new" ""
[[ "$rc" -ne 0 ]] && pin_unchanged && ok=yes || ok=no
result "$ok" "a failed checksums.txt download fails and leaves the pin alone" "rc=$rc"

run 0.56.2 "$sha_new" "$work/checksums.txt"
want="$(pin_text 0.56.2 "$sha_new")"
[[ "$rc" -eq 0 && "$(cat "$root/macos/Bundled/LEO_VERSION")" == "$want" ]] && ok=yes || ok=no
result "$ok" "a verified newer release rewrites exactly version= and sha256=" "rc=$rc: $(cat "$root/macos/Bundled/LEO_VERSION")"
grep -qx 'bump=true' "$work/gh.out" && grep -qx 'version=0.56.2' "$work/gh.out" && ok=yes || ok=no
result "$ok" "...and reports bump=true and the version via GITHUB_OUTPUT" "$(cat "$work/gh.out")"

checksums 0.57.0 "$sha_new"
run 0.57.0 "$sha_new" "$work/checksums.txt"
[[ "$rc" -eq 0 ]] && grep -qx 'version=0.57.0' "$root/macos/Bundled/LEO_VERSION" && ok=yes || ok=no
result "$ok" "a minor bump works" "rc=$rc"

run 0.56.1 "$sha_old" "$work/checksums.txt"
[[ "$rc" -eq 0 ]] && pin_unchanged && no_network && grep -qx 'bump=false' "$work/gh.out" && ok=yes || ok=no
result "$ok" "the pinned version again is a no-op (bump=false, no network)" "rc=$rc"

run 0.56.0 "$sha_new" "$work/checksums.txt"
[[ "$rc" -eq 0 ]] && pin_unchanged && no_network && grep -qx 'bump=false' "$work/gh.out" && ok=yes || ok=no
result "$ok" "an older version is a no-op (bump=false, no network)" "rc=$rc"

run 0.56.1 "$sha_new" "$work/checksums.txt"
[[ "$rc" -ne 0 ]] && pin_unchanged && ok=yes || ok=no
result "$ok" "the pinned version with a different sha is an error" "rc=$rc"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

#!/usr/bin/env bash
# Copies crash evidence into one flat directory so the upload step can glob
# a plain path instead of `~`: usage collect-crash-evidence.sh OUT_DIR.
#
#   OUT/DiagnosticReports/  .ips / .crash reports from the test host (macOS
#                           writes these when the host traps).
#   OUT/sentry/<n>/         Ghostty's sentry database (minidumps live in
#                           <run>.run/*.envelope). Location, per
#                           src/crash/sentry.zig cacheDir: with XDG_CACHE_HOME
#                           set, NSCachesDirectory/<bundle id>/sentry (the test
#                           host's id is studio.blackpaw.leo.macos.debug);
#                           otherwise the XDG cache, ~/.cache/ghostty/sentry.
#                           Every ~/Library/Caches/*/sentry is copied, as is
#                           each XDG location.
#
# Always exits 0: this runs on a failing job and must never mask its cause.
# HOME overrides the home directory (for tests).
set -uo pipefail

out="${1:?usage: collect-crash-evidence.sh OUT_DIR}"
home="${HOME:?}"
mkdir -p "$out"

copy_dir() {
  local src="$1" dest="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dest"
  cp -R "$src"/. "$dest"/ 2>/dev/null || true
}

copy_dir "$home/Library/Logs/DiagnosticReports" "$out/DiagnosticReports"

n=0
candidates=("$home/.cache/ghostty/sentry")
[[ -n "${XDG_CACHE_HOME:-}" ]] && candidates+=("$XDG_CACHE_HOME/ghostty/sentry")
for d in "$home"/Library/Caches/*/sentry; do
  candidates+=("$d")
done
for src in "${candidates[@]}"; do
  [[ -d "$src" ]] || continue
  n=$((n + 1))
  copy_dir "$src" "$out/sentry/$n"
  echo "$src" >"$out/sentry/$n.source"
done
exit 0

#!/bin/bash
# Copy every first-party plugin under Bundled/Plugins/<id>/ that has a
# leo-plugin.json into the app bundle's Resources/Plugins/<id>/. Run by the
# "Bundle Leo plugins" build phase. A folder without a manifest (a .gitkeep, a
# half-built plugin) is skipped. The destination is rebuilt each run, so a
# plugin removed from the source folder leaves the bundle too.
# Usage: leo-bundle-plugins.sh SOURCE_DIR OUT_DIR
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: leo-bundle-plugins.sh SOURCE_DIR OUT_DIR" >&2; exit 2; }
src="$1" out="$2"
[[ -d "$src" ]] || { echo "error: leo-bundle-plugins: no such source $src" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"
for dir in "$src"/*/; do
  [[ -f "${dir}leo-plugin.json" ]] || continue
  id="$(basename "$dir")"
  # -L is deliberately absent: a symlink in a plugin stays a symlink, and the
  # app's loader refuses one that leaves the folder.
  /usr/bin/ditto "$dir" "$out/$id"
done

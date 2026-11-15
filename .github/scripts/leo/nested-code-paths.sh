#!/usr/bin/env bash
# Print Leo.app's code in the order it must be signed: inside-out, every
# nested item before whatever contains it, and the app itself last.
# Usage: nested-code-paths.sh APP
#
# Sparkle's and the Dock tile plugin's paths are fixed and always listed (a
# missing one should fail signing loudly). Everything in Contents/Helpers is
# listed, whatever it is called (leo, tmux, LeoPluginHost, ...), so a helper
# the Xcode build adds later cannot ship unsigned; refs from before the
# helpers simply list none. check-bundle.sh requires leo and tmux for any app
# that carries a LeoDaemonLabel and checks every helper it finds.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: nested-code-paths.sh APP" >&2; exit 2; }
app="$1"
sparkle="$app/Contents/Frameworks/Sparkle.framework"

# The XPC services are unused (Leo is not sandboxed) but still shipped.
printf '%s\n' \
  "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
  "$sparkle/Versions/B/XPCServices/Installer.xpc" \
  "$sparkle/Versions/B/Autoupdate" \
  "$sparkle/Versions/B/Updater.app" \
  "$sparkle" \
  "$app/Contents/PlugIns/DockTilePlugin.plugin"
# codesign follows symlinks, so a linked helper would have the signer rewrite
# a file outside the bundle: every entry must be a regular file. Checked
# before anything is printed, so a rejected bundle lists nothing.
# The same goes for the directories on the way: a symlinked Contents or
# Contents/Helpers would walk the per-entry checks straight out of the bundle,
# so both must be real directories whose resolved path sits inside the bundle.
for dir in "$app/Contents" "$app/Contents/Helpers"; do
  if [[ -L "$dir" ]]; then
    echo "::error::nested-code-paths: $dir is a symlink" >&2
    exit 1
  fi
done
if [[ -d "$app/Contents/Helpers" ]]; then
  real_app="$(cd -P "$app" && pwd)"
  real_helpers="$(cd -P "$app/Contents/Helpers" && pwd)"
  if [[ "$real_helpers" != "$real_app/Contents/Helpers" ]]; then
    echo "::error::nested-code-paths: $app/Contents/Helpers resolves outside the bundle ($real_helpers)" >&2
    exit 1
  fi
fi
shopt -s dotglob nullglob
helpers=("$app"/Contents/Helpers/*)
for helper in ${helpers[@]+"${helpers[@]}"}; do
  if [[ -L "$helper" || ! -f "$helper" ]]; then
    echo "::error::nested-code-paths: $helper is a symlink or not a regular file" >&2
    exit 1
  fi
done
# The glob expands sorted, so the order is stable; helpers don't depend on
# each other, only on being signed before the app.
for helper in ${helpers[@]+"${helpers[@]}"}; do
  echo "$helper"
done
echo "$app"

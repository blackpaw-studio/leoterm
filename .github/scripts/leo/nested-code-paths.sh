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
# The glob expands sorted, so the order is stable; helpers don't depend on
# each other, only on being signed before the app.
for helper in "$app"/Contents/Helpers/*; do
  [[ -e "$helper" ]] && echo "$helper"
done
echo "$app"

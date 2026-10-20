#!/usr/bin/env bash
# Print Leo.app's code in the order it must be signed: inside-out, every
# nested item before whatever contains it, and the app itself last.
# Usage: nested-code-paths.sh APP
#
# Sparkle's and the Dock tile plugin's paths are fixed and always listed (a
# missing one should fail signing loudly). The bundled helpers are listed
# only when present, so refs from before them still sign; check-bundle.sh
# requires them for any app that carries a LeoDaemonLabel.
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
for helper in tmux leo; do
  [[ -e "$app/Contents/Helpers/$helper" ]] && echo "$app/Contents/Helpers/$helper"
done
echo "$app"

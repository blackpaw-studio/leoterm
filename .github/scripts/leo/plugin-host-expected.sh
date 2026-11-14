#!/usr/bin/env bash
# Print "yes" if the source tree builds and embeds LeoPluginHost, else "no".
# Usage: plugin-host-expected.sh PROJECT_PBXPROJ
#
# The answer comes from the source being built, never from the bundle being
# checked (a bundle that lost the helper must not be able to excuse itself).
# An unreadable project fails closed: "yes".
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: plugin-host-expected.sh PROJECT_PBXPROJ" >&2; exit 2; }
# grep exits 1 for "no match" and >= 2 for a read error (a directory, an I/O
# failure); only a clean no-match may say "no".
status=0
[[ -r "$1" ]] && { grep -q LeoPluginHost "$1" || status=$?; } || status=2
if [[ "$status" -eq 1 ]]; then
  echo no
else
  echo yes
fi

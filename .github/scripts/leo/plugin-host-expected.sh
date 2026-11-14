#!/usr/bin/env bash
# Print "yes" if the source tree builds and embeds LeoPluginHost, else "no".
# Usage: plugin-host-expected.sh PROJECT_PBXPROJ
#
# The answer comes from the source being built, never from the bundle being
# checked (a bundle that lost the helper must not be able to excuse itself).
# An unreadable project fails closed: "yes".
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: plugin-host-expected.sh PROJECT_PBXPROJ" >&2; exit 2; }
if [[ -r "$1" ]] && ! grep -q LeoPluginHost "$1"; then
  echo no
else
  echo yes
fi

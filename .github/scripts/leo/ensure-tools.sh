#!/usr/bin/env bash
# Install, via Homebrew, any tool a fresh Ghast VM lacks. Idempotent: a tool
# already on PATH is left alone. Each argument is `command` or `command=formula`.
# Usage: ensure-tools.sh gh jq pkg-config python3=python@3.13
set -euo pipefail

missing=()
for spec in "$@"; do
  cmd="${spec%%=*}"
  formula="${spec#*=}"
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$formula")
done

if [[ "${#missing[@]}" -eq 0 ]]; then
  echo "all tools present: $*"
  exit 0
fi
echo "installing: ${missing[*]}"
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install "${missing[@]}"

#!/usr/bin/env bash
# Put Homebrew OpenSSL 3 first on PATH for later steps when the default
# `openssl` is not 3.x (macOS LibreSSL can't derive Ed25519 keys).
set -euo pipefail

if openssl version | grep -q '^OpenSSL 3'; then exit 0; fi
brew list openssl@3 >/dev/null 2>&1 || HOMEBREW_NO_AUTO_UPDATE=1 brew install openssl@3
echo "$(brew --prefix openssl@3)/bin" >> "${GITHUB_PATH:-/dev/stdout}"

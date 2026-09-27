#!/usr/bin/env bash
# Create (or tear down) a per-job signing keychain in $RUNNER_TEMP from
# GitHub secrets. Nothing here depends on persistent state on the runner:
# the keychain, the decoded .p12 and the search-list backup all live under
# $RUNNER_TEMP and are gone once the job ends.
#
#   keychain.sh create   decode MACOS_CERTIFICATE, import it, prepend the
#                         keychain to the search list, export LEO_KEYCHAIN
#   keychain.sh cleanup  delete the keychain, restore the original search
#                         list, remove any leftover temp key files
#
# Env (create): MACOS_CERTIFICATE (base64-encoded .p12), MACOS_CERTIFICATE_PWD,
#               MACOS_CI_KEYCHAIN_PWD, RUNNER_TEMP, GITHUB_ENV.
# Env (cleanup): RUNNER_TEMP.
set -euo pipefail

: "${RUNNER_TEMP:?}"
keychain="$RUNNER_TEMP/leo-signing.keychain-db"
saved_list="$RUNNER_TEMP/leo-keychain-search-list"

current_list() { security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/'; }

create() {
  : "${MACOS_CERTIFICATE:?}" "${MACOS_CERTIFICATE_PWD:?}" "${MACOS_CI_KEYCHAIN_PWD:?}"
  local p12="$RUNNER_TEMP/leo-cert.p12"
  echo "$MACOS_CERTIFICATE" | base64 --decode > "$p12"

  security create-keychain -p "$MACOS_CI_KEYCHAIN_PWD" "$keychain"
  security set-keychain-settings "$keychain"
  security unlock-keychain -p "$MACOS_CI_KEYCHAIN_PWD" "$keychain"
  security import "$p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PWD" -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$MACOS_CI_KEYCHAIN_PWD" "$keychain"
  rm -f "$p12"

  current_list > "$saved_list"
  local others=()
  while IFS= read -r kc; do
    [[ -n "$kc" && "$kc" != "$keychain" ]] && others+=("$kc")
  done < "$saved_list"
  security list-keychains -d user -s "$keychain" ${others[@]+"${others[@]}"}

  [[ -n "${GITHUB_ENV:-}" ]] && echo "LEO_KEYCHAIN=$keychain" >> "$GITHUB_ENV"
  security list-keychains -d user
}

cleanup() {
  if [[ -f "$saved_list" ]]; then
    local list=()
    while IFS= read -r kc; do [[ -n "$kc" ]] && list+=("$kc"); done < "$saved_list"
    security list-keychains -d user -s ${list[@]+"${list[@]}"}
    rm -f "$saved_list"
  fi
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -f "$RUNNER_TEMP/leo-cert.p12" "$RUNNER_TEMP/leo-notary-key.p8" "$RUNNER_TEMP/leo-sparkle-key.txt"
  security list-keychains -d user
}

case "${1:-}" in
  create) create ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 create|cleanup" >&2; exit 2 ;;
esac

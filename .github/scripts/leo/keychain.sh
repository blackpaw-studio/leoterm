#!/usr/bin/env bash
# Create (or tear down) a per-job signing keychain in $RUNNER_TEMP from
# GitHub secrets. Nothing here depends on persistent state on the runner:
# the keychain, the decoded .p12 and the search-list backup all live under
# a per-job mktemp -d in $RUNNER_TEMP and are gone once the job ends.
#
#   keychain.sh create   decode MACOS_CERTIFICATE, import it, prepend the
#                         keychain to the search list, export LEO_KEYCHAIN
#   keychain.sh cleanup  delete the keychain, restore the original search
#                         list, remove the whole per-job temp dir
#
# create and cleanup run as separate workflow steps (separate script
# invocations), so create hands the temp dir's path to cleanup via
# LEO_KEYCHAIN (GITHUB_ENV) rather than a shell variable.
#
# cleanup must not abort partway through: if restoring the keychain search
# list fails, the keychain and temp files still need to go, so cleanup
# turns off `set -e` for its own body instead of relying on the global trap.
#
# Env (create): MACOS_CERTIFICATE (base64-encoded .p12), MACOS_CERTIFICATE_PWD,
#               MACOS_CI_KEYCHAIN_PWD, RUNNER_TEMP, GITHUB_ENV.
# Env (cleanup): LEO_KEYCHAIN (set by create via GITHUB_ENV), RUNNER_TEMP.
set -euo pipefail
umask 077

current_list() { security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/'; }

create() {
  : "${RUNNER_TEMP:?}" "${MACOS_CERTIFICATE:?}" "${MACOS_CERTIFICATE_PWD:?}" "${MACOS_CI_KEYCHAIN_PWD:?}"
  local workdir keychain p12 saved_list
  workdir="$(mktemp -d "$RUNNER_TEMP/leo-signing.XXXXXX")"
  keychain="$workdir/leo-signing.keychain-db"
  p12="$workdir/leo-cert.p12"
  saved_list="$workdir/leo-keychain-search-list"

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

  # LEO_KEYCHAIN doubles as the handle cleanup uses to find this job's temp
  # dir (saved_list and any leftover secret files live alongside it).
  [[ -n "${GITHUB_ENV:-}" ]] && echo "LEO_KEYCHAIN=$keychain" >> "$GITHUB_ENV"
  security list-keychains -d user
}

cleanup() {
  # No `set -e` in here: every step below must run even if an earlier one
  # fails (e.g. restoring the search list), so the keychain and temp files
  # are always removed.
  set +e
  local keychain="${LEO_KEYCHAIN:-}"
  local workdir="" saved_list=""
  if [[ -n "$keychain" ]]; then
    workdir="$(dirname "$keychain")"
    saved_list="$workdir/leo-keychain-search-list"
  fi

  if [[ -n "$saved_list" && -f "$saved_list" ]]; then
    local list=()
    while IFS= read -r kc; do [[ -n "$kc" ]] && list+=("$kc"); done < "$saved_list"
    security list-keychains -d user -s ${list[@]+"${list[@]}"} \
      || echo "::warning::Failed to restore the original keychain search list" >&2
  fi

  if [[ -n "$keychain" ]]; then
    security delete-keychain "$keychain" 2>/dev/null \
      || echo "::warning::Failed to delete $keychain" >&2
  fi

  if [[ -n "$workdir" ]]; then
    rm -rf "$workdir" || echo "::warning::Failed to remove $workdir" >&2
  fi

  # Other scripts (check-signing.sh, sign-package.sh) may leave a notary or
  # Sparkle key file directly under RUNNER_TEMP if they fail before their
  # own cleanup runs; sweep those too.
  if [[ -n "${RUNNER_TEMP:-}" ]]; then
    rm -f "$RUNNER_TEMP/leo-notary-key.p8" "$RUNNER_TEMP/leo-sparkle-key.txt"
  fi

  security list-keychains -d user
  return 0
}

case "${1:-}" in
  create) create ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 create|cleanup" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# Confine Xcode's automatic signing for the iOS TestFlight job to this job.
# Automatic provisioning (-allowProvisioningUpdates) writes the signing
# certificate and its private key to the default keychain and downloads
# provisioning profiles into the user's profile directories. On the shared
# runner both would otherwise outlive the job.
#
#   ios-signing.sh create   make a throwaway keychain with a random password,
#                            put it first in the search list and make it the
#                            default, and snapshot the profile directories.
#                            Exports LEO_IOS_KEYCHAIN (GITHUB_ENV).
#   ios-signing.sh cleanup  restore the search list and default keychain,
#                            delete the keychain, remove profiles added since
#                            the snapshot, remove the per-job temp dir.
#
# create and cleanup run as separate steps; create hands the temp dir to
# cleanup via LEO_IOS_KEYCHAIN (see keychain.sh, which this mirrors).
# Env: RUNNER_TEMP, GITHUB_ENV (create).
set -euo pipefail
umask 077

PROFILE_DIRS=(
  "$HOME/Library/MobileDevice/Provisioning Profiles"
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
)

current_list() { security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/'; }
current_default() { security default-keychain -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/'; }

snapshot_profiles() {
  local out="$1" dir
  : > "$out"
  for dir in "${PROFILE_DIRS[@]}"; do
    [[ -d "$dir" ]] && find "$dir" -type f >> "$out"
  done
  return 0
}

create() {
  : "${RUNNER_TEMP:?}"
  local workdir keychain password others=() kc
  workdir="$(mktemp -d "$RUNNER_TEMP/leo-ios-signing.XXXXXX")"
  keychain="$workdir/leo-ios.keychain-db"

  # Register the handle before creating anything so a partial create is
  # still cleaned up.
  [[ -n "${GITHUB_ENV:-}" ]] && echo "LEO_IOS_KEYCHAIN=$keychain" >> "$GITHUB_ENV"

  current_list > "$workdir/search-list"
  current_default > "$workdir/default-keychain"
  snapshot_profiles "$workdir/profiles-before"

  password="$(openssl rand -hex 24)"
  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings "$keychain"
  security unlock-keychain -p "$password" "$keychain"

  while IFS= read -r kc; do
    [[ -n "$kc" && "$kc" != "$keychain" ]] && others+=("$kc")
  done < "$workdir/search-list"
  security list-keychains -d user -s "$keychain" ${others[@]+"${others[@]}"}
  security default-keychain -d user -s "$keychain"

  security list-keychains -d user
}

cleanup() {
  # Every step must run even if an earlier one fails.
  set +e
  local keychain="${LEO_IOS_KEYCHAIN:-}" workdir="" file dir
  [[ -n "$keychain" ]] && workdir="$(dirname "$keychain")"

  if [[ -n "$workdir" && -f "$workdir/search-list" ]]; then
    local list=() kc
    while IFS= read -r kc; do [[ -n "$kc" ]] && list+=("$kc"); done < "$workdir/search-list"
    security list-keychains -d user -s ${list[@]+"${list[@]}"} \
      || echo "::warning::Failed to restore the keychain search list" >&2
  fi
  if [[ -n "$workdir" && -s "$workdir/default-keychain" ]]; then
    security default-keychain -d user -s "$(cat "$workdir/default-keychain")" \
      || echo "::warning::Failed to restore the default keychain" >&2
  fi
  if [[ -n "$keychain" ]]; then
    security delete-keychain "$keychain" 2>/dev/null \
      || echo "::warning::Failed to delete $keychain" >&2
  fi

  # Profiles Xcode downloaded during this job (not in the snapshot).
  if [[ -n "$workdir" && -f "$workdir/profiles-before" ]]; then
    snapshot_profiles "$workdir/profiles-after"
    while IFS= read -r file; do
      [[ -n "$file" ]] && ! grep -qxF -- "$file" "$workdir/profiles-before" && rm -f -- "$file"
    done < "$workdir/profiles-after"
  fi

  [[ -n "$workdir" ]] && { rm -rf "$workdir" || echo "::warning::Failed to remove $workdir" >&2; }
  security list-keychains -d user
  return 0
}

case "${1:-}" in
  create) create ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 create|cleanup" >&2; exit 2 ;;
esac

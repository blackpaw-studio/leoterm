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
# Everything cleanup restores is captured (and validated) before create
# changes anything, and written atomically, so a failed capture aborts the
# step instead of leaving an empty file that cleanup would "restore". If a
# capture is missing, cleanup only removes our own keychain from the current
# list and deletes no profiles.
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

strip_quotes() { sed -E 's/^[[:space:]]*"(.*)"$/\1/'; }

# Print the user keychain search list / default keychain, one path per line.
# Fails (non-zero, no output on stdout) if `security` fails or prints nothing.
current_list() {
  local out
  out="$(security list-keychains -d user)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out" | strip_quotes
}
current_default() {
  local out
  out="$(security default-keychain -d user)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out" | strip_quotes
}

# Print every provisioning profile file path. A missing directory is an
# empty snapshot; a failing `find` is an error.
list_profiles() {
  local dir
  for dir in "${PROFILE_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    find "$dir" -type f || return 1
  done
}

# Write "$2" (a string) to "$1" atomically; the file only exists complete.
write_atomic() {
  local tmp="$1.tmp"
  printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"
}

create() {
  : "${RUNNER_TEMP:?}"
  local workdir keychain password list default profiles others=() kc
  workdir="$(mktemp -d "$RUNNER_TEMP/leo-ios-signing.XXXXXX")"
  keychain="$workdir/leo-ios.keychain-db"

  # Register the handle before creating anything so a partial create is
  # still cleaned up.
  [[ -n "${GITHUB_ENV:-}" ]] && echo "LEO_IOS_KEYCHAIN=$keychain" >> "$GITHUB_ENV"

  # Capture and validate all state before changing any of it (each of these
  # aborts the step under `set -e` if it fails).
  list="$(current_list)"
  default="$(current_default)"
  profiles="$(list_profiles)"
  write_atomic "$workdir/search-list" "$list"
  write_atomic "$workdir/default-keychain" "$default"
  write_atomic "$workdir/profiles-before" "$profiles"

  password="$(openssl rand -hex 24)"
  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings "$keychain"
  security unlock-keychain -p "$password" "$keychain"

  while IFS= read -r kc; do
    [[ -n "$kc" && "$kc" != "$keychain" ]] && others+=("$kc")
  done <<< "$list"
  security list-keychains -d user -s "$keychain" ${others[@]+"${others[@]}"}
  security default-keychain -d user -s "$keychain"

  security list-keychains -d user
}

# Restore the keychain search list and default. With a valid capture, put it
# back; otherwise take only our keychain out of whatever is there now.
restore_keychains() {
  local keychain="$1" workdir="$2" list=() kc current
  local saved_list="$workdir/search-list" saved_default="$workdir/default-keychain"

  if [[ -s "$saved_list" ]]; then
    while IFS= read -r kc; do [[ -n "$kc" ]] && list+=("$kc"); done < "$saved_list"
  elif current="$(current_list)"; then
    while IFS= read -r kc; do
      [[ -n "$kc" && "$kc" != "$keychain" ]] && list+=("$kc")
    done <<< "$current"
  fi
  if (( ${#list[@]} > 0 )); then
    security list-keychains -d user -s "${list[@]}" \
      || echo "::warning::Failed to restore the keychain search list" >&2
  else
    echo "::warning::No keychain search list to restore; leaving it untouched" >&2
  fi

  if [[ -s "$saved_default" ]]; then
    security default-keychain -d user -s "$(head -n1 "$saved_default")" \
      || echo "::warning::Failed to restore the default keychain" >&2
  elif [[ "$(current_default)" == "$keychain" && ${#list[@]} -gt 0 ]]; then
    security default-keychain -d user -s "${list[0]}" \
      || echo "::warning::Failed to reset the default keychain" >&2
  fi
}

# Remove profiles added since the snapshot. Only runs with a completed
# before-snapshot and a successful after-listing; never deletes otherwise.
remove_new_profiles() {
  local workdir="$1" before="$1/profiles-before" after file
  if [[ ! -f "$before" ]]; then
    echo "::warning::No profile snapshot; leaving provisioning profiles untouched" >&2
    return 0
  fi
  if ! after="$(list_profiles)"; then
    echo "::warning::Could not list provisioning profiles; leaving them untouched" >&2
    return 0
  fi
  while IFS= read -r file; do
    [[ -n "$file" ]] && ! grep -qxF -- "$file" "$before" && rm -f -- "$file"
  done <<< "$after"
  return 0
}

cleanup() {
  # Every step must run even if an earlier one fails.
  set +e
  local keychain="${LEO_IOS_KEYCHAIN:-}" workdir=""
  if [[ -z "$keychain" ]]; then
    echo "::warning::LEO_IOS_KEYCHAIN not set; nothing to clean up" >&2
    return 0
  fi
  workdir="$(dirname "$keychain")"

  restore_keychains "$keychain" "$workdir"
  security delete-keychain "$keychain" 2>/dev/null \
    || echo "::warning::Failed to delete $keychain" >&2
  remove_new_profiles "$workdir"
  rm -rf "$workdir" || echo "::warning::Failed to remove $workdir" >&2

  security list-keychains -d user
  return 0
}

case "${1:-}" in
  create) create ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 create|cleanup" >&2; exit 2 ;;
esac

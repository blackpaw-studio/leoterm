#!/usr/bin/env bash
# Is semver A strictly greater than semver B?
# Usage: semver-gt.sh A B
# Exit:  0 A > B    1 A <= B    2 bad input (not strict X.Y.Z, or wrong argument count)
# Versions are bare X.Y.Z, the same shape as macos/Bundled/LEO_VERSION. Parts
# are compared as digit strings (leading zeros stripped, longer is bigger), so
# there is no octal or integer-overflow surprise.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: semver-gt.sh A B" >&2; exit 2; }

readonly semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'
for v in "$1" "$2"; do
  [[ "$v" =~ $semver_re ]] || { echo "semver-gt: '$v' is not X.Y.Z" >&2; exit 2; }
done

# part_gt X Y: digit strings, X > Y?
part_gt() {
  local x="${1##+(0)}" y="${2##+(0)}"
  x="${x:-0}"
  y="${y:-0}"
  if [[ "${#x}" -ne "${#y}" ]]; then
    [[ "${#x}" -gt "${#y}" ]]
  else
    [[ "$x" > "$y" ]]
  fi
}

shopt -s extglob
IFS=. read -r -a a <<< "$1"
IFS=. read -r -a b <<< "$2"
for i in 0 1 2; do
  if part_gt "${a[i]}" "${b[i]}"; then exit 0; fi
  if part_gt "${b[i]}" "${a[i]}"; then exit 1; fi
done
exit 1

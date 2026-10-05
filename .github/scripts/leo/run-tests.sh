#!/usr/bin/env bash
# Run every test_*.sh in a directory (default: ./tests next to this script),
# report each, and exit non-zero if any fails or none are found. Every test
# runs even after a failure, so one red test doesn't hide another.
# Usage:
#   run-tests.sh [DIR]     run the tests
#   run-tests.sh --list    print the tests that would run (default dir)
set -euo pipefail

default_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tests"

list=no
if [[ "${1:-}" == --list ]]; then
  list=yes
  shift
fi
dir="${1:-$default_dir}"

if [[ ! -d "$dir" ]]; then
  echo "run-tests.sh: no such directory: $dir" >&2
  exit 2
fi

tests=()
while IFS= read -r t; do
  tests+=("$t")
done < <(find "$dir" -maxdepth 1 -type f -name 'test_*.sh' | LC_ALL=C sort)

if [[ "${#tests[@]}" -eq 0 ]]; then
  echo "run-tests.sh: no test_*.sh found in $dir" >&2
  exit 1
fi

if [[ "$list" == yes ]]; then
  printf '%s\n' "${tests[@]}"
  exit 0
fi

failed=()
for t in "${tests[@]}"; do
  name="$(basename "$t")"
  echo "::group::$name"
  if bash "$t"; then
    echo "::endgroup::"
    echo "ok   $name"
  else
    rc=$?
    echo "::endgroup::"
    echo "FAIL $name (exit $rc)"
    failed+=("$name")
  fi
done

echo "-- $((${#tests[@]} - ${#failed[@]})) of ${#tests[@]} test scripts passed --"
if [[ "${#failed[@]}" -gt 0 ]]; then
  printf '::error::script test failed: %s\n' "${failed[@]}"
  exit 1
fi

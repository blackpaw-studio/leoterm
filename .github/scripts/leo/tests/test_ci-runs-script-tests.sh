#!/usr/bin/env bash
# Guards that CI actually runs these test_*.sh files (B-221). Before this,
# no workflow step invoked them, so a regression such as the B-129 #ifdef in
# Ghostty-Info.plist only surfaced when a release failed.
#
# Checks two things:
#   1. run-tests.sh behaves: runs every test_*.sh, fails on any failure,
#      fails when it finds none, and by default discovers this directory.
#      Exercised against fixture dirs only, so this test never re-enters the
#      real suite (no recursion).
#   2. leo-ci.yml (push to main + every PR) has a step that calls it, parsed
#      as YAML, with no step-level `if:` or `continue-on-error` that could
#      skip it or swallow its failure.
# Run directly:
#   ./test_ci-runs-script-tests.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly runner=../run-tests.sh
readonly workflow=../../../workflows/leo-ci.yml
readonly ruby=/usr/bin/ruby
pass=0
fail=0

result() {
  local ok="$1" desc="$2" detail="${3:-}"
  if [[ "$ok" == yes ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc${detail:+ ($detail)}"
    fail=$((fail + 1))
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fixture() {
  local dir="$work/$1"
  shift
  mkdir -p "$dir"
  local spec name code
  for spec in "$@"; do
    name="${spec%%=*}"
    code="${spec#*=}"
    printf '#!/usr/bin/env bash\necho "ran %s" >> "%s/ran.log"\nexit %s\n' \
      "$name" "$dir" "$code" > "$dir/$name"
  done
  echo "$dir"
}

# -- runner behaviour ---------------------------------------------------------

if [[ ! -f "$runner" ]]; then
  result no "run-tests.sh exists" "missing $runner"
else
  result yes "run-tests.sh exists"

  ok_dir="$(fixture ok test_a.sh=0 test_b.sh=0 helper.sh=1)"
  bash "$runner" "$ok_dir" > "$work/ok.out" 2>&1 && rc=0 || rc=$?
  [[ "$rc" -eq 0 ]] && ok=yes || ok=no
  result "$ok" "all-passing dir exits 0 (non-test_ files ignored)" "rc=$rc: $(tail -3 "$work/ok.out")"

  bad_dir="$(fixture bad test_a.sh=0 test_b.sh=1 test_c.sh=0)"
  bash "$runner" "$bad_dir" > "$work/bad.out" 2>&1 && rc=0 || rc=$?
  [[ "$rc" -ne 0 ]] && ok=yes || ok=no
  result "$ok" "one failing test makes the runner exit non-zero" "rc=$rc"
  ran="$(sort "$bad_dir/ran.log" | tr '\n' ' ')"
  [[ "$ran" == "ran test_a.sh ran test_b.sh ran test_c.sh " ]] && ok=yes || ok=no
  result "$ok" "a failure does not stop the remaining tests" "ran: $ran"
  grep -q 'test_b.sh' "$work/bad.out" && ok=yes || ok=no
  result "$ok" "the failing test is named in the output"

  empty_dir="$work/empty"
  mkdir -p "$empty_dir"
  bash "$runner" "$empty_dir" > "$work/empty.out" 2>&1 && rc=0 || rc=$?
  [[ "$rc" -ne 0 ]] && ok=yes || ok=no
  result "$ok" "a dir with no test_*.sh fails rather than passing vacuously" "rc=$rc"

  want="$(ls test_*.sh | sort)"
  got="$(bash "$runner" --list | xargs -n1 basename | sort)" || got="(--list failed)"
  [[ "$got" == "$want" ]] && ok=yes || ok=no
  result "$ok" "by default it discovers every test_*.sh in this directory" "got: $(echo $got)"
fi

# -- workflow wiring ----------------------------------------------------------

if [[ ! -x "$ruby" ]]; then
  result no "YAML parser available" "$ruby not found"
else
  # Prints one line per step that runs run-tests.sh unconditionally; a
  # commented-out invocation inside a run block does not count.
  steps="$("$ruby" -ryaml -e '
    wf = YAML.safe_load(File.read(ARGV[0])) || {}
    (wf["jobs"] || {}).each do |job_id, job|
      (job["steps"] || []).each do |s|
        lines = s["run"].to_s.lines.reject { |l| l.strip.start_with?("#") }
        next unless lines.any? { |l| l =~ %r{(\A|[\s/])\.github/scripts/leo/run-tests\.sh\b} }
        next if s.key?("if") || s["continue-on-error"]
        puts "#{job_id}: #{s["name"]}"
      end
    end
  ' "$workflow" 2>&1)" || steps=""
  [[ -n "$steps" ]] && ok=yes || ok=no
  result "$ok" "leo-ci.yml has an unconditional step that runs run-tests.sh" "${steps:-no such step}"
fi

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

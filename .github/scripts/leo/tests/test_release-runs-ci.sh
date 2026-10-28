#!/usr/bin/env bash
# Guards that a leo-vX.Y.Z tag cannot release without the CI gate (B-227).
# leo-release.yml used to call only leo-build, so a tag on a commit that
# skipped main's leo-ci (or landed while it was red) shipped without the
# script tests. Checks, parsed as YAML:
#   1. leo-ci.yml is callable (on: workflow_call).
#   2. leo-release.yml has a job that calls leo-ci.yml with no `if:`.
#   3. every job that calls leo-build.yml needs that job, so the signed
#      build (and therefore publish, which needs build) waits for green CI.
# Run directly:
#   ./test_release-runs-ci.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly ci=../../../workflows/leo-ci.yml
readonly release=../../../workflows/leo-release.yml
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

if [[ ! -x "$ruby" ]]; then
  result no "YAML parser available" "$ruby not found"
  echo "-- $pass passed, $fail failed --"
  exit 1
fi

# check <desc> <file> <ruby snippet over wf>; the snippet prints a problem,
# or nothing when the check holds. `on` parses as the boolean true key in
# YAML 1.1, so look it up both ways.
check() {
  local desc="$1" file="$2" snippet="$3" problem
  problem="$("$ruby" -ryaml -e '
    wf = YAML.safe_load(File.read(ARGV[0])) || {}
    triggers = wf["on"] || wf[true] || {}
    jobs = wf["jobs"] || {}
    '"$snippet"'
  ' "$file" 2>&1)" || problem="parse error: $problem"
  [[ -z "$problem" ]] && result yes "$desc" || result no "$desc" "$problem"
}

check "leo-ci.yml is callable via workflow_call" "$ci" '
  puts "no workflow_call trigger" unless triggers.is_a?(Hash) && triggers.key?("workflow_call")
'

check "leo-release.yml calls leo-ci.yml unconditionally" "$release" '
  gate = jobs.select { |_, j| j["uses"].to_s.end_with?("/leo-ci.yml") }
  puts "no job calls leo-ci.yml" if gate.empty?
  gate.each { |id, j| puts "#{id} has an if:" if j.key?("if") }
'

check "every leo-build.yml call in leo-release.yml needs the leo-ci call" "$release" '
  gate = jobs.select { |_, j| j["uses"].to_s.end_with?("/leo-ci.yml") }.keys
  builds = jobs.select { |_, j| j["uses"].to_s.end_with?("/leo-build.yml") }
  puts "no job calls leo-build.yml" if builds.empty?
  builds.each do |id, j|
    needs = Array(j["needs"])
    puts "#{id} does not need #{gate.inspect}" if (needs & gate).empty?
  end
'

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
